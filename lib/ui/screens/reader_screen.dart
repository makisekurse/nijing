import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_info.dart';
import '../../data/secure_store.dart';
import '../../models/app_config.dart';
import '../../models/chapter_node.dart';
import '../../models/save_slot.dart';
import '../../models/world_line.dart';
import '../../models/world_state.dart';
import '../../services/file_export_service.dart';
import '../../services/game_session.dart';
import '../../services/generation_controller.dart';
import '../../services/response_parser.dart';
import '../../services/save_service.dart';
import '../../services/runtime_log.dart';
import '../../services/story_export_service.dart';
import '../../services/text_layout.dart';
import '../../services/wakelock_service.dart';
import '../themes/app_theme.dart';
import '../widgets/chapter_toc_sheet.dart';
import '../widgets/choice_pill.dart';
import '../widgets/free_input_bar.dart';
import '../widgets/glossary_sheet.dart';
import '../widgets/live_thought_view.dart';
import '../widgets/thought_sheet.dart';
import '../widgets/world_line_tree.dart';
import 'cast_screen.dart';
import 'chronicle_screen.dart';
import 'settings_screen.dart';

/// 沉浸式阅读主视口。
///
/// 零 HUD：顶栏默认隐藏，轻触屏幕中央淡入、再次轻触或 3 秒无操作淡出。
/// 界面上**没有任何写死的剧本信息**，全部来自当前世界书。
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

  /// 状态与纯逻辑都在这里（可单测）；本类只负责展示与交互。
  late GameSession _session;

  // 读操作走 getter 委托，尽量少改动既有代码。
  List<ChapterNode> get _history => _session.history;
  String get _chronicle => _session.chronicle;
  WorldState get _worldState => _session.worldState;
  List<String> get _choices => _session.choices;

  bool _busy = false;
  String _pendingAction = '';
  String _live = '';
  String _notice = '';

  /// 提示是否「粘住」：终态提示（降级 / 中止）留到下次操作，
  /// 过程提示（正在重试…）在章节落定时必须清掉 —— 否则选项都出来了，
  /// 「输出未满足契约，正在改写重试」还挂在那儿。
  bool _noticeSticky = false;
  bool _degraded = false;

  bool _headerVisible = true;
  Timer? _headerTimer;

  final Map<int, GlobalKey> _chapterKeys = <int, GlobalKey>{};
  GlobalKey _chapterKeyFor(int index) =>
      _chapterKeys.putIfAbsent(index, () => GlobalKey());

  /// 托管自由输入框控制器与焦点，防止列表滚动及界面重建时草稿内容丢失。
  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();

  /// 主宰模式（最高权限）单次/全局运行状态，初始继承全局配置。
  late bool _godMode;

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
      _busy = true;
      _pendingAction = _controller.pendingAction;
      _live = _controller.live;
      _notice = _controller.notice;
      _noticeSticky = _controller.noticeSticky;
      _degraded = _controller.degraded;
    } else if (_controller.session != null) {
      _slot = _controller.lastSavedSlot ?? _slot;
      _session = _controller.session!;
      _notice = _controller.notice;
      _noticeSticky = _controller.noticeSticky;
      _degraded = _controller.degraded;
    } else if (_controller.lastSavedSlot != null) {
      _slot = _controller.lastSavedSlot!;
      _session = GameSession(_slot);
      _notice = _controller.notice;
      _noticeSticky = _controller.noticeSticky;
      _degraded = _controller.degraded;
    } else {
      _session = GameSession(_slot);
    }
    _controller.addListener(_onControllerUpdate);
    _scroll.addListener(_onScroll);
    _enterImmersive();
    _scheduleHeaderHide();
    _applyWakelock();
    _loadApiKey();
    _maybeJumpToLatest();
  }

  void _onControllerUpdate() {
    if (!mounted) return;
    final wasBusy = _busy;
    final prevLiveLength = _live.length;
    setState(() {
      _busy = _controller.isBusy;
      _pendingAction = _controller.pendingAction;
      _live = _controller.live;
      _notice = _controller.notice;
      _noticeSticky = _controller.noticeSticky;
      _degraded = _controller.degraded;
      if (!_atBottom && (_busy || wasBusy) && _live.length > prevLiveLength) {
        _hasNewStreamingContent = true;
      }
    });
    _follow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    WakelockService.disable();
    _headerTimer?.cancel();
    _controller.removeListener(_onControllerUpdate);
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

  // ---------- 沉浸模式 ----------
  //
  // 阅读时把系统状态栏与导航栏藏起来，让屏幕只剩文字。
  //
  // 用 immersiveSticky 而不是 immersive：从屏幕边缘上滑能临时唤出系统栏，
  // 几秒后自动缩回 —— 用户随时能看到时间和电量，不会觉得「被困住」。

  void _enterImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _exitImmersive() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  // ---------- 顶栏自动隐藏 ----------

  void _scheduleHeaderHide() {
    _headerTimer?.cancel();
    if (!_config.autoHideHeader) return;
    _headerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _headerVisible = false);
    });
  }

  /// 单击切换顶栏：
  /// - 未显示时单击屏幕显示顶栏（并启动 3 秒自动隐藏计时）；
  /// - 顶栏已显示时再次单击屏幕立即隐藏顶栏（并取消计时）。
  void _toggleHeader() {
    if (_headerVisible) {
      _headerTimer?.cancel();
      setState(() => _headerVisible = false);
    } else {
      setState(() => _headerVisible = true);
      _scheduleHeaderHide();
    }
  }

  /// 打开推演时跳到最新一幕。
  ///
  /// 「继续进入」的语义就是**接着上次的进度往下** —— 默认停在第一幕的话，
  /// 用户得手动翻到底，等于每次进来都要重新找位置。
  void _maybeJumpToLatest() {
    if (!_config.autoScrollToLatest) return;
    if (_history.isEmpty) return;
    _jumpToLatest();
  }

  /// 跳到最新一幕。切换世界线后也走这里。
  void _jumpToLatest() {
    if (_history.isEmpty) return;
    _hasNewStreamingContent = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _chapterKeyFor(_history.length - 1).currentContext;
      if (ctx != null) {
        _atBottom = true;
        _hasNewStreamingContent = false;
        Scrollable.ensureVisible(ctx, duration: Duration.zero, alignment: 1);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _atBottom = true;
        _hasNewStreamingContent = false;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    });
  }

  /// 精准平滑跳转定位到指定幕。
  void _jumpToChapter(int index) {
    if (index < 0 || index >= _history.length) return;
    _hasNewStreamingContent = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _chapterKeyFor(index).currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOut,
          alignment: 0.05,
        );
      }
    });
  }

  // ---------- 原始指针：区分「单击」、「划动」与「控件交互」 ----------
  //
  // 1. 单击：未拖动且未点在操作控件上时切换顶栏显隐。
  // 2. 划选与滚动：移动超过 12 像素视为滚动/划动，不触发展开或收回。
  // 3. 控件点击：若落在底部决策分支或操作按钮上，执行对应功能，不误切顶栏。
  // 4. 多指触摸与取消：基于 pointer id 跟踪主触摸点，防止多指或系统手势打断导致状态错乱。

  int? _activePointer;
  Offset? _pointerDown;
  bool _pointerMoved = false;
  bool _ignoreTapForHeader = false;

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

  // ---------- 滚动跟随 ----------
  //
  // 旧版每来一个 chunk 就强行滚到底，用户往回翻看前文会被反复拽走。
  // 现在只有「已经在底部附近」时才跟随。

  bool _atBottom = true;
  bool _hasNewStreamingContent = false;

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final cur = _scroll.position.pixels;
    // 只要距离底端大于 48px 即判定用户在往上翻阅前文，立即停止跟随；
    // 避免 120px 阈值过大导致用户刚往上滑一点又被强行拽回底部。
    final isBottom = (max - cur) <= 48;
    if (isBottom != _atBottom) {
      setState(() {
        _atBottom = isBottom;
        if (isBottom) {
          _hasNewStreamingContent = false;
        }
      });
    }
  }

  void _follow() {
    // 用户手指正按在屏幕上或不在最底端时，坚决不发起任何滚动动画，杜绝手势与动画互殴
    if (!_atBottom || _activePointer != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients || !_atBottom || _activePointer != null) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  void _scrollToBottomAndFollow() {
    setState(() {
      _atBottom = true;
      _hasNewStreamingContent = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  // ---------- 流式文本 ----------
  //
  // 2026-09-25 移除了打字机效果：它只是把已经到手的文字延迟显示，
  // 除了让人等之外没有实际价值，还额外引入一个 16ms 定时器与「跳过」状态。
  // 现在模型吐多少就显示多少。

  /// 丢掉当前这一轮的流式结果，从零重来。
  void _resetLive() {
    _live = '';
    _controller.reset();
  }

  // ---------- 生成 ----------

  Future<void> _act(String action, {bool? godMode}) async {
    if (_busy) return;
    final isGod = godMode ?? _godMode;
    if (_apiKey.isEmpty) {
      await _loadApiKey();
    }
    _atBottom = true;
    _follow();

    await _controller.startGeneration(
      session: _session,
      config: _config,
      apiKey: _apiKey,
      action: action,
      book: _slot.worldBook,
      godMode: isGod,
    );
    if (mounted) {
      _follow();
    }
  }

  String _apiKey = '';

  Future<void> _persist() async {
    await SaveService.upsert(_session.toSlot());
  }

  /// 重新生成当前这一幕。
  ///
  /// ⚠️ 必须先把 chronicle / worldState 恢复到**这一幕之前**的样子再重跑，
  /// 否则第二次生成会继承第一次留下的状态（例如「张某已死」还在），
  /// 整个状态就脏了。
  Future<void> _rerollLast() async {
    if (_busy || _history.isEmpty) return;
    final last = _history.last;
    final action = last.playerAction;
    if (action == null || action.trim().isEmpty) return;

    setState(() {
      // 弹出最后一幕，并把 chronicle / worldState 恢复到这一幕**之前**
      _session.popLastForReroll();
      _resetLive();
      _pendingAction = '';
      _notice = '';
      _noticeSticky = false;
    });
    await _act(action);
  }

  // ---------- 世界线 ----------
  //
  // 2026-09-25 改：原来的「回滚」是**单向销毁** —— 把后面的幕丢掉，
  // 只留一个会被下次覆盖的备份槽，而且没有任何入口能再打开它。
  //
  // 现在换成**世界线分支**：从第 k 幕分岔出一条新线，**原来的线原样保留**，
  // 玩家随时能在多条线之间查看和切换，各线的进度与选择记录互不干扰。

  /// 从第 [index] 幕分岔出一条新世界线，并切过去。
  Future<void> _branchFrom(int index) async {
    if (_busy) return;
    if (index < 0 || index >= _history.length) return;
    final chapterNo = _history[index].chapterIndex;

    final branch = _session.branchFrom(index);
    setState(() {
      _resetLive();
      _pendingAction = '';
      _notice = '已从第 $chapterNo 幕分岔出「${branch.name}」。'
          '原世界线已保留，可在「世界线」里随时切回。';
      _noticeSticky = false;
    });
    await _persist();
    _jumpToLatest();
  }

  /// 切换世界线。切换后正文、世界状态、编年史、可选行动全部换成那条线的。
  Future<void> _switchLine(String lineId) async {
    if (_busy) return;
    setState(() {
      _session.switchLine(lineId);
      _resetLive();
      _pendingAction = '';
      _notice = '';
      _noticeSticky = false;
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
    if (_busy) {
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
      _resetLive();
      _pendingAction = '';
    });
    await _persist();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  void _cancel() {
    _controller.cancel();
  }

  // ---------- 界面 ----------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fontSize = AppTheme.getFontSize(_config.fontSize);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                Expanded(
                  child: Listener(
                    behavior: HitTestBehavior.translucent,
                    onPointerDown: _onPointerDown,
                    onPointerMove: _onPointerMove,
                    onPointerUp: _onPointerUp,
                    onPointerCancel: _onPointerCancel,
                    child: SelectionArea(
                      child: ListView(
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                        children: <Widget>[
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _frontispiece(theme),
                              for (var i = 0; i < _history.length; i++)
                                _chapterView(
                                  theme,
                                  _history[i],
                                  fontSize,
                                  i,
                                  anchorKey: _chapterKeyFor(i),
                                ),
                              if (_busy || _live.isNotEmpty) _liveView(theme, fontSize),
                              if (_notice.isNotEmpty && (!_busy || _noticeSticky))
                                _noticeView(theme),
                            ],
                          ),
                          const SizedBox(height: 16),
                          SelectionContainer.disabled(
                            child: Listener(
                              behavior: HitTestBehavior.translucent,
                              onPointerDown: (_) => _ignoreTapForHeader = true,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  if (_choices.isNotEmpty && (_live.isEmpty || !_busy)) ...<Widget>[
                                    for (var i = 0; i < _choices.length; i++)
                                      ChoicePill(
                                        index: i + 1,
                                        text: _choices[i],
                                        enabled: !_busy,
                                        onTap: () => _act(_choices[i]),
                                      ),
                                    const SizedBox(height: 6),
                                  ] else if (!_busy && _history.isEmpty && _choices.isEmpty) ...<Widget>[
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 12),
                                      child: SizedBox(
                                        width: double.infinity,
                                        child: FilledButton.icon(
                                          onPressed: () => _act(''),
                                          icon: const Icon(Icons.auto_stories_rounded,
                                              size: 18),
                                          label: const Text('开始推演'),
                                          style: FilledButton.styleFrom(
                                            backgroundColor:
                                                theme.colorScheme.primary,
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 14),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                  FreeInputBar(
                                    busy: _busy,
                                    controller: _inputController,
                                    focusNode: _inputFocusNode,
                                    godMode: _godMode,
                                    onToggleGodMode: (v) =>
                                        setState(() => _godMode = v),
                                    onSend: (text) =>
                                        _act(text, godMode: _godMode),
                                    onCancel: _cancel,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 32),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
            _header(theme),
            _buildBackToLatestButton(theme),
          ],
        ),
      ),
    );
  }

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
                // 目录 / 编年史 / 人物志 / 世界观察 / 更多 —— 顶栏就是内容入口
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
                  onTap: _showWorldState,
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

  /// 顶栏第二行：极轻量。有分支时把当前世界线名也带上。
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

  /// 世界观察：默认收起，只在用户主动点开时才展开。
  /// 普通玩家只看小说，想看局势的人才用得到。
  void _showWorldState() {
    final theme = Theme.of(context);
    final s = _worldState;

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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  '世界观察',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 14),
                Flexible(
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: s.isEmpty
                        ? Text(
                            '还没有世界状态。\n推演一幕之后，这里会记录此刻的时间、'
                            '地点、人物关系与未决之事。',
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.8,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.6),
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              _stateSection(theme, '当前位置',
                                  s.location.isEmpty ? '—' : s.location),
                              _stateSection(theme, '当前时间',
                                  s.time.isEmpty ? '—' : s.time),
                              if (s.relations.isNotEmpty)
                                _stateSection(
                                  theme,
                                  '重要人物',
                                  s.relations.entries
                                      .map((e) => '${e.key} · ${e.value}')
                                      .join('\n'),
                                ),
                              if (s.events.isNotEmpty)
                                _stateSection(
                                    theme, '正在发生', s.events.join('\n')),
                              if (s.facts.isNotEmpty)
                                _stateSection(
                                    theme, '你已知晓', s.facts.join('\n')),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stateSection(ThemeData theme, String title, String body) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.7,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      );

  void _openMenu() {
    final theme = Theme.of(context);
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
                    _showWorldState();
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
                  enabled: !_busy && _history.isNotEmpty,
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
                  enabled: !_busy && _history.isNotEmpty,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showWorldLines();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('导出推演故事'),
                  subtitle: const Text('导出为 Markdown / TXT 物理文件并支持分享'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showExportSheet();
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

  void _showExportSheet() {
    final theme = Theme.of(context);
    final palette = AppTheme.readingOf(context);

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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '导出推演故事',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '将当前世界线的长篇小说按章节规范排版导出。支持保存为物理文件至系统下载目录，以及系统原生分享与复制。',
                    style: TextStyle(
                        fontSize: 12, height: 1.5, color: palette.muted),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    leading: const Icon(Icons.file_present_rounded),
                    title: const Text('导出为 Markdown 文件（.md）'),
                    subtitle: const Text('保存至系统下载目录，带标题层级、抉择与大事记'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _exportStoryFile(isMarkdown: true);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('导出为纯文本文件（.txt）'),
                    subtitle: const Text('保存至系统下载目录，带全角缩进与分段的小说纯文本'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await _exportStoryFile(isMarkdown: false);
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.copy_rounded),
                    title: const Text('复制为 Markdown 格式'),
                    subtitle: const Text('仅复制结构化 Markdown 文本到剪贴板'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final md = StoryExportService.toMarkdown(
                        book: _slot.worldBook,
                        line: _session.line,
                        history: _history,
                        chronicle: _chronicle,
                        worldState: _worldState,
                      );
                      await Clipboard.setData(ClipboardData(text: md));
                      if (mounted) _toast('Markdown 故事已复制到剪贴板（${md.length} 字）');
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.content_copy_rounded),
                    title: const Text('复制为纯文本小说'),
                    subtitle: const Text('仅复制纯文本小说内容到剪贴板'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final txt = StoryExportService.toPlainText(
                        book: _slot.worldBook,
                        line: _session.line,
                        history: _history,
                        chronicle: _chronicle,
                        worldState: _worldState,
                      );
                      await Clipboard.setData(ClipboardData(text: txt));
                      if (mounted) _toast('纯文本小说已复制到剪贴板（${txt.length} 字）');
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _exportStoryFile({required bool isMarkdown}) async {
    final bookName = _slot.worldBook.name.trim().isEmpty
        ? '推演故事'
        : _slot.worldBook.name.trim();
    final lineName =
        _session.line.name.trim().isEmpty ? '主线' : _session.line.name.trim();
    final ts = FileExportService.formatTimestamp();
    final ext = isMarkdown ? 'md' : 'txt';
    final mimeType = isMarkdown ? 'text/markdown' : 'text/plain';
    final fileName =
        '拟境_${FileExportService.sanitizeFileName(bookName)}_${FileExportService.sanitizeFileName(lineName)}_第${_history.length}幕_$ts.$ext';

    final content = isMarkdown
        ? StoryExportService.toMarkdown(
            book: _slot.worldBook,
            line: _session.line,
            history: _history,
            chronicle: _chronicle,
            worldState: _worldState,
          )
        : StoryExportService.toPlainText(
            book: _slot.worldBook,
            line: _session.line,
            history: _history,
            chronicle: _chronicle,
            worldState: _worldState,
          );

    final res = await FileExportService.exportFile(
      fileName: fileName,
      content: content,
      mimeType: mimeType,
    );

    await Clipboard.setData(ClipboardData(text: content));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          res.success
              ? '已导出保存至：${res.path}\n（已同时复制到剪贴板）'
              : '保存失败：${res.message}（已复制到剪贴板）',
        ),
        action: SnackBarAction(
          label: '系统分享',
          onPressed: () async {
            if (res.success && res.path != null) {
              final ok = await FileExportService.shareFile(
                filePath: res.path!,
                title: '${_slot.worldBook.name} · 推演故事',
                mimeType: mimeType,
              );
              if (!ok) {
                await FileExportService.shareText(
                  title: '${_slot.worldBook.name} · 推演故事',
                  text: content,
                );
              }
            } else {
              await FileExportService.shareText(
                title: '${_slot.worldBook.name} · 推演故事',
                text: content,
              );
            }
          },
        ),
      ),
    );
  }

  /// 世界线管理：以时空分岔树直观展示各线关系，可切换 / 重命名 / 删除 / 分岔。
  void _showWorldLines() {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);

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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    '世界线时空分岔树',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                  child: Text(
                    '清晰展示从第几幕分岔、走向与幕数。轻触任一条即可直接切换过去。',
                    style: TextStyle(fontSize: 11.5, height: 1.6, color: muted),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: WorldLineTreeView(
                    lines: _session.lines,
                    activeLineId: _session.line.id,
                    onSelect: (l) {
                      Navigator.pop(ctx);
                      _switchLine(l.id);
                    },
                    onRename: (l) {
                      Navigator.pop(ctx);
                      _renameLine(l);
                    },
                    onDelete: (l) {
                      Navigator.pop(ctx);
                      _deleteLine(l);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.call_split_rounded),
                  title: const Text('从某一幕分岔出新世界线'),
                  subtitle: const Text('保留到那一幕，之后重新做选择'),
                  enabled: !_busy && _history.isNotEmpty,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showBranchPicker();
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


  /// 分岔点选择：从哪一幕分出去。
  void _showBranchPicker() {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: theme.scaffoldBackgroundColor,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  '从哪一幕分岔？',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  '保留到该幕为止的剧情，之后重新做选择。'
                  '当前世界线会原样保留，不会丢。',
                  style: TextStyle(fontSize: 11.5, height: 1.6, color: muted),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  itemCount: _history.length,
                  itemBuilder: (_, i) {
                    final node = _history[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '第 ${node.chapterIndex} 幕'
                        '${node.date.isEmpty ? '' : ' · ${node.date}'}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: node.playerAction == null
                          ? null
                          : Text(
                              node.playerAction!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _branchFrom(i);
                      },
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  /// 渲染一个正文段落。
  ///
  /// ⚠️ 段首缩进用 **WidgetSpan 里的固定宽度盒子**，而不是几个全角空格。
  ///
  /// 2026-09-25 排查结论：代码与配置链路都是对的（`indent()` 用的确实是
  /// U+3000，逐字节验过；设置 → copyWith → toJson → reader 也通），
  /// 问题出在**文本排版层把行首空白吃掉了** —— 两端对齐时行首空白会被
  /// 当作 hanging whitespace 处理。
  ///
  /// 占位盒子是布局实体，shaper 折叠不了它，所以缩进**必然**生效。
  Widget _paragraph(
    String text, {
    required double fontSize,
    required Color color,
    TextAlign align = TextAlign.justify,
  }) {
    final indentPx = _config.paragraphIndent * fontSize;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          if (indentPx > 0)
            WidgetSpan(
              child: SizedBox(width: indentPx, height: fontSize),
              alignment: PlaceholderAlignment.middle,
            ),
          TextSpan(text: text),
        ],
      ),
      textAlign: align,
      style: TextStyle(
        fontSize: fontSize,
        height: _config.lineHeight,
        letterSpacing: 0.4,
        color: color,
      ),
    );
  }

  Widget _frontispiece(ThemeData theme) {
    final book = _slot.worldBook;
    final palette = AppTheme.readingOf(context);
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 26),
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.rule)),
      ),
      child: Column(
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              border: Border.all(color: palette.accent, width: 1.1),
              borderRadius: BorderRadius.circular(2),
            ),
            child: Text(
              AppInfo.appName,
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 2,
                fontWeight: FontWeight.w600,
                color: palette.accent,
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            book.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              height: 1.35,
              color: palette.ink,
            ),
          ),
          if (book.era.trim().isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              book.era.trim(),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: palette.muted),
            ),
          ],
          const SizedBox(height: 14),
          Container(width: 36, height: 2, color: palette.accent),
          const SizedBox(height: 12),
          Text(
            '你扮演：${book.playerRole.trim()}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: palette.muted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chapterView(
    ThemeData theme,
    ChapterNode chapter,
    double fontSize,
    int index, {
    Key? anchorKey,
  }) {
    final palette = AppTheme.readingOf(context);
    final act = chapter.playerAction;
    return Column(
      key: anchorKey,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (act != null && act.trim().isNotEmpty) _actionCard(theme, act),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  chapter.date.trim().isEmpty
                      ? chapter.title
                      : '${chapter.title} · ${chapter.date.trim()}',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.1,
                    color: palette.accent,
                  ),
                ),
              ),
              if (chapter.glossary.isNotEmpty)
                _miniAction(
                  theme,
                  Icons.info_outline_rounded,
                  () => AnnotationSheet.showGlossary(context, chapter.glossary),
                ),
              if (chapter.cast.isNotEmpty)
                _miniAction(
                  theme,
                  Icons.groups_outlined,
                  () => AnnotationSheet.showCast(context, chapter.cast),
                ),
              if (chapter.thought.isNotEmpty)
                _miniAction(
                  theme,
                  Icons.psychology_outlined,
                  () => ThoughtSheet.show(
                    context,
                    title: chapter.title,
                    thought: chapter.thought,
                  ),
                ),
              _miniAction(
                theme,
                Icons.more_horiz_rounded,
                () => _chapterMenu(chapter),
              ),
            ],
          ),
        ),
        for (final para in TextLayout.paragraphs(chapter.content))
          Padding(
            padding: EdgeInsets.only(
              bottom: TextLayout.spacing(_config.paragraphSpacing),
            ),
            child: _paragraph(para, fontSize: fontSize, color: palette.ink),
          ),
        Divider(height: 26, color: palette.rule),
      ],
    );
  }

  Widget _miniAction(ThemeData theme, IconData icon, VoidCallback onTap) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _ignoreTapForHeader = true,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Icon(
            icon,
            size: 16,
            color: theme.colorScheme.primary.withValues(alpha: 0.75),
          ),
        ),
      ),
    );
  }

  /// 本幕操作菜单。复制与原始输出都收在这里，不占用正文空间，
  /// 也不破坏「像小说阅读器」的观感。
  void _chapterMenu(ChapterNode chapter) {
    final theme = Theme.of(context);
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
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('复制本幕'),
                  subtitle: const Text('标题 + 你的行动 + 正文'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _copyChapter(chapter);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit_note_rounded),
                  title: const Text('修改错字 / 编辑本幕'),
                  subtitle: const Text('就地修正本幕正文中的错别字并保存'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _editChapterContentDialog(chapter);
                  },
                ),
                if (chapter.thought.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.psychology_outlined),
                    title: const Text('推演思考'),
                    subtitle: const Text('查看模型生成本幕时的思维链过程'),
                    onTap: () {
                      Navigator.pop(ctx);
                      ThoughtSheet.show(
                        context,
                        title: chapter.title,
                        thought: chapter.thought,
                      );
                    },
                  ),
                if (chapter.glossary.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.menu_book_rounded),
                    title: const Text('本幕词条'),
                    onTap: () {
                      Navigator.pop(ctx);
                      AnnotationSheet.showGlossary(context, chapter.glossary);
                    },
                  ),
                if (chapter.cast.isNotEmpty)
                  ListTile(
                    leading: const Icon(Icons.groups_rounded),
                    title: const Text('本幕人物'),
                    onTap: () {
                      Navigator.pop(ctx);
                      AnnotationSheet.showCast(context, chapter.cast);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.data_object_rounded),
                  title: const Text('查看原始输出'),
                  subtitle: Text(
                    chapter.rawOutput.isEmpty
                        ? '本幕没有留存原始输出'
                        : '模型返回的原文，用于排查格式问题',
                  ),
                  enabled: chapter.rawOutput.isNotEmpty,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showRawOutput(chapter);
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.bug_report_outlined),
                  title: const Text('导出运行日志'),
                  subtitle: Text(
                    RuntimeLog.enabled
                        ? '本次会话已记录 ${RuntimeLog.count} 条，用于排查生成异常'
                        : '日志未开启 —— 请先在「我的 → 调试与日志」里打开',
                  ),
                  enabled: RuntimeLog.enabled && RuntimeLog.count > 0,
                  onTap: () {
                    Navigator.pop(ctx);
                    _exportRuntimeLog();
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

  Future<void> _editChapterContentDialog(ChapterNode chapter) async {
    final ctrl = TextEditingController(text: chapter.content);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '修改正文 · ${chapter.title}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            maxLines: 14,
            autofocus: true,
            style: const TextStyle(fontSize: 13.5, height: 1.6),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '输入修正后的正文内容…',
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('保存修改'),
          ),
        ],
      ),
    );
    ctrl.dispose();

    if (saved == null || !mounted) return;
    if (saved.trim().isEmpty) {
      _toast('正文内容不能为空');
      return;
    }
    final index = _history.indexOf(chapter);
    if (index < 0) return;

    setState(() {
      _session.editChapterContent(index, saved);
    });
    await _persist();
    _toast('第 ${chapter.chapterIndex} 幕正文已更新并保存。');
  }

  Future<void> _copyChapter(ChapterNode chapter) async {
    final sb = StringBuffer();
    sb.writeln(chapter.date.trim().isEmpty
        ? chapter.title
        : '${chapter.title} · ${chapter.date.trim()}');
    final act = chapter.playerAction;
    if (act != null && act.trim().isNotEmpty) {
      sb.writeln();
      sb.writeln('【你的行动】${act.trim()}');
    }
    if (chapter.content.trim().isNotEmpty) {
      sb.writeln();
      sb.writeln(chapter.content.trim());
    }
    await Clipboard.setData(ClipboardData(text: sb.toString().trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本幕已复制到剪贴板')),
    );
  }

  /// 排障用：直接把模型返回的原文摊开。
  /// 「为什么这次 cast 又漏了」——不用再猜，看一眼就知道。
  void _showRawOutput(ChapterNode chapter) {
    final theme = Theme.of(context);
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        '模型原始输出',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: chapter.rawOutput),
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('原始输出已复制')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_rounded, size: 16),
                      label: const Text('复制'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    child: SelectableText(
                      chapter.rawOutput,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.6,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurface
                            .withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 排障用：把本次会话的运行日志导出成物理文件。
  Future<void> _exportRuntimeLog() async {
    final text = RuntimeLog.dump();
    final ts = FileExportService.formatTimestamp();
    final res = await FileExportService.exportFile(
      fileName: '拟境_运行日志_$ts.txt',
      content: text,
      mimeType: 'text/plain',
    );
    if (res.success) {
      RuntimeLog.i('App', '运行日志已导出：${res.path}');
    }
    if (!mounted) return;
    if (res.success && res.path != null) {
      final ok = await FileExportService.shareFile(
        filePath: res.path!,
        title: '拟境 · 运行日志',
        mimeType: 'text/plain',
      );
      if (!ok) {
        await FileExportService.shareText(
          title: '拟境 · 运行日志',
          text: text,
        );
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          res.success
              ? '运行日志（${RuntimeLog.count} 条）已保存至：${res.path}'
              : '导出失败：${res.message}',
        ),
        action: SnackBarAction(
          label: '系统分享',
          onPressed: () async {
            if (res.success && res.path != null) {
              final ok = await FileExportService.shareFile(
                filePath: res.path!,
                title: '拟境 · 运行日志',
                mimeType: 'text/plain',
              );
              if (!ok) {
                await FileExportService.shareText(
                  title: '拟境 · 运行日志',
                  text: text,
                );
              }
            } else {
              await FileExportService.shareText(
                title: '拟境 · 运行日志',
                text: text,
              );
            }
          },
        ),
      ),
    );
  }

  /// 视口停泊浮动按钮：流式涌入或有新内容流出且用户手动向上滚动查看前文时，
  /// 右下角浮出精致胶囊按钮（“↓ 有新内容流出”）；点击后平滑滚回最新行并恢复跟随。
  Widget _buildBackToLatestButton(ThemeData theme) {
    final palette = AppTheme.readingOf(context);
    final show = !_atBottom &&
        (_hasNewStreamingContent || (_busy && _live.isNotEmpty));

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
                    horizontal: 14,
                    vertical: 8,
                  ),
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
                      Icon(
                        Icons.arrow_downward_rounded,
                        size: 14,
                        color: Colors.white,
                      ),
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
  }

  Widget _actionCard(ThemeData theme, String act) {
    final palette = AppTheme.readingOf(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.07),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
        border: Border(
          left: BorderSide(color: palette.accent, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '【你的行动】 ',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: palette.accent,
            ),
          ),
          Expanded(
            child: Text(
              act,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.5,
                color: palette.ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _liveView(ThemeData theme, double fontSize) {
    final palette = AppTheme.readingOf(context);
    // 思考块不丢弃 —— 拆出来单独显示。
    // 推演进行期间只要有思考，思考面板全程常驻在正文上方，用户展开后绝不自动关闭；
    // 本幕完成后平滑过渡到章节菜单的思维链查看。
    final (thought, preview) = ResponseParser.splitLive(_live);
    final hasThought = thought.isNotEmpty;
    final statusText = _busy
        ? (_degraded
            ? '本地降级中…'
            : (preview.isEmpty && hasThought ? '推演思考中…' : '推演中…'))
        : '推演中断（已保留现场）';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_pendingAction.isNotEmpty) _actionCard(theme, _pendingAction),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: <Widget>[
              if (_busy)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(palette.accent),
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
                statusText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.accent,
                ),
              ),
            ],
          ),
        ),
        if (hasThought)
          LiveThoughtView(
            key: const ValueKey('live_thought_view'),
            thought: thought,
            initialExpanded: _controller.thoughtExpanded,
            onExpansionChanged: (v) => _controller.thoughtExpanded = v,
          ),
        if (preview.isNotEmpty)
          _paragraph(preview, fontSize: fontSize, color: palette.ink),
      ],
    );
  }

  Widget _noticeView(ThemeData theme) {
    final palette = AppTheme.readingOf(context);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.rule),
      ),
      child: Text(
        _notice,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.6,
          color: palette.ink,
        ),
      ),
    );
  }

  bool _apiKeyLoaded = false;

  Future<void> _loadApiKey() async {
    if (_apiKeyLoaded) return;
    _apiKeyLoaded = true;
    final key = await SecureStore.readApiKey();
    if (mounted) setState(() => _apiKey = key);
  }
}
