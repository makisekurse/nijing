import '../core/app_error.dart';
import '../models/app_config.dart';
import '../models/chapter_node.dart';
import '../models/world_book.dart';
import 'llm_client.dart';
import 'prompt_builder.dart';
import 'response_parser.dart';
import 'runtime_log.dart';

enum GenEventKind {
  thoughtDelta,
  contentDelta,
  notice,
  restart,
  done,
  interrupted,
  failed,
}

class GenEvent {
  final GenEventKind kind;

  /// thoughtDelta / contentDelta 为文本增量；notice / interrupted / failed 为可读提示。
  final String text;

  final ParsedChapter? chapter;

  /// 是否由本地降级产出。
  final bool degraded;

  const GenEvent.thoughtDelta(this.text)
      : kind = GenEventKind.thoughtDelta,
        chapter = null,
        degraded = false;

  const GenEvent.contentDelta(this.text)
      : kind = GenEventKind.contentDelta,
        chapter = null,
        degraded = false;

  const GenEvent.delta(this.text)
      : kind = GenEventKind.contentDelta,
        chapter = null,
        degraded = false;

  const GenEvent.notice(this.text)
      : kind = GenEventKind.notice,
        chapter = null,
        degraded = false;

  const GenEvent.restart()
      : kind = GenEventKind.restart,
        text = '',
        chapter = null,
        degraded = false;

  const GenEvent.done(this.chapter, {this.degraded = false})
      : kind = GenEventKind.done,
        text = '';

  /// 流式已吐出有效正文后中途断流：绝不清屏重跑，原地保留现场交由用户续写或重试。
  const GenEvent.interrupted(this.text)
      : kind = GenEventKind.interrupted,
        chapter = null,
        degraded = false;

  const GenEvent.failed(this.text)
      : kind = GenEventKind.failed,
        chapter = null,
        degraded = false;
}

/// 绝不抹屏重写的一幕生成器（v2.0 吸收 Kelivo `retrying_stream.dart` 核心铁律）。
///
/// 铁律：
/// 1. **永不误杀台词**：彻底删除流式阶段靠「抱歉/对不起/我不能」关键词掐流重跑的缺陷；
/// 2. **已吐字绝不清屏（`if (yieldedBody) interrupt`）**：
///    - 仅在 **0 字节首帧前** 遇到临时网络/5xx/429 或全空响应时静默重试；
///    - 一旦已经向屏幕吐出正文，遇到网络波动或超时 **绝不发 `restart` 抹屏**，而是立刻发射
///      [GenEvent.interrupted] 原地保留所有文字，由用户决定「继续生成 / 重新生成 / 直接保存」；
/// 3. **正文绝对优先**：流式正常结束时，只要解析出非空正文（哪怕缺 `<choices>` 或 `<date>`），
///    直接成幕落盘，绝不为了少一个标签就把玩家等出来的千字正文全部作废！
class FallbackService {
  FallbackService(this.client);

  final LlmClient client;

  static const int _maxPreBodyRetries = 1;

