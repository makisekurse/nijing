import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/app_config.dart';
import '../models/chapter_node.dart';
import '../models/save_slot.dart';
import '../models/world_book.dart';
import '../models/world_state.dart';
import 'chronicle_service.dart';
import 'fallback_service.dart';
import 'game_session.dart';
import 'llm_client.dart';
import 'providers.dart';
import 'response_parser.dart';
import 'runtime_log.dart';
import 'save_service.dart';
import 'scene_extractor_service.dart';
import 'world_state_service.dart';

enum GenerationStatus {
  idle,
  generating,
  interrupted,
  completed,
  failed,
}

/// 长生命周期的推演控制器（v2.0 升级：绝不清屏 + 断流续写 + 思考计时 + 后台双模型档案官）。
class GenerationController extends ChangeNotifier {
  final String slotId;
  final LlmClient client;

  /// 仅供测试注入后台档案官/编年史用客户端。
  @visibleForTesting
  LlmClient? auxClient;

  GenerationController(this.slotId, {LlmClient? client, this.auxClient})
      : client = client ?? LlmClient();

  static final Map<String, GenerationController> _registry =
      <String, GenerationController>{};

  static GenerationController forSlot(
    String slotId, {
    LlmClient? client,
    LlmClient? auxClient,
  }) {
    if (client != null || auxClient != null) {
      return _registry[slotId] = GenerationController(
        slotId,
        client: client,
        auxClient: auxClient,
      );
    }
    return _registry.putIfAbsent(slotId, () => GenerationController(slotId));
  }

  static GenerationController? get(String slotId) => _registry[slotId];

  /// 判断辅助模型在未填独立 Key 时是否允许安全回退复用主模型 Key：
  /// 仅当未启用独立辅模型，或辅模型与主模型同服务商且同端点时才允许回退。
  static bool canAuxFallbackToMainKey(AppConfig config) {
    if (!config.enableAuxModel || config.auxModelName.trim().isEmpty) {
      return true;
    }
    final aux = config.resolveAuxConfig();
    if (aux.apiProvider != config.apiProvider) return false;
    return Providers.resolveBaseUrl(config) == Providers.resolveBaseUrl(aux);
  }

  /// 解析后台辅助模型实际应使用的 API Key；跨厂商/异端点未配置独立 Key 时恒返回空串，绝不泄露主 Key。
  static String resolveEffectiveAuxKey({
    required AppConfig config,
    required String mainApiKey,
    required String auxApiKey,
  }) {
    if (auxApiKey.trim().isNotEmpty) return auxApiKey.trim();
    if (canAuxFallbackToMainKey(config)) return mainApiKey.trim();
    return '';
  }

  // ---------- 状态 ----------
  GenerationStatus status = GenerationStatus.idle;
  bool get isBusy => status == GenerationStatus.generating;
  bool get isInterrupted => status == GenerationStatus.interrupted;

  /// 单调递增代际号：隔离过期异步流，彻底杜绝 cancel() -> discardInterrupted() 后旧流误刷 failed。
  int _runEpoch = 0;

  String pendingAction = '';
  bool _continuing = false;
  bool _needThoughtSeparator = false;
  List<String> _activeBackupChoices = const <String>[];

  /// 纯思考增量缓冲（物理独立）。
  final StringBuffer _thoughtBuf = StringBuffer();

  /// 纯正文增量缓冲（物理独立）。
  final StringBuffer _contentBuf = StringBuffer();

  /// 节流后供 UI 直接渲染的纯净思考文本与正文预览（UI 零正则开销）。
  String liveThought = '';
  String liveBodyPreview = '';

  /// 思考阶段精确计时（支持续写多段累加）。
  DateTime? _thinkingStartedAt;
  int thinkingDurationMs = 0;

  /// 当前是否正处于「只吐思考、尚未吐正文」的阶段。
  bool get isThinkingPhase =>
      isBusy &&
      _thoughtBuf.isNotEmpty &&
      (liveBodyPreview.isEmpty || _thinkingStartedAt != null);

  /// 当前已累计的思考耗时（毫秒，支持续写累加实时推进）。
  int get liveThinkingDurationMs {
    if (_thinkingStartedAt != null) {
      return thinkingDurationMs +
          DateTime.now().difference(_thinkingStartedAt!).inMilliseconds;
    }
    return thinkingDurationMs;
  }

