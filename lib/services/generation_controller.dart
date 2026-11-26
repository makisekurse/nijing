import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/app_config.dart';
import '../models/chapter_node.dart';
import '../models/save_slot.dart';
import '../models/world_book.dart';
import 'chronicle_service.dart';
import 'fallback_service.dart';
import 'game_session.dart';
import 'llm_client.dart';
import 'response_parser.dart';
import 'runtime_log.dart';
import 'save_service.dart';
import 'world_state_service.dart';

enum GenerationStatus {
  idle,
  generating,
  completed,
  failed,
}

/// 长生命周期的推演控制器（按 slotId 维系独立的推演状态机、双轨流式缓冲区与持久化）。
///
/// 核心升级：
/// 1. **双轨物理隔离缓冲**：`liveThought` 与 `liveContent` 分开累积，杜绝思考草稿漏入正文；
/// 2. **60ms 渲染节流 + 预计算预览**：不在 UI `build()` 里重复跑正则，彻底根治高频 token 导致的掉帧卡顿；
/// 3. **非阻塞异步编年史**：章节落盘并立即刷新 UI 后，编年史增量压缩在后台静默完成，绝不卡死第 5/10/15 幕；
/// 4. **退出页面不中断推演**：`ReaderScreen` 只作为订阅者 attach/detach。
class GenerationController extends ChangeNotifier {
  final String slotId;
  final LlmClient client;

  GenerationController(this.slotId, {LlmClient? client})
      : client = client ?? LlmClient();

  static final Map<String, GenerationController> _registry =
      <String, GenerationController>{};

  static GenerationController forSlot(String slotId, {LlmClient? client}) {
    if (client != null) {
      return _registry[slotId] = GenerationController(slotId, client: client);
    }
    return _registry.putIfAbsent(slotId, () => GenerationController(slotId));
  }

  static GenerationController? get(String slotId) => _registry[slotId];

  // ---------- 状态 ----------
  GenerationStatus status = GenerationStatus.idle;
  bool get isBusy => status == GenerationStatus.generating;

  String pendingAction = '';

  /// 纯思考增量缓冲（物理独立）。
  final StringBuffer _thoughtBuf = StringBuffer();

  /// 纯正文增量缓冲（物理独立）。
  final StringBuffer _contentBuf = StringBuffer();

  /// 节流后供 UI 直接渲染的纯净思考文本与正文预览（UI 零正则开销）。
  String liveThought = '';
  String liveBodyPreview = '';

  /// 兼容旧读写：合成文本视图。
  String get live {
    final t = _thoughtBuf.toString();
    final c = _contentBuf.toString();
    if (t.isEmpty) return c;
    if (c.isEmpty) return '<think>$t';
    return '<think>$t</think>\n\n$c';
  }

  /// 供测试或外部直接注入流式内容（自动同步拆分至双轨缓冲并刷新预览）。
  set live(String value) {
    _clearLiveBuffers();
    if (value.isEmpty) return;
    final splitter = InlineThinkSplitter();
    for (final c in <LlmChunk>[...splitter.feed(value), ...splitter.flush()]) {
      if (c.isThought) {
        _thoughtBuf.write(c.text);
      } else {
        _contentBuf.write(c.text);
      }
    }
    _refreshPreviewsNow();
  }

  bool get hasLiveOutput => _thoughtBuf.isNotEmpty || _contentBuf.isNotEmpty;

  String notice = '';
  bool noticeSticky = false;
  bool degraded = false;
  bool godMode = false;
  bool thoughtExpanded = false;

  GameSession? session;
  SaveSlot? lastSavedSlot;

  Timer? _throttleTimer;
  bool _dirty = false;
  static const Duration _uiThrottle = Duration(milliseconds: 60);

  void _clearLiveBuffers() {
    _thoughtBuf.clear();
    _contentBuf.clear();
    liveThought = '';
    liveBodyPreview = '';
    _dirty = false;
    _throttleTimer?.cancel();
    _throttleTimer = null;
  }

  void _refreshPreviewsNow() {
    final rawThought = _thoughtBuf.toString();
    final rawContent = _contentBuf.toString();
    liveThought =
        rawThought.isEmpty ? '' : ResponseParser.cleanThoughtForShow(rawThought);
    liveBodyPreview =
        rawContent.isEmpty ? '' : ResponseParser.previewBody(rawContent);
  }