  Stream<GenEvent> generate({
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required List<ChapterNode> history,
    required String playerAction,
    String? workspaceId,
    String frameworkOverride = '',
    String chronicle = '',
    String worldState = '',
    bool? godMode,
    bool? lightweightContract,
  }) async* {
    final isGod = godMode ?? config.godMode;
    final systemPrompt = PromptBuilder.buildSystemPrompt(
      config: config,
      book: book,
      frameworkOverride: frameworkOverride,
      chronicle: chronicle,
      worldState: worldState,
      godMode: isGod,
      lightweightContract: lightweightContract,
    );

    AppError? lastError;
    var lastAttemptWasEmptyBody = false;

    for (var attempt = 0; attempt <= _maxPreBodyRetries; attempt++) {
      if (client.isCancelled) {
        yield const GenEvent.failed('已中止。');
        return;
      }

      // 严格区分“网络重试”与“空正文重试”：网络重试绝不拼接 retryNudge 提示词
      final nudge = (attempt > 0 && lastAttemptWasEmptyBody)
          ? PromptBuilder.retryNudge(attempt)
          : '';
      final messages = PromptBuilder.buildMessages(
        systemPrompt: systemPrompt + nudge,
        history: history,
        playerAction: playerAction,
        godMode: isGod,
      );

      final thoughtBuf = StringBuffer();
      final contentBuf = StringBuffer();

      try {
        await for (final chunk in client.streamChunks(
          config: config,
          apiKey: apiKey,
          messages: messages,
          workspaceId: workspaceId,
        )) {
          if (chunk.isThought) {
            thoughtBuf.write(chunk.text);
            yield GenEvent.thoughtDelta(chunk.text);
            continue;
          }
          contentBuf.write(chunk.text);
          yield GenEvent.contentDelta(chunk.text);
        }
      } on AppError catch (e) {
        if (e.kind == AppErrorKind.cancelled) {
          yield const GenEvent.failed('已中止。');
          return;
        }
        lastError = e;
        RuntimeLog.w(
          'Fallback',
          '第 ${attempt + 1} 轮抛出：${e.kind.name} · ${e.message}'
              '${e.detail == null ? '' : ' · ${e.detail}'}',
        );

        // 配置/鉴权硬错立刻透出真实报文，绝不重试
        if (e.isConfigError) {
          if (contentBuf.isEmpty && thoughtBuf.isEmpty) {
            yield const GenEvent.restart();
          }
          yield GenEvent.failed(e.message);
          return;
        }

        // 核心铁律：只要已经吐出过正文，绝不抹屏重来！直接原地保留并进入可续写中断态。
        final hasVisibleBody =
            ResponseParser.previewBody(contentBuf.toString()).trim().isNotEmpty;
        if (hasVisibleBody) {
          RuntimeLog.i(
            'Fallback',
            '已吐出正文（${contentBuf.length} 字）后断流，严格原地保留现场并转入可续写态',
          );
          yield GenEvent.interrupted('${e.message}（已完整保留上方正文）');
          return;
        }

        // 尚未吐出任何正文：若 LlmClient 层尚未完成退避重试（或仅吐思考后断流需先清思考缓冲），允许干净重连一次
        final alreadyRetriedInClient =
            client.lastStreamAttempts > 1 && !client.yieldedAny;
        if (e.retryable &&
            attempt < _maxPreBodyRetries &&
            !alreadyRetriedInClient) {
          lastAttemptWasEmptyBody = false;
          yield const GenEvent.restart();
          yield GenEvent.notice('${e.message} 正在重新连接（第 ${attempt + 2} 次）…');
          continue;
        }

        yield GenEvent.failed(
          '${e.message}\n推演尚未产出正文，已保留当前现场与选项，请检查网络或配置后重试。',
        );
        return;
      }

      final contentRaw = contentBuf.toString();
      final thoughtRaw = thoughtBuf.toString();
      final parsed = ResponseParser.parseChannels(
        content: contentRaw,
        thought: thoughtRaw,
      );
      final finishReason = client.lastFinishReason;

      RuntimeLog.i(
        'Fallback',
        '第 ${attempt + 1} 轮完成：正文 ${parsed.body.length} 字 · '
            '思考 ${parsed.thought.length} 字 · 分支 ${parsed.choices.length} 条'
            '${finishReason == null ? '' : ' · finish_reason=$finishReason'}',
      );

      // 若因 token 长度上限截断且尚未写出 <choices>，进入可续写 interrupted 态而非静默残缺落幕
      if (finishReason == 'length' &&
          parsed.body.trim().isNotEmpty &&
          parsed.choices.isEmpty) {
        RuntimeLog.w(
          'Fallback',
          '命中 finish_reason=length 且缺少 <choices>，原地保留正文并转入可续写中断态',
        );
        yield const GenEvent.interrupted(
          '本幕输出达到单次长度上限（已完整保留上方正文，可点击「继续生成」补完）',
        );
        return;
      }

      // 只要有非空正文，立刻正常落幕！绝不因为缺少 <choices> 或字数偏短就清屏重来！
      if (parsed.body.trim().isNotEmpty) {
        yield GenEvent.done(parsed);
        return;
      }

      // 全空正文（屏幕此时本来为空）：允许附带补充说明重试一次
      lastError = const AppError(AppErrorKind.refused, '模型返回了空正文。');
      lastAttemptWasEmptyBody = true;
      if (attempt < _maxPreBodyRetries) {
        yield const GenEvent.restart();
        yield const GenEvent.notice('模型未输出正文，正在重试…');
        continue;
      }
    }

    final err = lastError ??
        const AppError(AppErrorKind.unknown, '推演未能取得有效正文，请检查模型配置或稍后重试。');
    RuntimeLog.e('Fallback', '最终失败：${err.kind.name} · ${err.message}');
    yield GenEvent.failed(err.message);
  }