  /// 兼容旧读写：合成文本视图。
  String get live {
    final t = _thoughtBuf.toString();
    final c = _contentBuf.toString();
    if (t.isEmpty) return c;
    if (c.isEmpty) return '<think>$t';
    return '<think>$t</think>\n\n$c';
  }

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
  bool get hasLiveBody => liveBodyPreview.trim().isNotEmpty;

  String notice = '';
  bool noticeSticky = false;
  bool degraded = false;
  bool godMode = false;
  bool thoughtExpanded = false;
  int _pendingBgExtracts = 0;
  bool get extractingInBackground => _pendingBgExtracts > 0;
  Future<void> _bgExtractQueue = Future<void>.value();

  /// 用于「续写 / 重试」保留的上下文参数。
  AppConfig? _lastConfig;
  String _lastApiKey = '';
  String _lastAuxApiKey = '';
  WorldBook? _lastBook;

  GameSession? session;
  SaveSlot? lastSavedSlot;

  Timer? _throttleTimer;
  bool _dirty = false;
  static const Duration _uiThrottle = Duration(milliseconds: 55);

  void _clearLiveBuffers() {
    _thoughtBuf.clear();
    _contentBuf.clear();
    liveThought = '';
    liveBodyPreview = '';
    _thinkingStartedAt = null;
    thinkingDurationMs = 0;
    _needThoughtSeparator = false;
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

  void _markThinkingTick() {
    _thinkingStartedAt ??= DateTime.now();
  }

  void _finishThinkingClockIfNeeded() {
    if (_thinkingStartedAt != null) {
      thinkingDurationMs +=
          DateTime.now().difference(_thinkingStartedAt!).inMilliseconds;
      _thinkingStartedAt = null;
    }
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

  /// 开始推演新一幕。
  Future<void> startGeneration({
    required GameSession session,
    required AppConfig config,
    required String apiKey,
    String? auxApiKey,
    required String action,
    required WorldBook book,
    bool godMode = false,
  }) async {
    if (isBusy) return;

    final epoch = ++_runEpoch;
    final backupChoices = List<String>.from(session.choices);
    _activeBackupChoices = backupChoices;
    client.reset();
    this.session = session;
    this.godMode = godMode;
    _lastConfig = config;
    _lastApiKey = apiKey;
    _lastAuxApiKey = auxApiKey ?? '';
    _lastBook = book;
    _continuing = false;

    pendingAction = action;
    status = GenerationStatus.generating;
    _clearLiveBuffers();
    notice = '';
    noticeSticky = false;
    degraded = false;
    thoughtExpanded = false;
    notifyListeners();

    RuntimeLog.i('GenerationController', '[$slotId] 开始推演：action="$action"');

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

    await _consumeStream(
      epoch: epoch,
      stream: stream,
      session: session,
      config: config,
      apiKey: apiKey,
      book: book,
      action: action,
      godMode: godMode,
      backupChoices: backupChoices,
    );
  }

  /// 断流后原地无缝续写（Continue）：绝不清空已吐正文，直接接续生成。
  Future<void> continueGeneration({
    String? latestApiKey,
    String? latestAuxApiKey,
    AppConfig? latestConfig,
  }) async {
    if (isBusy || !hasLiveBody) return;
    final s = session;
    final cfg = latestConfig ?? _lastConfig;
    final book = _lastBook;
    if (s == null || cfg == null || book == null) return;

    final epoch = ++_runEpoch;
    final key = latestApiKey ?? _lastApiKey;
    _lastConfig = cfg;
    _lastApiKey = key;
    if (latestAuxApiKey != null) _lastAuxApiKey = latestAuxApiKey;

    final backupChoices = List<String>.from(s.choices);
    _activeBackupChoices = backupChoices;
    client.reset();
    _continuing = true;
    _finishThinkingClockIfNeeded();
    _needThoughtSeparator = _thoughtBuf.isNotEmpty;
    status = GenerationStatus.generating;
    notice = '';
    noticeSticky = false;
    notifyListeners();

    RuntimeLog.i('GenerationController', '[$slotId] 从断点续写（已有 ${_contentBuf.length} 字）');

    final stream = FallbackService(client).continueGenerate(
      config: cfg,
      apiKey: key,
      book: book,
      history: s.history,
      playerAction: pendingAction,
      existingContent: _contentBuf.toString(),
      existingThought: _thoughtBuf.toString(),
      workspaceId: cfg.workspaceId,
      chronicle: s.chronicle,
      worldState: WorldStateService.renderForPrompt(s.worldState),
      godMode: godMode,
    );

    await _consumeStream(
      epoch: epoch,
      stream: stream,
      session: s,
      config: cfg,
      apiKey: key,
      book: book,
      action: pendingAction,
      godMode: godMode,
      backupChoices: backupChoices,
    );
  }

  /// 直接把当前中断现场已有的正文保存落幕（若用户觉得残文已足够完整）。
  Future<void> commitInterruptedAsChapter() async {
    if (isBusy || !hasLiveBody || session == null) return;
    final s = session!;
    final cfg = _lastConfig;
    final book = _lastBook;
    final parsed = FallbackService.buildSalvageCandidate(
      content: _contentBuf.toString(),
      thought: _thoughtBuf.toString(),
    );
    if (parsed == null) return;
    await _commitChapter(
      session: s,
      parsed: parsed,
      action: pendingAction,
      godMode: godMode,
      wasDegraded: false,
      config: cfg,
      apiKey: _lastApiKey,
      book: book,
    );
  }

  /// 使用上次保存的参数原地重试本轮推演。
  Future<void> retryLast({
    String? latestApiKey,
    String? latestAuxApiKey,
    AppConfig? latestConfig,
  }) async {
    if (isBusy) return;
    final s = session;
    final cfg = latestConfig ?? _lastConfig;
    final book = _lastBook;
    if (s == null || cfg == null || book == null) return;
    await startGeneration(
      session: s,
      config: cfg,
      apiKey: latestApiKey ?? _lastApiKey,
      auxApiKey: latestAuxApiKey ?? _lastAuxApiKey,
      action: pendingAction,
      book: book,
      godMode: godMode,
    );
  }

  Future<void> _consumeStream({
    required int epoch,
    required Stream<GenEvent> stream,
    required GameSession session,
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required String action,
    required bool godMode,
    required List<String> backupChoices,
  }) async {
    ParsedChapter? parsed;
    var wasDegraded = false;
    var interrupted = false;

    try {
      await for (final ev in stream) {
        if (epoch != _runEpoch) return;
        if (client.isCancelled) break;
        switch (ev.kind) {
          case GenEventKind.thoughtDelta:
            if (session.choices.isNotEmpty) session.clearChoices();
            if (_needThoughtSeparator && ev.text.isNotEmpty) {
              _thoughtBuf.write('\n\n');
              _needThoughtSeparator = false;
            }
            _markThinkingTick();
            _thoughtBuf.write(ev.text);
            _scheduleThrottledNotify();
            break;
          case GenEventKind.contentDelta:
            if (session.choices.isNotEmpty) session.clearChoices();
            _finishThinkingClockIfNeeded();
            _contentBuf.write(ev.text);
            _scheduleThrottledNotify();
            break;
          case GenEventKind.notice:
            notice = ev.text;
            noticeSticky = false;
            _flushNotifyNow();
            break;
          case GenEventKind.restart:
            if (!_continuing) {
              _clearLiveBuffers();
              notice = '';
              noticeSticky = false;
              notifyListeners();
            }
            break;
          case GenEventKind.done:
            _finishThinkingClockIfNeeded();
            parsed = ev.chapter;
            wasDegraded = ev.degraded;
            notice = '';
            noticeSticky = false;
            _flushNotifyNow();
            break;
          case GenEventKind.interrupted:
            _finishThinkingClockIfNeeded();
            interrupted = true;
            notice = ev.text;
            noticeSticky = true;
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

      if (epoch != _runEpoch) return;

      if (client.isCancelled) {
        _handleCancelled(session, backupChoices);
        return;
      }

      if (parsed != null) {
        await _commitChapter(
          session: session,
          parsed: parsed,
          action: action,
          godMode: godMode,
          wasDegraded: wasDegraded,
          config: config,
          apiKey: apiKey,
          book: book,
        );
        return;
      }

      if (interrupted || hasLiveBody) {
        // 断流：原地保留全部残文和 pendingAction，供用户一键「继续生成 / 重试 / 直接保存」
        status = GenerationStatus.interrupted;
        _flushNotifyNow();
        return;
      }

      status = GenerationStatus.failed;
      if (session.choices.isEmpty && backupChoices.isNotEmpty) {
        session.restoreChoices(backupChoices);
      }
      _flushNotifyNow();
    } catch (e) {
      if (epoch != _runEpoch) return;
      if (client.isCancelled) {
        _handleCancelled(session, backupChoices);
        return;
      }
      RuntimeLog.e('GenerationController', '[$slotId] 推演未捕获异常: $e');
      _refreshPreviewsNow();
      if (hasLiveBody) {
        status = GenerationStatus.interrupted;
        notice = '推演中断：$e（已完整保留上方正文）';
        noticeSticky = true;
        _flushNotifyNow();
        return;
      }

      status = GenerationStatus.failed;
      notice = '推演发生异常：$e';
      noticeSticky = true;
      if (session.choices.isEmpty && backupChoices.isNotEmpty) {
        session.restoreChoices(backupChoices);
      }
      _flushNotifyNow();
    }
  }

  Future<void> _commitChapter({
    required GameSession session,
    required ParsedChapter parsed,
    required String action,
    required bool godMode,
    required bool wasDegraded,
    required AppConfig? config,
    required String apiKey,
    required WorldBook? book,
  }) async {
    final prevStateSnapshot = session.worldState.copy();
    final elapsedThoughtMs = liveThinkingDurationMs;

    final committed = session.appendChapter(
      content: parsed.body,
      playerAction: action,
      date: parsed.date,
      choices: parsed.choices,
      glossary: parsed.glossary,
      cast: parsed.cast,
      rawOutput: parsed.rawOutput,
      stateRaw: parsed.stateRaw,
      thought: parsed.thought,
      thinkingDurationMs: elapsedThoughtMs,
      godMode: godMode,
    );

    _clearLiveBuffers();
    pendingAction = '';
    _continuing = false;
    degraded = wasDegraded;
    status = GenerationStatus.completed;

    // 立刻落盘并刷新 UI —— 读者零等待！
    final slot = session.toSlot();
    await SaveService.upsert(slot);
    lastSavedSlot = slot;
    RuntimeLog.i('GenerationController', '[$slotId] 推演完成并已落盘');
    notifyListeners();

    if (wasDegraded || config == null || book == null) return;

    final targetLineId = session.line.id;
    final targetChapterIndex = committed.chapterIndex;
    final targetChapterCount = session.history.length;
    final auxConfig = config.resolveAuxConfig();
    final effectiveAuxKey = resolveEffectiveAuxKey(
      config: config,
      mainApiKey: apiKey,
      auxApiKey: _lastAuxApiKey,
    );
    final auxUrl = Providers.chatCompletionsUrl(auxConfig);
    final canRunAux = effectiveAuxKey.isNotEmpty ||
        LlmClient.allowsEmptyKey(auxConfig, auxUrl);
    if (!canRunAux) {
      RuntimeLog.w(
        'GenerationController',
        '[$slotId] 跨厂商或独立端点辅模型（${auxConfig.apiProvider}/${auxConfig.modelName}）'
            '未配置独立 API Key，为防止泄露主密钥已跳过后台档案与编年史任务',
      );
      return;
    }

    // 1. 后台档案官增量抽取（按 (lineId, chapterIndex) 串行排队定向合入，绝不因快节奏推演被丢弃）
    final needsExtract = config.enableBackgroundExtract &&
        (parsed.stateRaw.trim().isEmpty ||
            (parsed.cast.isEmpty && parsed.glossary.isEmpty));
    if (needsExtract) {
      _enqueueBackgroundExtraction(
        session: session,
        config: config,
        apiKey: effectiveAuxKey,
        book: book,
        previousState: prevStateSnapshot,
        chapterBody: parsed.body,
        playerAction: action,
        godMode: godMode,
        expectedLineId: targetLineId,
        expectedChapterIndex: targetChapterIndex,
      );
    }

    // 2. 每 5 幕后台非阻塞增量编年史压缩（走独立辅模型 Key 与 auxConfig 专属 workspaceId）
    if (ChronicleService.shouldCompress(targetChapterCount)) {
      final historySnapshot = List.of(session.history);
      final prevChronicle = session.chronicle;
      unawaited(
        _compressChronicleInBackground(
          session: session,
          config: config,
          apiKey: effectiveAuxKey,
          book: book,
          previousChronicle: prevChronicle,
          historySnapshot: historySnapshot,
          expectedLineId: targetLineId,
          expectedChapterCount: targetChapterCount,
        ),
      );
    }
  }

  void _enqueueBackgroundExtraction({
    required GameSession session,
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required WorldState previousState,
    required String chapterBody,
    required String playerAction,
    required bool godMode,
    required String expectedLineId,
    required int expectedChapterIndex,
  }) {
    _pendingBgExtracts++;
    notifyListeners();
    _bgExtractQueue = _bgExtractQueue.catchError((_) {}).then(
          (_) => _extractSceneInBackground(
            session: session,
            config: config,
            apiKey: apiKey,
            book: book,
            previousState: previousState,
            chapterBody: chapterBody,
            playerAction: playerAction,
            godMode: godMode,
            expectedLineId: expectedLineId,
            expectedChapterIndex: expectedChapterIndex,
          ),
        );
  }

  void _handleCancelled(GameSession session, List<String> backupChoices) {
    _finishThinkingClockIfNeeded();
    _refreshPreviewsNow();
    if (hasLiveBody) {
      // 用户手动点中止时，如果已经吐出正文，也贴心保留在现场供续写或保存
      status = GenerationStatus.interrupted;
      notice = '已暂停推演（已保留上方正文，可继续生成或直接保存）';
      noticeSticky = true;
      notifyListeners();
      return;
    }
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

  Future<void> _extractSceneInBackground({
    required GameSession session,
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required WorldState previousState,
    required String chapterBody,
    required String playerAction,
    required bool godMode,
    required String expectedLineId,
    required int expectedChapterIndex,
  }) async {
    try {
      final result = await SceneExtractorService.extract(
        config: config,
        apiKey: apiKey,
        book: book,
        previousState: previousState,
        chapterBody: chapterBody,
        playerAction: playerAction,
        godMode: godMode,
        client: auxClient,
      );
      if (result == null || result.isEmpty) return;
      if (!identical(_registry[slotId], this)) return;

      final applied = session.applyBackgroundExtraction(
        result,
        godMode: godMode,
        targetLineId: expectedLineId,
        targetChapterIndex: expectedChapterIndex,
      );
      if (!applied) return;

      final updatedSlot = session.toSlot();
      await SaveService.upsert(updatedSlot);
      lastSavedSlot = updatedSlot;
      notifyListeners();
    } catch (e) {
      RuntimeLog.w('GenerationController', '[$slotId] 后台状态抽取异常：$e');
    } finally {
      if (_pendingBgExtracts > 0) _pendingBgExtracts--;
      notifyListeners();
    }
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
        client: auxClient,
      );
      if (updated == previousChronicle || updated.trim().isEmpty) return;
      if (!identical(_registry[slotId], this)) return;

      final attached = session.attachChronicle(
        updated,
        targetLineId: expectedLineId,
      );
      if (!attached) return;

      final updatedSlot = session.toSlot();
      await SaveService.upsert(updatedSlot);
      lastSavedSlot = updatedSlot;
      RuntimeLog.i('GenerationController', '[$slotId] 后台编年史已更新并落盘');
      notifyListeners();
    } catch (e) {
      RuntimeLog.w('GenerationController', '[$slotId] 后台编年史更新异常：$e');
    }
  }

  void cancel() {
    client.cancel();
    _finishThinkingClockIfNeeded();
    _refreshPreviewsNow();
    if (hasLiveBody) {
      status = GenerationStatus.interrupted;
      notice = '已暂停推演（已保留上方正文，可继续生成或直接保存）';
      noticeSticky = true;
      notifyListeners();
      return;
    }
    status = GenerationStatus.idle;
    _clearLiveBuffers();
    pendingAction = '';
    notice = '已中止本次推演。';
    noticeSticky = true;
    final s = session;
    if (s != null && s.choices.isEmpty && _activeBackupChoices.isNotEmpty) {
      s.restoreChoices(_activeBackupChoices);
    }
    notifyListeners();
  }

  void discardInterrupted() {
    _runEpoch++;
    client.reset();
    status = GenerationStatus.idle;
    _clearLiveBuffers();
    pendingAction = '';
    _continuing = false;
    notice = '';
    noticeSticky = false;
    notifyListeners();
  }

  void reset() {
    _runEpoch++;
    client.reset();
    status = GenerationStatus.idle;
    _clearLiveBuffers();
    pendingAction = '';
    _continuing = false;
    notice = '';
    noticeSticky = false;
    degraded = false;
    thoughtExpanded = false;
    notifyListeners();
  }

  static void disposeSlot(String slotId) {
    final c = _registry.remove(slotId);
    if (c != null) {
      c._runEpoch++;
      c._throttleTimer?.cancel();
      c.client.cancel();
    }
  }

  static void resetAll() {
    for (final c in _registry.values) {
      c._runEpoch++;
      c._throttleTimer?.cancel();
      c.client.cancel();
    }
    _registry.clear();
  }
}