  void _scheduleThrottledNotify() {
    _dirty = true;
    if (_throttleTimer != null) return;
    _throttleTimer = Timer(_uiThrottle, () {
      _throttleTimer = null;
      if (!_dirty) return;
      _dirty = false;
      _refreshPreviewsNow();
      notifyListeners();
    });
  }

  void _flushNotifyNow() {
    _throttleTimer?.cancel();
    _throttleTimer = null;
    _dirty = false;
    _refreshPreviewsNow();
    notifyListeners();
  }

  /// 开始推演。
  Future<void> startGeneration({
    required GameSession session,
    required AppConfig config,
    required String apiKey,
    required String action,
    required WorldBook book,
    bool godMode = false,
  }) async {
    if (isBusy) return;

    final backupChoices = List<String>.from(session.choices);
    client.reset();
    this.session = session;
    this.godMode = godMode;
    pendingAction = action;
    status = GenerationStatus.generating;
    _clearLiveBuffers();
    notice = '';
    noticeSticky = false;
    degraded = false;
    thoughtExpanded = false;
    // 选项保留防闪烁：直到首个有效内容流入再清空
    notifyListeners();

    RuntimeLog.i('GenerationController', '[$slotId] 开始推演：action="$action"');

    ParsedChapter? parsed;
    var wasDegraded = false;

    try {
      final stream = FallbackService(client).generate(
        config: config,
        apiKey: apiKey,
        book: book,
        history: session.history,
        playerAction: action,
        workspaceId: config.workspaceId,
        chronicle: session.chronicle,
        worldState: WorldStateService.renderForPrompt(session.worldState),
        godMode: godMode,
      );

      await for (final ev in stream) {
        if (client.isCancelled) break;
        switch (ev.kind) {
          case GenEventKind.thoughtDelta:
            if (session.choices.isNotEmpty) {
              session.clearChoices();
            }
            _thoughtBuf.write(ev.text);
            _scheduleThrottledNotify();
            break;
          case GenEventKind.contentDelta:
            if (session.choices.isNotEmpty) {
              session.clearChoices();
            }
            _contentBuf.write(ev.text);
            _scheduleThrottledNotify();
            break;
          case GenEventKind.notice:
            notice = ev.text;
            noticeSticky = false;
            _flushNotifyNow();
            break;
          case GenEventKind.restart:
            _clearLiveBuffers();
            notice = '';
            noticeSticky = false;
            notifyListeners();
            break;
          case GenEventKind.done:
            parsed = ev.chapter;
            wasDegraded = ev.degraded;
            if (wasDegraded) {
              if (notice.isEmpty) {
                notice = '本幕未能取得有效模型响应，已进入本地降级，可重新生成本幕。';
              }
              noticeSticky = true;
            } else {
              notice = '';
              noticeSticky = false;
            }
            _flushNotifyNow();
            break;
          case GenEventKind.failed:
            if (!client.isCancelled) {
              notice = ev.text;
              noticeSticky = true;
              _flushNotifyNow();
            }
            break;
        }
      }

      if (client.isCancelled) {
        _handleCancelled(session, backupChoices);
        return;
      }

      final p = parsed ?? _trySalvageLive();
      if (p != null) {
        session.appendChapter(
          content: p.body,
          playerAction: action,
          date: p.date,
          choices: p.choices,
          glossary: p.glossary,
          cast: p.cast,
          rawOutput: p.rawOutput,
          stateRaw: p.stateRaw,
          thought: p.thought,
          godMode: godMode,
        );
        _clearLiveBuffers();
        pendingAction = '';
        degraded = wasDegraded;
        status = GenerationStatus.completed;
        if (parsed == null) {
          notice = '网络连接中断，已成功抢救并保存推演正文。';
          noticeSticky = true;
        }

        // 先落盘并立刻通知 UI 呈现新章节 —— 零等待！
        final slot = session.toSlot();
        await SaveService.upsert(slot);
        lastSavedSlot = slot;
        RuntimeLog.i('GenerationController', '[$slotId] 推演完成并已落盘');
        notifyListeners();

        // 编年史压缩改为后台非阻塞增量执行，彻底告别第 5/10/15 幕卡死
        if (!wasDegraded &&
            ChronicleService.shouldCompress(session.history.length)) {
          final targetLineId = session.line.id;
          final targetChapterCount = session.history.length;
          final historySnapshot = List.of(session.history);
          final prevChronicle = session.chronicle;
          unawaited(
            _compressChronicleInBackground(
              session: session,
              config: config,
              apiKey: apiKey,
              book: book,
              previousChronicle: prevChronicle,
              historySnapshot: historySnapshot,
              expectedLineId: targetLineId,
              expectedChapterCount: targetChapterCount,
            ),
          );
        }
      } else {
        // 严禁在失败时清空已有残文现场
        status = GenerationStatus.failed;
        pendingAction = '';
        if (session.choices.isEmpty && backupChoices.isNotEmpty) {
          session.restoreChoices(backupChoices);
        }
        _flushNotifyNow();
      }
    } catch (e) {
      if (client.isCancelled) {
        _handleCancelled(session, backupChoices);
        return;
      }
      RuntimeLog.e('GenerationController', '[$slotId] 推演未捕获异常: $e');

      final salvaged = _trySalvageLive();
      if (salvaged != null && this.session != null) {
        this.session!.appendChapter(
              content: salvaged.body,
              playerAction: action,
              date: salvaged.date,
              choices: salvaged.choices,
              glossary: salvaged.glossary,
              cast: salvaged.cast,
              rawOutput: salvaged.rawOutput,
              stateRaw: salvaged.stateRaw,
              thought: salvaged.thought,
              godMode: godMode,
            );
        _clearLiveBuffers();
        pendingAction = '';
        status = GenerationStatus.completed;
        notice = '推演发生异常中断，但已成功抢救并保存推演正文。';
        noticeSticky = true;
        final slot = this.session!.toSlot();
        await SaveService.upsert(slot);
        lastSavedSlot = slot;
        notifyListeners();
        return;
      }

      status = GenerationStatus.failed;
      notice = '推演发生异常：$e';
      noticeSticky = true;
      pendingAction = '';
      if (session.choices.isEmpty && backupChoices.isNotEmpty) {
        session.restoreChoices(backupChoices);
      }
      _flushNotifyNow();
    }
  }