  /// 断流原地续写（Continue）：紧接已有残文无缝流式补完剩余剧情与分支。
  Stream<GenEvent> continueGenerate({
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required List<ChapterNode> history,
    required String playerAction,
    required String existingContent,
    required String existingThought,
    String? workspaceId,
    String frameworkOverride = '',
    String chronicle = '',
    String worldState = '',
    bool? godMode,
    bool? lightweightContract,
  }) async* {
    final isGod = godMode ?? config.godMode;
    final systemPrompt = PromptBuilder.buildSystemPrompt(
      config: config,
      book: book,
      frameworkOverride: frameworkOverride,
      chronicle: chronicle,
      worldState: worldState,
      godMode: isGod,
      lightweightContract: lightweightContract,
    );

    final messages = PromptBuilder.buildContinueMessages(
      systemPrompt: systemPrompt,
      history: history,
      playerAction: playerAction,
      partialContent: existingContent,
      godMode: isGod,
    );

    final addedThought = StringBuffer();
    final addedContent = StringBuffer();

    try {
      await for (final chunk in client.streamChunks(
        config: config,
        apiKey: apiKey,
        messages: messages,
        workspaceId: workspaceId,
      )) {
        if (chunk.isThought) {
          addedThought.write(chunk.text);
          yield GenEvent.thoughtDelta(chunk.text);
          continue;
        }
        addedContent.write(chunk.text);
        yield GenEvent.contentDelta(chunk.text);
      }
    } on AppError catch (e) {
      if (e.kind == AppErrorKind.cancelled) {
        yield const GenEvent.interrupted('已暂停续写（已保留当前全部正文）');
        return;
      }
      yield GenEvent.interrupted('${e.message}（已保留当前全部正文）');
      return;
    }

    final mergedContent = existingContent + addedContent.toString();
    final mergedThought = <String>[
      if (existingThought.trim().isNotEmpty) existingThought.trim(),
      if (addedThought.toString().trim().isNotEmpty)
        addedThought.toString().trim(),
    ].join('\n\n');

    final parsed = ResponseParser.parseChannels(
      content: mergedContent,
      thought: mergedThought,
    );
    if (client.lastFinishReason == 'length' &&
        parsed.body.trim().isNotEmpty &&
        parsed.choices.isEmpty) {
      yield const GenEvent.interrupted(
        '续写再次达到长度上限（已保留全部正文，可继续生成或直接落幕）',
      );
      return;
    }
    if (parsed.body.trim().isNotEmpty) {
      yield GenEvent.done(parsed);
    } else {
      yield const GenEvent.interrupted('续写未返回新内容，已保留先前现场。');
    }
  }

  /// 判断残文是否具备落盘价值（保留兼容方法，供外部直接抢救/单测调用）。
  static ParsedChapter? buildSalvageCandidate({
    required String content,
    required String thought,
    bool allowWithoutDate = true,
  }) {
    if (content.trim().isEmpty) return null;
    final parsed = ResponseParser.parseChannels(
      content: content,
      thought: thought,
    );
    if (parsed.body.trim().isEmpty) return null;

    final salvagedDate = parsed.date.isNotEmpty
        ? parsed.date
        : (RegExp(r'[<＜《]\s*date\s*[>＞》]([^\n<＜《]+)')
                .firstMatch(content)
                ?.group(1)
                ?.trim() ??
            '');

    return ParsedChapter(
      body: parsed.body,
      date: salvagedDate,
      choices: List<String>.from(parsed.choices),
      glossary: parsed.glossary,
      cast: parsed.cast,
      stateRaw: parsed.stateRaw,
      thought: parsed.thought,
      rawOutput: parsed.rawOutput,
    );
  }
}
