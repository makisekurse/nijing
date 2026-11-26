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
  failed,
}

class GenEvent {
  final GenEventKind kind;

  /// thoughtDelta / contentDelta 时为文本增量；notice 时为状态提示；failed 时为可读错误。
  final String text;

  final ParsedChapter? chapter;

  /// 是否由本地降级产出（内容不完整，但游戏没断流）。
  final bool degraded;

  const GenEvent.thoughtDelta(this.text)
      : kind = GenEventKind.thoughtDelta,
        chapter = null,
        degraded = false;

  const GenEvent.contentDelta(this.text)
      : kind = GenEventKind.contentDelta,
        chapter = null,
        degraded = false;

  /// 兼容别名，等同于 [GenEvent.contentDelta]。
  const GenEvent.delta(this.text)
      : kind = GenEventKind.contentDelta,
        chapter = null,
        degraded = false;

  const GenEvent.notice(this.text)
      : kind = GenEventKind.notice,
        chapter = null,
        degraded = false;

  /// 上一轮作废，即将从零开始新一轮 —— UI 必须清空思考与正文缓冲。
  const GenEvent.restart()
      : kind = GenEventKind.restart,
        text = '',
        chapter = null,
        degraded = false;

  const GenEvent.done(this.chapter, {this.degraded = false})
      : kind = GenEventKind.done,
        text = '';

  const GenEvent.failed(this.text)
      : kind = GenEventKind.failed,
        chapter = null,
        degraded = false;
}

/// 带双轨流隔离与清晰分级兜底的一幕生成器。
///
/// 策略：
/// - **配置/鉴权硬错（400 / 401 / 403 / 404）**：立刻以 `failed` 透出真实报文，绝不盲目重试或写入降级章节；
/// - **网络波动 / 断流 / 5xx / 429**：优先自动重试（不注入训诫词），同时记录最佳残文候选；重试耗尽有充足残文时终极抢救，否则以 `failed` 保留现场；
/// - **契约违背（拒答 / 空正文 / 缺分支）**：正向改写重试（最多 2 次）；若正文充足仅缺 `<choices>` 直接补齐分支结算；彻底无响应时才进入本地降级。
class FallbackService {
  FallbackService(this.client);

  final LlmClient client;

