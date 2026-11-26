import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../data/secure_store.dart';
import '../../models/app_config.dart';
import '../../models/chapter_node.dart';
import '../../models/save_slot.dart';
import '../../models/world_line.dart';
import '../../models/world_state.dart';
import '../../services/game_session.dart';
import '../../services/generation_controller.dart';
import '../../services/save_service.dart';
import '../../services/wakelock_service.dart';
import '../themes/app_theme.dart';
import '../widgets/chapter_toc_sheet.dart';
import '../widgets/choice_pill.dart';
import '../widgets/free_input_bar.dart';
import '../widgets/glossary_sheet.dart';
import '../widgets/live_thought_view.dart';
import '../widgets/reader_chapter_card.dart';
import '../widgets/reader_paragraph.dart';
import '../widgets/reader_sheets.dart';
import '../widgets/reader_world_line_sheets.dart';
import 'cast_screen.dart';
import 'chronicle_screen.dart';
import 'settings_screen.dart';

/// 沉浸式阅读主视口（重构瘦身 + 高性能虚拟化版）。
///
/// 核心改进：
/// 1. `CustomScrollView` + `SliverList.builder` 懒加载历史章节；
/// 2. 流式推演区通过独立 `ListenableBuilder` 订阅 `GenerationController`，
///    吐字期间历史章节零重绘、零正则重算，彻底告别卡顿掉帧；
/// 3. 流式正文与落定章节共用 `ReaderParagraphList`，落定瞬间排版零跳变；
/// 4. 每次发起推演与从设置页返回时实时刷新 API Key，修复改 Key 不生效 Bug；
/// 5. 修复第一幕无法「重新生成本幕」的静默失效 Bug；
/// 6. 用 `UserScrollNotification` + 单次贴底调度根治滚动手势与自动滚底互殴。
class ReaderScreen extends StatefulWidget {
  final AppConfig config;
  final SaveSlot slot;
  final ValueChanged<AppConfig> onConfigChanged;