  void _handleCancelled(GameSession session, List<String> backupChoices) {
    status = GenerationStatus.idle;
    _clearLiveBuffers();
    pendingAction = '';
    notice = '已中止本次推演。';
    noticeSticky = true;
    if (session.choices.isEmpty && backupChoices.isNotEmpty) {
      session.restoreChoices(backupChoices);
    }
    notifyListeners();
  }

  Future<void> _compressChronicleInBackground({
    required GameSession session,
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required String previousChronicle,
    required List<ChapterNode> historySnapshot,
    required String expectedLineId,
    required int expectedChapterCount,
  }) async {
    try {
      final updated = await ChronicleService.compress(
        config: config,
        apiKey: apiKey,
        book: book,
        previousChronicle: previousChronicle,
        history: historySnapshot,
        workspaceId: config.workspaceId,
      );
      if (updated == previousChronicle || updated.trim().isEmpty) return;
      // 校验当前槽位仍在注册表内且仍处于同一世界线，防止重开/删档/切线后串写
      if (!identical(_registry[slotId], this)) return;
      if (session.line.id != expectedLineId) return;
      if (session.history.length < expectedChapterCount) return;

      session.attachChronicle(updated);
      final updatedSlot = session.toSlot();
      await SaveService.upsert(updatedSlot);
      lastSavedSlot = updatedSlot;
      RuntimeLog.i('GenerationController', '[$slotId] 后台编年史已更新并落盘');
    } catch (e) {
      RuntimeLog.w('GenerationController', '[$slotId] 后台编年史更新异常：$e');
    }
  }

  ParsedChapter? _trySalvageLive() {
    final rawContent = _contentBuf.toString();
    final rawThought = _thoughtBuf.toString();
    if (rawContent.trim().isEmpty) return null;
    return FallbackService.buildSalvageCandidate(
      content: rawContent,
      thought: rawThought,
    );
  }

  void cancel() {
    client.cancel();
    status = GenerationStatus.idle;
    _clearLiveBuffers();
    pendingAction = '';
    notice = '已中止本次推演。';
    noticeSticky = true;
    notifyListeners();
  }

  void reset() {
    client.reset();
    status = GenerationStatus.idle;
    _clearLiveBuffers();
    pendingAction = '';
    notice = '';
    noticeSticky = false;
    degraded = false;
    thoughtExpanded = false;
    notifyListeners();
  }

  static void disposeSlot(String slotId) {
    final c = _registry.remove(slotId);
    c?._throttleTimer?.cancel();
    c?.client.cancel();
  }

  static void resetAll() {
    for (final c in _registry.values) {
      c._throttleTimer?.cancel();
      c.client.cancel();
    }
    _registry.clear();
  }
}