  static const int _maxRetries = 2;

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
  }) async* {
    final isGod = godMode ?? config.godMode;
    final systemPrompt = PromptBuilder.buildSystemPrompt(
      config: config,
      book: book,
      frameworkOverride: frameworkOverride,
      chronicle: chronicle,
      worldState: worldState,
      godMode: isGod,
    );

    AppError? lastError;
    var contractNudgeCount = 0;
    ParsedChapter? bestSalvage;

    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      if (client.isCancelled) {
        yield const GenEvent.failed('已中止。');
        return;
      }

      if (attempt > 0) {
        yield const GenEvent.restart();
        if (contractNudgeCount > 0) {
          yield GenEvent.notice('输出未满足契约，正在改写重试（第 $attempt 次）…');
        } else {
          yield GenEvent.notice('网络波动中断，正在重新连接重试（第 $attempt 次）…');
        }
      }
      RuntimeLog.i('Fallback', '尝试 ${attempt + 1}/${_maxRetries + 1}');

      // 网络重试严禁注入训诫词；仅契约违背或拒答时注入
      final nudge = contractNudgeCount > 0
          ? PromptBuilder.retryNudge(contractNudgeCount)
          : '';
      final messages = PromptBuilder.buildMessages(
        systemPrompt: systemPrompt + nudge,
        history: history,
        playerAction: playerAction,
        godMode: isGod,
      );

      final thoughtBuf = StringBuffer();
      final contentBuf = StringBuffer();
      var abortedEarly = false;

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
          final sofar = contentBuf.toString();
          if (sofar.length < 160 && ResponseParser.looksLikeRefusal(sofar)) {
            abortedEarly = true;
            break;
          }
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

        // 配置/鉴权硬错立刻退出，绝不重试
        if (e.isConfigError) {
          yield const GenEvent.restart();
          yield GenEvent.failed(e.message);
          return;
        }

        // 记录当前轮次可抢救的最佳残文
        final salvageCandidate = buildSalvageCandidate(
          content: contentBuf.toString(),
          thought: thoughtBuf.toString(),
        );
        if (salvageCandidate != null &&
            (bestSalvage == null ||
                salvageCandidate.body.length > bestSalvage.body.length)) {
          bestSalvage = salvageCandidate;
        }

        // 网络/服务端可重试错误：优先自动重连发起完整推演
        if (e.retryable && attempt < _maxRetries) {
          if (contentBuf.isNotEmpty || thoughtBuf.isNotEmpty) {
            yield const GenEvent.restart();
          }
          yield GenEvent.notice(
            '${e.message} 正在重新连接并完整推演（第 ${attempt + 2} 次）…',
          );
          continue;
        }

        // 重试机会耗尽：若有充足残文，执行终极抢救
        if (bestSalvage != null) {
          RuntimeLog.i(
            'Fallback',
            '重试耗尽但正文充足（${bestSalvage.body.length} 字），启动终极残文抢救',
          );
          yield const GenEvent.notice('网络多次波动中断，已为您抢救保存当前幕推演。');
          yield GenEvent.done(bestSalvage);
          return;
        }

        break;
      }

      if (abortedEarly) {
        RuntimeLog.w('Fallback', '第 ${attempt + 1} 轮早停（疑似拒答）');
        lastError = const AppError(AppErrorKind.refused, '模型回避了这一段的推演。');
        contractNudgeCount++;
        if (attempt < _maxRetries) {
          yield const GenEvent.restart();
          yield const GenEvent.notice('模型回避了这一段的推演，正在改写重试…');
        }
        continue;
      }

      final contentRaw = contentBuf.toString();
      final thoughtRaw = thoughtBuf.toString();
      final parsed = ResponseParser.parseChannels(
        content: contentRaw,
        thought: thoughtRaw,
      );

      RuntimeLog.i(
        'Fallback',
        '第 ${attempt + 1} 轮结束：正文 ${parsed.body.length} 字 · '
            '思考 ${parsed.thought.length} 字 · 分支 ${parsed.choices.length} 条',
      );

      if (parsed.body.trim().isEmpty) {
        lastError = const AppError(AppErrorKind.refused, '模型返回了空内容。');
        contractNudgeCount++;
        if (attempt < _maxRetries) {
          yield const GenEvent.restart();
          yield const GenEvent.notice('模型返回了空内容，正在重试…');
        }
        continue;
      }

      if (!parsed.hasUsableChoices) {
        final salvaged = buildSalvageCandidate(
          content: contentRaw,
          thought: thoughtRaw,
          allowWithoutDate: parsed.body.trim().length >= 300,
        );
        if (salvaged != null) {
          RuntimeLog.i(
            'Fallback',
            '正文充足（${salvaged.body.length} 字）但缺分支，自动补齐稳妥选项结算',
          );
          yield GenEvent.done(salvaged);
          return;
        }

        lastError = const AppError(
          AppErrorKind.truncated,
          '输出缺少决断分支（<choices>）。',
        );
        contractNudgeCount++;
        if (attempt < _maxRetries) {
          yield const GenEvent.restart();
          yield const GenEvent.notice('输出缺少决断分支，正在重试…');
        }
        continue;
      }

      yield GenEvent.done(parsed);
      return;
    }

    // ---- 兜底收尾 ----
    final err = lastError ??
        const AppError(AppErrorKind.unknown, '生成失败，原因未知。');
    RuntimeLog.e('Fallback', '兜底处理：${err.kind.name} · ${err.message}');

    if (err.isConfigError) {
      yield const GenEvent.restart();
      yield GenEvent.failed(err.message);
      return;
    }

    if (err.kind == AppErrorKind.network ||
        err.kind == AppErrorKind.server ||
        err.kind == AppErrorKind.rateLimit) {
      yield GenEvent.failed(
        '${err.message}\n推演未能完整落定，已保留当前现场与选项，请稍后重试。',
      );
      return;
    }

    // 仅在反复拒答/空返回时走本地降级，确保故事不断流
    yield const GenEvent.restart();
    yield GenEvent.notice(
      '${err.message}\n可尝试在设置里更换模型或服务商，或点击「重新生成本幕」。',
    );
    yield GenEvent.done(
      ParsedChapter(
        body: _localDegradedBody(playerAction, book),
        date: '',
        choices: const <String>[
          '重新生成本幕（调整模型或参数后重试）',
          '换一种行动表述重新推演',
        ],
      ),
      degraded: true,
    );
  }

  /// 判断残文是否具备抢救价值，并补全缺失的决断选项。
  static ParsedChapter? buildSalvageCandidate({
    required String content,
    required String thought,
    bool allowWithoutDate = false,
  }) {
    if (content.trim().isEmpty) return null;
    final parsed = ResponseParser.parseChannels(
      content: content,
      thought: thought,
    );
    final hasDate = parsed.date.isNotEmpty ||
        RegExp(r'[<＜《]\s*date\s*[>＞》]', caseSensitive: false).hasMatch(content);
    final bodyLen = parsed.body.trim().length;
    if (bodyLen < 200) return null;
    if (!hasDate && !allowWithoutDate) return null;

    final choices = List<String>.from(parsed.choices);
    if (choices.isEmpty) {
      choices.addAll(const <String>[
        '继续深入探查眼下局势',
        '按兵不动，静观其变',
      ]);
    } else if (choices.length == 1) {
      choices.add('按兵不动，静观其变');
    }

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
      choices: choices,
      glossary: parsed.glossary,
      cast: parsed.cast,
      stateRaw: parsed.stateRaw,
      thought: parsed.thought,
      rawOutput: parsed.rawOutput,
    );
  }

  String _localDegradedBody(String playerAction, WorldBook book) {
    final actionText =
        playerAction.trim().isEmpty ? '（开局起笔）' : '「${playerAction.trim()}」';
    return '（本地降级模式 · 模型连续未能输出有效推演）\n\n'
        '你在《${book.name}》中做出了如下决定：\n\n'
        '$actionText\n\n'
        '这一决定已记入编年史，本幕的推演正文尚未生成。'
        '待接口或模型调整后，点击菜单中的「重新生成本幕」即可补齐。';
  }
}
