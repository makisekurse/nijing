import '../core/app_error.dart';
import '../models/app_config.dart';
import '../models/chapter_node.dart';
import '../models/world_book.dart';
import 'llm_client.dart';
import 'prompt_builder.dart';
import 'response_parser.dart';
import 'runtime_log.dart';

enum GenEventKind { delta, notice, restart, done, failed }

class GenEvent {
  final GenEventKind kind;

  /// delta 时为文本增量；notice 时为状态提示；failed 时为可读错误。
  final String text;

  final ParsedChapter? chapter;

  /// 是否由本地降级产出（内容不完整，但游戏没断流）。
  final bool degraded;

  const GenEvent.delta(this.text)
      : kind = GenEventKind.delta,
        chapter = null,
        degraded = false;

  const GenEvent.notice(this.text)
      : kind = GenEventKind.notice,
        chapter = null,
        degraded = false;

  /// 上一轮作废，即将从零开始新一轮 —— UI 收到后必须**清空已显示的残文**，
  /// 否则不合格的旧内容会和新内容叠在一起。
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

/// 带**三级兜底**的一幕生成器。
///
/// ① 检出拒答 / 截断 → 正向改写重试（最多 2 次）
/// ② 仍失败 → 提示用户切换 API 通道（不同厂商审核尺度不同）
/// ③ 仍失败 → 回落本地降级，把决定记入编年史，游戏永不断流
///
/// 注意：这里用的是**正向改写**而不是对抗性越狱词 ——
/// 后者容易被平台风控判定为攻击，反而会让 Key 被限流甚至封禁。
class FallbackService {
  FallbackService(this.client);

  final LlmClient client;

  static const int _maxNudge = 2;

  Stream<GenEvent> generate({
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required List<ChapterNode> history,
    required String playerAction,
    String workspaceId = '',
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

    for (var attempt = 0; attempt <= _maxNudge; attempt++) {
      if (client.isCancelled) {
        yield const GenEvent.failed('已中止。');
        return;
      }

      if (attempt > 0) {
        // 先让 UI 丢掉落选的那一轮残文，再报「正在重试」——
        // 顺序不能反，否则旧残文会和新内容叠在一起。
        yield const GenEvent.restart();
        yield GenEvent.notice('输出未满足契约，正在改写重试（第 $attempt 次）…');
      }
      RuntimeLog.i('Fallback', '尝试 ${attempt + 1}/${_maxNudge + 1}');

      final nudge = PromptBuilder.retryNudge(attempt);
      final messages = PromptBuilder.buildMessages(
        systemPrompt: systemPrompt + nudge,
        history: history,
        playerAction: playerAction,
        godMode: isGod,
      );

      final buffer = StringBuffer();
      var abortedEarly = false;

      try {
        await for (final delta in client.streamChat(
          config: config,
          apiKey: apiKey,
          messages: messages,
          workspaceId: workspaceId,
        )) {
          buffer.write(delta);

          // 早停：开头就像拒答，不必等它把整段废话说完。
          final sofar = buffer.toString();
          if (sofar.length < 160 && ResponseParser.looksLikeRefusal(sofar)) {
            abortedEarly = true;
            break;
          }
          yield GenEvent.delta(delta);
        }
      } on AppError catch (e) {
        if (e.kind == AppErrorKind.cancelled) {
          yield const GenEvent.failed('已中止。');
          return;
        }
        lastError = e;
        RuntimeLog.w('Fallback', '第 ${attempt + 1} 轮抛出：'
            '${e.kind.name} · ${e.message}${e.detail == null ? '' : ' · ${e.detail}'}');
        if (e.retryable && attempt < _maxNudge) {
          if (buffer.isNotEmpty) yield const GenEvent.restart();
          yield GenEvent.notice('${e.message} 正在重试…');
          continue;
        }
        break;
      }

      if (abortedEarly) {
        RuntimeLog.w('Fallback', '第 ${attempt + 1} 轮早停（疑似拒答）');
        lastError = const AppError(
          AppErrorKind.refused,
          '模型回避了这一段的推演。',
        );
        if (attempt < _maxNudge) {
          yield const GenEvent.restart();
          yield const GenEvent.notice('模型回避了这一段的推演，正在改写重试…');
        }
        continue;
      }

      final raw = buffer.toString();
      final parsed = ResponseParser.parse(raw);

      RuntimeLog.i('Fallback', '第 ${attempt + 1} 轮结束：原文 ${raw.length} 字 · '
          '正文 ${parsed.body.length} 字 · 思考 ${parsed.thought.length} 字 · '
          '分支 ${parsed.choices.length} 条'
          '${parsed.hasUsableChoices ? '' : '（分支不足）'}');
      if (!parsed.hasUsableChoices) {
        RuntimeLog.w('Fallback', '缺 <choices>，原文尾部：${_tail(raw)}', detail: true);
      }

      if (parsed.body.trim().isEmpty) {
        lastError = const AppError(AppErrorKind.refused, '模型返回了空内容。');
        if (attempt < _maxNudge) {
          yield const GenEvent.restart();
          yield const GenEvent.notice('模型返回了空内容，正在重试…');
        }
        continue;
      }
      if (!parsed.hasUsableChoices) {
        lastError = const AppError(
          AppErrorKind.truncated,
          '输出缺少决断分支（<choices>）。',
        );
        if (attempt < _maxNudge) {
          yield const GenEvent.restart();
          yield const GenEvent.notice('输出缺少决断分支，正在重试…');
        }
        continue;
      }

      yield GenEvent.done(parsed);
      return;
    }

    // ---- 二级兜底：提示切换通道 ----
    final err = lastError ??
        const AppError(AppErrorKind.unknown, '生成失败，原因未知。');
    RuntimeLog.e('Fallback', '兜底处理：${err.kind.name} · ${err.message}');

    // 关键修复：参数/认证非法（400 Bad Request、401/403 密钥无效等）属于配置与端点校验失败，
    // 必须直接以 failed 中止推演并保留原有备选分支，严禁插入虚假降级章节污染用户存档。
    if (err.kind == AppErrorKind.auth) {
      yield const GenEvent.restart();
      yield GenEvent.failed(err.message);
      return;
    }

    // ---- 三级兜底：本地降级，保证不断流 ----
    yield const GenEvent.restart();
    yield GenEvent.notice(
      '${err.message}\n可尝试：在设置里换一个模型或换一家服务商'
      '（不同厂商的内容尺度不同），或点「重新生成本幕」。',
    );
    yield GenEvent.done(
      ParsedChapter(
        body: _localDegradedBody(playerAction, book),
        date: '',
        choices: <String>[
          '重新生成本幕（网络恢复后补齐内容）',
          '换一个模型或服务商后再试',
        ],
      ),
      degraded: true,
    );
  }

  /// 本地降级正文：如实说明当前状态，并把决定记下来，
  /// 而不是编造一段假剧情。
  String _localDegradedBody(String playerAction, WorldBook book) {
    return '（本地降级模式 · 当前未能取得模型响应）\n\n'
        '你在《${book.name}》中做出了如下决定：\n\n'
        '「$playerAction」\n\n'
        '这一决定已记入编年史，本幕的推演正文尚未生成。'
        '待网络或接口恢复后，点击下方「重新生成本幕」即可补齐。';
  }

  /// 排障用：取原文尾部，直接定位截断点。
  static String _tail(String s, [int n = 200]) =>
      s.length <= n ? s : '…${s.substring(s.length - n)}';
}