  const ReaderScreen({
    super.key,
    required this.config,
    required this.slot,
    required this.onConfigChanged,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();
  late GenerationController _controller;

  late AppConfig _config;
  late SaveSlot _slot;
  late GameSession _session;

  List<ChapterNode> get _history => _session.history;
  String get _chronicle => _session.chronicle;
  WorldState get _worldState => _session.worldState;
  List<String> get _choices => _session.choices;

  bool _headerVisible = true;
  Timer? _headerTimer;

  final Map<int, GlobalKey> _chapterKeys = <int, GlobalKey>{};
  GlobalKey _chapterKeyFor(int index) =>
      _chapterKeys.putIfAbsent(index, () => GlobalKey());

  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  late bool _godMode;

  int _lastHistoryLen = 0;
  int _lastLiveLen = 0;
  bool _atBottom = true;
  bool _hasNewStreamingContent = false;
  bool _followScheduled = false;

  int? _activePointer;
  Offset? _pointerDown;
  bool _pointerMoved = false;
  bool _ignoreTapForHeader = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _config = widget.config;
    _godMode = _config.godMode;
    _slot = widget.slot;
    _controller = GenerationController.forSlot(_slot.id);

    if (_controller.isBusy) {
      _session = _controller.session ?? GameSession(_slot);
    } else if (_controller.session != null) {
      _slot = _controller.lastSavedSlot ?? _slot;
      _session = _controller.session!;
    } else if (_controller.lastSavedSlot != null) {
      _slot = _controller.lastSavedSlot!;
      _session = GameSession(_slot);
    } else {
      _session = GameSession(_slot);
    }

    _lastHistoryLen = _history.length;
    _lastLiveLen = _controller.liveThought.length + _controller.liveBodyPreview.length;

    _controller.addListener(_onControllerEvent);
    _scroll.addListener(_onScroll);
    _enterImmersive();
    _scheduleHeaderHide();
    _applyWakelock();
    _maybeJumpToLatest();
  }

  /// 仅在章节数量变更或状态切换时刷新外层列表；流式增量由局部 `ListenableBuilder` 消费。
  void _onControllerEvent() {
    if (!mounted) return;
    final curHistoryLen = _history.length;
    final curLiveLen =
        _controller.liveThought.length + _controller.liveBodyPreview.length;

    final historyChanged = curHistoryLen != _lastHistoryLen;
    final liveGrew = curLiveLen > _lastLiveLen;
    _lastHistoryLen = curHistoryLen;
    _lastLiveLen = curLiveLen;

    if (historyChanged) {
      setState(() {});
      _scheduleFollow(smooth: true);
      return;
    }

    if (liveGrew) {
      if (!_atBottom) {
        if (!_hasNewStreamingContent) {
          setState(() => _hasNewStreamingContent = true);
        }
      } else {
        _scheduleFollow(smooth: false);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockService.disable();
    _headerTimer?.cancel();
    _controller.removeListener(_onControllerEvent);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    _exitImmersive();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _applyWakelock();
    } else {
      WakelockService.disable();
    }
  }

  void _applyWakelock() {
    if (_config.keepScreenOn) {
      WakelockService.enable();
    } else {
      WakelockService.disable();
    }
  }

  void _enterImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _exitImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  void _scheduleHeaderHide() {
    _headerTimer?.cancel();
    if (!_config.autoHideHeader) return;
    _headerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _headerVisible = false);
    });
  }

  void _toggleHeader() {
    if (_headerVisible) {
      _headerTimer?.cancel();
      setState(() => _headerVisible = false);
    } else {
      setState(() => _headerVisible = true);
      _scheduleHeaderHide();
    }
  }

  // ---------- 滚动与跳转 ----------

  void _maybeJumpToLatest() {
    if (!_config.autoScrollToLatest || _history.isEmpty) return;
    _jumpToLatest();
  }

  void _jumpToLatest() {
    if (_history.isEmpty) return;
    _hasNewStreamingContent = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _atBottom = true;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    });
  }

  /// 支持懒加载 SliverList 的精准跳幕：未挂载时先估算跳转，再微调对齐。
  void _jumpToChapter(int index) {
    if (index < 0 || index >= _history.length) return;
    _hasNewStreamingContent = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final ctx = _chapterKeyFor(index).currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
          alignment: 0.05,
        );
        return;
      }
      final ratio = _history.length <= 1 ? 0.0 : index / (_history.length - 1);
      final target = (_scroll.position.maxScrollExtent * ratio)
          .clamp(0.0, _scroll.position.maxScrollExtent);
      _scroll.jumpTo(target);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final mountedCtx = _chapterKeyFor(index).currentContext;
        if (mountedCtx != null) {
          Scrollable.ensureVisible(
            mountedCtx,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0.05,
          );
        }
      });
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final cur = _scroll.position.pixels;
    final isBottom = (max - cur) <= 48;
    if (isBottom != _atBottom) {
      setState(() {
        _atBottom = isBottom;
        if (isBottom) _hasNewStreamingContent = false;
      });
    }
  }

  bool _onUserScroll(UserScrollNotification n) {
    // 只要用户主动向上拖拽，立刻解除自动跟随，绝不和用户抢滚动条
    if (n.direction == ScrollDirection.forward && _atBottom) {
      setState(() => _atBottom = false);
    }
    return false;
  }

  void _scheduleFollow({required bool smooth}) {
    if (!_atBottom || _activePointer != null || _followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_scroll.hasClients || !_atBottom || _activePointer != null) {
        return;
      }
      final max = _scroll.position.maxScrollExtent;
      if (smooth) {
        _scroll.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        // 流式吐字期间用无重叠 jumpTo 贴底，彻底消灭每秒几十次 animateTo 互相打架
        _scroll.jumpTo(max);
      }
    });
  }

  void _scrollToBottomAndFollow() {
    setState(() {
      _atBottom = true;
      _hasNewStreamingContent = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ---------- 原始指针（单击切顶栏，不抢控件与拖动） ----------

  void _onPointerDown(PointerDownEvent e) {
    if (_activePointer == null) {
      _activePointer = e.pointer;
      _pointerDown = e.position;
      _pointerMoved = false;
      _ignoreTapForHeader = false;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (e.pointer != _activePointer) return;
    final d = _pointerDown;
    if (d == null || _pointerMoved) return;
    if ((e.position - d).distance > 12) _pointerMoved = true;
  }

  void _onPointerUp(PointerUpEvent e) {
    if (e.pointer != _activePointer) return;
    final wasDrag = _pointerMoved;
    final ignored = _ignoreTapForHeader;
    _activePointer = null;
    _pointerDown = null;
    _pointerMoved = false;
    _ignoreTapForHeader = false;
    if (wasDrag || ignored) return;
    _toggleHeader();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    if (e.pointer == _activePointer) {
      _activePointer = null;
      _pointerDown = null;
      _pointerMoved = false;
      _ignoreTapForHeader = false;
    }
  }

  // ---------- 推演与状态操作 ----------

  Future<void> _act(String action, {bool? godMode}) async {
    if (_controller.isBusy) return;
    final isGod = godMode ?? _godMode;
    // 每次推演直接读取最新 API Key，彻底修复从设置页改 Key 返回后不生效的 Bug
    final latestKey = await SecureStore.readApiKey();
    if (!mounted) return;
    _atBottom = true;
    _scheduleFollow(smooth: true);

    await _controller.startGeneration(
      session: _session,
      config: _config,
      apiKey: latestKey,
      action: action,
      book: _slot.worldBook,
      godMode: isGod,
    );
    if (mounted) {
      _scheduleFollow(smooth: true);
    }
  }

  Future<void> _persist() async {
    await SaveService.upsert(_session.toSlot());
  }

  /// 重新生成当前这一幕（支持第一幕空 action 开局重生成）。
  Future<void> _rerollLast() async {
    if (_controller.isBusy || _history.isEmpty) return;
    final last = _history.last;
    final action = (last.playerAction ?? '').trim();

    setState(() {
      _session.popLastForReroll();
      _lastHistoryLen = _history.length;
      _controller.reset();
    });
    await _act(action);
  }

  Future<void> _branchFrom(int index) async {
    if (_controller.isBusy) return;
    if (index < 0 || index >= _history.length) return;
    final chapterNo = _history[index].chapterIndex;

    final branch = _session.branchFrom(index);
    setState(() {
      _lastHistoryLen = _history.length;
      _controller.reset();
      _controller.notice =
          '已从第 $chapterNo 幕分岔出「${branch.name}」。原世界线已保留，可在「世界线」里随时切回。';
      _controller.noticeSticky = false;
    });
    await _persist();
    _jumpToLatest();
  }

  Future<void> _switchLine(String lineId) async {
    if (_controller.isBusy) return;
    setState(() {
      _session.switchLine(lineId);
      _lastHistoryLen = _history.length;
      _controller.reset();
    });
    await _persist();
    _jumpToLatest();
  }

  Future<void> _renameLine(WorldLine target) async {
    final ctrl = TextEditingController(text: target.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名世界线', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：走西南路线'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || !mounted) return;
    setState(() => _session.renameLine(target.id, name));
    await _persist();
  }

  Future<void> _deleteLine(WorldLine target) async {
    if (_controller.isBusy) {
      _toast('推演进行中，暂不能管理世界线。');
      return;
    }
    if (_session.lines.length <= 1) {
      _toast('至少要保留一条世界线。');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
          '删除「${target.name}」？\n它的 ${target.chapterCount} 幕进度会一起消失，无法恢复。',
          style: const TextStyle(fontSize: 14, height: 1.7),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      _session.deleteLine(target.id);
      _lastHistoryLen = _history.length;
      _controller.reset();
    });
    await _persist();
  }

  Future<void> _editChapter(ChapterNode chapter) async {
    final saved = await ReaderSheets.showEditChapterDialog(context, chapter);
    if (saved == null || !mounted) return;
    if (saved.trim().isEmpty) {
      _toast('正文内容不能为空');
      return;
    }
    final index = _history.indexOf(chapter);
    if (index < 0) return;

    setState(() => _session.editChapterContent(index, saved));
    await _persist();
    _toast('第 ${chapter.chapterIndex} 幕正文已更新并保存。');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- 界面构建 ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fontSize = AppTheme.getFontSize(_config.fontSize);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: NotificationListener<UserScrollNotification>(
                onNotification: _onUserScroll,
                child: SelectionArea(
                  child: CustomScrollView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(
                      parent: BouncingScrollPhysics(),
                    ),
                    slivers: <Widget>[
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: ReaderFrontispiece(book: _slot.worldBook),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        sliver: SliverList.builder(
                          itemCount: _history.length,
                          itemBuilder: (ctx, i) {
                            final chapter = _history[i];
                            return KeyedSubtree(
                              key: _chapterKeyFor(i),
                              child: ReaderChapterCard(
                                chapter: chapter,
                                config: _config,
                                fontSize: fontSize,
                                onInteractiveTouch: () =>
                                    _ignoreTapForHeader = true,
                                onOpenMenu: () => ReaderSheets.showChapterMenu(
                                  context,
                                  chapter: chapter,
                                  onCopy: () =>
                                      ReaderExportAndLineSheets.copyChapter(
                                          context, chapter),
                                  onEdit: () => _editChapter(chapter),
                                  onExportLog: () =>
                                      ReaderExportAndLineSheets.exportRuntimeLog(
                                          context),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      // 独立流式推演与操作栏区域：仅局部响应 GenerationController，零历史重绘
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 44),
                        sliver: SliverToBoxAdapter(
                          child: ListenableBuilder(
                            listenable: _controller,
                            builder: (ctx, _) =>
                                _buildLiveAndFooter(theme, fontSize),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _header(theme),
            _buildBackToLatestButton(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveAndFooter(ThemeData theme, double fontSize) {
    final palette = AppTheme.readingOf(context);
    final busy = _controller.isBusy;
    final hasLive = _controller.hasLiveOutput;
    final thought = _controller.liveThought;
    final preview = _controller.liveBodyPreview;
    final notice = _controller.notice;
    final showNotice = notice.isNotEmpty && (!busy || _controller.noticeSticky);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (busy || hasLive) ...<Widget>[
          if (_controller.pendingAction.isNotEmpty)
            ReaderActionCard(action: _controller.pendingAction),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: <Widget>[
                if (busy)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
                    ),
                  )
                else
                  Icon(
                    Icons.pause_circle_outline_rounded,
                    size: 14,
                    color: palette.accent,
                  ),
                const SizedBox(width: 8),
                Text(
                  busy
                      ? (_controller.degraded
                          ? '本地降级中…'
                          : (preview.isEmpty && thought.isNotEmpty
                              ? '推演思考中…'
                              : '推演中…'))
                      : '推演中断（已保留现场）',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.accent,
                  ),
                ),
              ],
            ),
          ),
          if (thought.isNotEmpty)
            Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _ignoreTapForHeader = true,
              child: LiveThoughtView(
                key: const ValueKey('live_thought_view'),
                thought: thought,
                initialExpanded: _controller.thoughtExpanded,
                onExpansionChanged: (v) => _controller.thoughtExpanded = v,
              ),
            ),
          if (preview.isNotEmpty)
            ReaderParagraphList(
              content: preview,
              config: _config,
              fontSize: fontSize,
              color: palette.ink,
            ),
        ],
        if (showNotice)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.rule),
            ),
            child: Text(
              notice,
              style: TextStyle(fontSize: 12.5, height: 1.6, color: palette.ink),
            ),
          ),
        const SizedBox(height: 12),
        SelectionContainer.disabled(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (_) => _ignoreTapForHeader = true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_choices.isNotEmpty && (!hasLive || !busy)) ...<Widget>[
                  for (var i = 0; i < _choices.length; i++)
                    ChoicePill(
                      index: i + 1,
                      text: _choices[i],
                      enabled: !busy,
                      onTap: () => _act(_choices[i]),
                    ),
                  const SizedBox(height: 6),
                ] else if (!busy && _history.isEmpty && _choices.isEmpty) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => _act(''),
                        icon: const Icon(Icons.auto_stories_rounded, size: 18),
                        label: const Text('开始推演'),
                        style: FilledButton.styleFrom(
                          backgroundColor: theme.colorScheme.primary,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                      ),
                    ),
                  ),
                ],
                FreeInputBar(
                  busy: busy,
                  controller: _inputController,
                  focusNode: _inputFocusNode,
                  godMode: _godMode,
                  onToggleGodMode: (v) => setState(() => _godMode = v),
                  onSend: (text) => _act(text, godMode: _godMode),
                  onCancel: _controller.cancel,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 顶栏与全局菜单 ----------

  Widget _header(ThemeData theme) {
    final palette = AppTheme.readingOf(context);
    return AnimatedOpacity(
      opacity: _headerVisible ? 1 : 0,
      duration: const Duration(milliseconds: 240),
      child: IgnorePointer(
        ignoring: !_headerVisible,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleHeader,
          child: Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 6, 12),
            decoration: BoxDecoration(
              color: palette.scrim,
              border: Border(
                bottom: BorderSide(color: palette.rule, width: 0.8),
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        _slot.worldBook.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                      Text(
                        _statusLine(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: palette.muted),
                      ),
                    ],
                  ),
                ),
                _headerAction(
                  palette,
                  icon: Icons.format_list_bulleted_rounded,
                  tooltip: '幕次目录',
                  onTap: () => ChapterTocSheet.show(
                    context,
                    history: _history,
                    onSelectChapter: _jumpToChapter,
                  ),
                ),
                _headerAction(
                  palette,
                  icon: Icons.timeline_rounded,
                  tooltip: '编年史',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ChronicleScreen(history: _history),
                    ),
                  ),
                ),
                _headerAction(
                  palette,
                  icon: Icons.groups_outlined,
                  tooltip: '人物志',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => CastScreen(history: _history),
                    ),
                  ),
                ),
                _headerAction(
                  palette,
                  icon: Icons.explore_outlined,
                  tooltip: '世界观察',
                  onTap: () => ReaderSheets.showWorldState(context, _worldState),
                ),
                _headerAction(
                  palette,
                  icon: Icons.more_horiz_rounded,
                  tooltip: '更多',
                  onTap: _openMenu,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerAction(
    ReadingPalette palette, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) =>
      IconButton(
        tooltip: tooltip,
        iconSize: 20,
        visualDensity: VisualDensity.compact,
        icon: Icon(icon, color: palette.ink),
        onPressed: onTap,
      );

  String _statusLine() {
    final parts = <String>[];
    if (_session.lines.length > 1) parts.add(_session.line.name);
    parts.add('第 ${_history.length} 幕');
    final summary = _worldState.inlineSummary;
    if (summary.isNotEmpty) {
      parts.add(summary);
    } else if (_slot.worldBook.era.trim().isNotEmpty) {
      parts.add(_slot.worldBook.era.trim());
    }
    return parts.join(' · ');
  }

  void _openMenu() {
    final theme = Theme.of(context);
    final busy = _controller.isBusy;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  leading: const Icon(Icons.explore_outlined),
                  title: const Text('世界观察'),
                  subtitle: const Text('此刻的时间、地点、人物与未决之事'),
                  onTap: () {
                    Navigator.pop(ctx);
                    ReaderSheets.showWorldState(context, _worldState);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.timeline_rounded),
                  title: const Text('编年史时间线'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ChronicleScreen(history: _history),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.groups_rounded),
                  title: const Text('人物志'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => CastScreen(history: _history),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.menu_book_rounded),
                  title: const Text('本幕词条'),
                  onTap: () {
                    Navigator.pop(ctx);
                    if (_history.isEmpty) return;
                    AnnotationSheet.showGlossary(
                        context, _history.last.glossary);
                  },
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.refresh_rounded),
                  title: const Text('重新生成本幕'),
                  enabled: !busy && _history.isNotEmpty,
                  onTap: () {
                    Navigator.pop(ctx);
                    _rerollLast();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.history_rounded),
                  title: Text(
                    _session.lines.length > 1
                        ? '世界线（${_session.lines.length} 条）'
                        : '世界线',
                  ),
                  subtitle: Text(
                    _session.lines.length > 1
                        ? '当前：${_session.line.name} · 可切换 / 分岔'
                        : '走错了可以从某一幕分岔出新世界线',
                  ),
                  enabled: !busy && _history.isNotEmpty,
                  onTap: () {
                    Navigator.pop(ctx);
                    ReaderExportAndLineSheets.showWorldLines(
                      context,
                      lines: _session.lines,
                      activeLineId: _session.line.id,
                      canBranch: !busy && _history.isNotEmpty,
                      onSelect: (l) => _switchLine(l.id),
                      onRename: _renameLine,
                      onDelete: _deleteLine,
                      onPickBranch: () =>
                          ReaderExportAndLineSheets.showBranchPicker(
                        context,
                        history: _history,
                        onPickIndex: _branchFrom,
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('导出推演故事'),
                  subtitle: const Text('导出为 Markdown / TXT 物理文件并支持分享'),
                  onTap: () {
                    Navigator.pop(ctx);
                    ReaderExportAndLineSheets.showExportSheet(
                      context,
                      book: _slot.worldBook,
                      line: _session.line,
                      history: _history,
                      chronicle: _chronicle,
                      worldState: _worldState,
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: const Text('设置'),
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsScreen(
                          config: _config,
                          onConfigChanged: (c) {
                            setState(() {
                              _config = c;
                              _godMode = c.godMode;
                            });
                            widget.onConfigChanged(c);
                            _applyWakelock();
                          },
                        ),
                      ),
                    );
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackToLatestButton(ThemeData theme) {
    final palette = AppTheme.readingOf(context);
    return ListenableBuilder(
      listenable: _controller,
      builder: (ctx, _) {
        final show = !_atBottom &&
            (_hasNewStreamingContent ||
                (_controller.isBusy && _controller.hasLiveOutput));
        return Positioned(
          right: 18,
          bottom: 24,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            offset: show ? Offset.zero : const Offset(0, 1.5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              opacity: show ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !show,
                child: Material(
                  color: Colors.transparent,
                  elevation: 4,
                  borderRadius: BorderRadius.circular(20),
                  shadowColor: Colors.black.withValues(alpha: 0.25),
                  child: InkWell(
                    key: const ValueKey('back_to_latest_button'),
                    borderRadius: BorderRadius.circular(20),
                    onTap: _scrollToBottomAndFollow,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: palette.accent,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(Icons.arrow_downward_rounded,
                              size: 14, color: Colors.white),
                          SizedBox(width: 5),
                          Text(
                            '有新内容流出',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
