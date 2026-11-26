import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../data/secure_store.dart';
import '../../models/app_config.dart';
import '../../models/chapter_node.dart';
import '../../models/model_profile.dart';
import '../../models/save_slot.dart';
import '../../models/world_line.dart';
import '../../models/world_state.dart';
import '../../services/game_session.dart';
import '../../services/generation_controller.dart';
import '../../services/providers.dart';
import '../../services/save_service.dart';
import '../../services/wakelock_service.dart';
import '../../state/config_provider.dart';
import '../themes/app_theme.dart';
import '../themes/surface_ladder.dart';
import '../widgets/app_toast.dart';
import '../widgets/reader_chapter_card.dart';
import '../widgets/reader_composer.dart';
import '../widgets/reader_drawer.dart';
import '../widgets/reader_paragraph.dart';
import '../widgets/reader_sheets.dart';
import '../widgets/reader_typography_sheet.dart';
import '../widgets/reader_world_line_sheets.dart';
import '../widgets/thinking_capsule.dart';
import 'cast_screen.dart';
import 'chronicle_screen.dart';
import 'settings_screen.dart';

/// 拟境 v2.0 现代 AI 剧场阅读器。
///
/// 核心升级：
/// 1. 彻底废除旧版 1087 行自研指针拦截与顶栏乱闪，采用克制稳重顶栏 + 固定贴底交互舱 + 右侧统一抽屉；
/// 2. 接入 Kelivo 同款 `SuperSliverList` + `ListController`，超长剧情实现零估算精准跳幕；
/// 3. 绝不清屏重写：断流/暂停原地保留正文，底部交互舱无缝提供「继续生成 / 直接落幕 / 重试」；
/// 4. 集成呼吸感思考胶囊（正文一出自动折叠）与 Anx Reader 风格的「页内实时排版浮层」；
/// 5. 支持跨厂商主辅双模型各自独立加密 Key 解析与页内一键切换模型档案。
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
  final ListController _listController = ListController();
  late GenerationController _controller;

  late AppConfig _config;
  late SaveSlot _slot;
  late GameSession _session;

  List<ChapterNode> get _history => _session.history;
  String get _chronicle => _session.chronicle;
  WorldState get _worldState => _session.worldState;
  List<String> get _choices => _session.choices;

  final TextEditingController _inputController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  late bool _godMode;

  int _lastHistoryLen = 0;
  int _lastLiveLen = 0;
  bool _atBottom = true;
  bool _hasNewStreamingContent = false;
  bool _followScheduled = false;
  bool _choicesExpanded = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _config = widget.config;
    _godMode = _config.godMode;
    _slot = widget.slot;
    _controller = GenerationController.forSlot(_slot.id);

    if (_controller.isBusy || _controller.isInterrupted) {
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
    _lastLiveLen =
        _controller.liveThought.length + _controller.liveBodyPreview.length;

    _controller.addListener(_onControllerEvent);
    _scroll.addListener(_onScroll);
    _applyWakelock();
    _maybeJumpToLatest();
  }

  ConfigProvider? _maybeConfigProvider() {
    try {
      return Provider.of<ConfigProvider>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  AppConfig _effectiveConfig() {
    final p = _maybeConfigProvider();
    return p?.config ?? _config;
  }

  void _applyConfigUpdate(AppConfig next, {bool immediate = true}) {
    setState(() {
      _config = next;
      _godMode = next.godMode;
    });
    final p = _maybeConfigProvider();
    if (p != null) {
      p.updateConfig(next, immediate: immediate);
    } else {
      widget.onConfigChanged(next);
    }
    _applyWakelock();
  }

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
      setState(() {
        _choicesExpanded = true;
      });
      _scheduleFollow(smooth: true);
      return;
    }

    // 后台档案官更新了最后一幕状态摘要时轻刷列表
    if (!_controller.isBusy && !_controller.extractingInBackground) {
      setState(() {});
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
    _controller.removeListener(_onControllerEvent);
    _scroll.removeListener(_onScroll);
    _listController.dispose();
    _scroll.dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
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
    if (_effectiveConfig().keepScreenOn) {
      WakelockService.enable();
    } else {
      WakelockService.disable();
    }
  }

  // ---------- 滚动与 SuperSliverList 精准跳幕 ----------

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

  /// 借助 `super_sliver_list` 实现零估算精准跳到任意第 N 幕。
  void _jumpToChapter(int index) {
    if (index < 0 || index >= _history.length) return;
    _hasNewStreamingContent = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_listController.isAttached) {
        _listController.animateToItem(
          index: index,
          scrollController: _scroll,
          alignment: 0.04,
          duration: (_) => const Duration(milliseconds: 280),
          curve: (_) => Curves.easeOutCubic,
        );
      }
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final cur = _scroll.position.pixels;
    final isBottom = (max - cur) <= 52;
    if (isBottom != _atBottom) {
      setState(() {
        _atBottom = isBottom;
        if (isBottom) _hasNewStreamingContent = false;
      });
    }
  }

  bool _onUserScroll(UserScrollNotification n) {
    if (n.direction == ScrollDirection.forward) {
      // 用户主动上滑阅读前文：立刻解除自动跟底 + 自动折叠建议分支让出大视野
      if (_atBottom || _choicesExpanded) {
        setState(() {
          _atBottom = false;
          if (_choicesExpanded && _choices.isNotEmpty) {
            _choicesExpanded = false;
          }
        });
      }
    }
    return false;
  }

  void _scheduleFollow({required bool smooth}) {
    if (!_atBottom || _followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_scroll.hasClients || !_atBottom) return;
      final max = _scroll.position.maxScrollExtent;
      if (smooth) {
        _scroll.animateTo(
          max,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
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

  // ---------- 推演、续写与多厂商分槽密钥解析 ----------

  Future<(String mainKey, String auxKey, AppConfig cfg)> _resolveRuntimeAuth() async {
    final cfgProvider = _maybeConfigProvider();
    final cfg = cfgProvider?.config ?? _config;
    final mainKey = cfgProvider != null
        ? await cfgProvider.resolveActiveMainKey()
        : await SecureStore.readMainKeyForConfig(cfg);
    final auxKey = cfgProvider != null
        ? await cfgProvider.resolveActiveAuxKey()
        : await SecureStore.readAuxKeyForConfig(cfg);
    return (mainKey, auxKey, cfg);
  }

  Future<void> _act(String action, {bool? godMode}) async {
    if (_controller.isBusy) return;
    final isGod = godMode ?? _godMode;
    final (mainKey, auxKey, cfg) = await _resolveRuntimeAuth();
    if (!mounted) return;
    _atBottom = true;
    _scheduleFollow(smooth: true);

    await _controller.startGeneration(
      session: _session,
      config: cfg,
      apiKey: mainKey,
      auxApiKey: auxKey,
      action: action,
      book: _slot.worldBook,
      godMode: isGod,
    );
    if (mounted) _scheduleFollow(smooth: true);
  }

  Future<void> _continueInterrupted() async {
    final (mainKey, auxKey, cfg) = await _resolveRuntimeAuth();
    if (!mounted) return;
    _atBottom = true;
    _scheduleFollow(smooth: true);
    await _controller.continueGeneration(
      latestApiKey: mainKey,
      latestAuxApiKey: auxKey,
      latestConfig: cfg,
    );
    if (mounted) _scheduleFollow(smooth: true);
  }

  Future<void> _retryInterrupted() async {
    final (mainKey, auxKey, cfg) = await _resolveRuntimeAuth();
    if (!mounted) return;
    _atBottom = true;
    _scheduleFollow(smooth: true);
    await _controller.retryLast(
      latestApiKey: mainKey,
      latestAuxApiKey: auxKey,
      latestConfig: cfg,
    );
  }

  Future<void> _persist() async {
    await SaveService.upsert(_session.toSlot());
  }

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
      _choicesExpanded = true;
      _controller.notice =
          '已从第 $chapterNo 幕分岔出「${branch.name}」。原世界线已保留，可在右侧抽屉随时切回。';
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
      _choicesExpanded = true;
    });
    await _persist();
    _jumpToLatest();
  }

  Future<void> _renameLine(WorldLine target) async {
    final ctrl = TextEditingController(text: target.name);
    final name = await showFDialog<String>(
      context: context,
      builder: (ctx, style, anim) => FDialog(
        animation: anim,
        style: style,
        builder: (c, s) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('重命名世界线', style: s.titleTextStyle),
              const SizedBox(height: 12),
              FTextField(
                control: FTextFieldControl.managed(controller: ctrl),
                autofocus: true,
                hint: '例如：走西南路线',
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FButton(
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c, ctrl.text),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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
    final ok = await showFDialog<bool>(
      context: context,
      builder: (ctx, style, anim) => FDialog(
        animation: anim,
        style: style,
        builder: (c, s) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('删除「${target.name}」？', style: s.titleTextStyle),
              const SizedBox(height: 8),
              Text(
                '它的 ${target.chapterCount} 幕进度会一起消失，无法恢复。',
                style: s.bodyTextStyle,
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c, false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FButton(
                      variant: FButtonVariant.destructive,
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c, true),
                      child: const Text('删除'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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
    _toast('第 ${chapter.chapterIndex} 幕正文已更新');
  }

  /// 阅读页顶栏快捷切换已保存的多模型档案。
  Future<void> _showQuickModelSwitch() async {
    final cfgProvider = _maybeConfigProvider();
    final cfg = _effectiveConfig();
    final palette = AppTheme.readingOf(context);
    final profiles = cfg.savedProfiles;

    await showFSheet<void>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.72,
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: palette.page,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: palette.muted.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Text(
                    '切换主力模型',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '当前：${Providers.byId(cfg.apiProvider).shortLabel} · ${Providers.resolveModelName(cfg)}',
                    style: TextStyle(fontSize: 12.5, color: palette.muted),
                  ),
                  const SizedBox(height: 14),
                  if (profiles.isNotEmpty)
                    FTileGroup(
                      label: const Text('已保存的模型档案'),
                      children: <FTileMixin>[
                        for (final ModelProfile p in profiles)
                          FTile(
                            prefix: Icon(
                              LucideIcons.cpu,
                              size: 16,
                              color: palette.accent,
                            ),
                            title: Text(p.name),
                            subtitle: Text(
                              '${Providers.byId(p.apiProvider).shortLabel} · ${p.modelName}',
                            ),
                            suffix: (cfg.activeProfileId.isNotEmpty
                                    ? p.id == cfg.activeProfileId
                                    : (p.modelName == cfg.modelName &&
                                        p.apiProvider == cfg.apiProvider &&
                                        p.baseUrl == cfg.baseUrl &&
                                        p.workspaceId == cfg.workspaceId))
                                ? Icon(
                                    LucideIcons.check,
                                    size: 16,
                                    color: palette.accent,
                                  )
                                : null,
                            onPress: () async {
                              Navigator.pop(ctx);
                              if (cfgProvider != null) {
                                await cfgProvider.applyProfile(p);
                                if (mounted) {
                                  setState(() => _config = cfgProvider.config);
                                  _toast('已切换至 ${p.name}');
                                }
                              } else {
                                _applyConfigUpdate(cfg.applyProfile(p));
                              }
                            },
                          ),
                      ],
                    )
                  else
                    FCard(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          '还没有保存多个模型档案。前往「模型与接口设置」添加不同服务商或模型档案后，即可在这里一键切换且自动切换独立加密 Key。',
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.6,
                            color: palette.muted,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  FButton(
                    variant: FButtonVariant.outline,
                    prefix: const Icon(LucideIcons.settings2, size: 15),
                    onPress: () {
                      Navigator.pop(ctx);
                      _openSettings(section: SettingsSection.model);
                    },
                    child: const Text('管理模型与 API Key'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openSettings({
    SettingsSection section = SettingsSection.all,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsScreen(
          config: _effectiveConfig(),
          onConfigChanged: _applyConfigUpdate,
          section: section,
        ),
      ),
    );
    if (mounted) {
      setState(() => _config = _effectiveConfig());
    }
  }

  void _openTypographySheet() {
    ReaderTypographySheet.show(
      context,
      readConfig: _effectiveConfig,
      onApply: _applyConfigUpdate,
    );
  }

  void _openDrawer() {
    ReaderDrawer.show(
      context,
      book: _slot.worldBook,
      worldState: _worldState,
      chronicle: _chronicle,
      history: _history,
      lines: _session.lines,
      activeLineId: _session.line.id,
      busy: _controller.isBusy,
      onJumpToChapter: _jumpToChapter,
      onSelectLine: (l) => _switchLine(l.id),
      onRenameLine: _renameLine,
      onDeleteLine: _deleteLine,
      onPickBranch: () => ReaderExportAndLineSheets.showBranchPicker(
        context,
        history: _history,
        onPickIndex: _branchFrom,
      ),
      onOpenCast: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CastScreen(history: _history),
        ),
      ),
      onOpenChronicle: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChronicleScreen(history: _history),
        ),
      ),
      onExportStory: () => ReaderExportAndLineSheets.showExportSheet(
        context,
        book: _slot.worldBook,
        line: _session.line,
        history: _history,
        chronicle: _chronicle,
        worldState: _worldState,
      ),
      onOpenTypography: _openTypographySheet,
      onOpenSettings: _openSettings,
      onRerollLast: _rerollLast,
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.show(context, msg);
  }

  // ---------- 界面构建 ----------

  @override
  Widget build(BuildContext context) {
    final cfg = _maybeConfigProvider() != null
        ? context.watch<ConfigProvider>().config
        : _config;
    _config = cfg;

    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);
    final fontSize = AppTheme.getFontSize(cfg.fontSize);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final overlayStyle = (isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark)
        .copyWith(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    );

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: overlayStyle,
      child: Scaffold(
        backgroundColor: palette.page,
        body: Column(
        children: <Widget>[
          // 1. 克制、稳定的现代顶栏（绝不再 3 秒自动乱闪，明确返回按钮）
          _buildTopBar(palette, ladder, cfg),

          // 2. 丝滑正文流（SuperSliverList 零估算精准跳幕 + 局部流式订阅）
          Expanded(
            child: Stack(
              children: <Widget>[
                NotificationListener<UserScrollNotification>(
                  onNotification: _onUserScroll,
                  child: SelectionArea(
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(
                        parent: BouncingScrollPhysics(),
                      ),
                      slivers: <Widget>[
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          sliver: SliverToBoxAdapter(
                            child: ReaderFrontispiece(book: _slot.worldBook),
                          ),
                        ),
                        SliverPadding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          sliver: SuperSliverList.builder(
                            listController: _listController,
                            itemCount: _history.length,
                            itemBuilder: (ctx, i) {
                              final chapter = _history[i];
                              return ReaderChapterCard(
                                chapter: chapter,
                                config: cfg,
                                fontSize: fontSize,
                                isLastChapter: i == _history.length - 1,
                                busy: _controller.isBusy,
                                onCopy: () =>
                                    ReaderExportAndLineSheets.copyChapter(
                                  context,
                                  chapter,
                                ),
                                onEdit: () => _editChapter(chapter),
                                onBranchHere: () => _branchFrom(i),
                                onReroll: i == _history.length - 1
                                    ? _rerollLast
                                    : null,
                                onOpenState: _openDrawer,
                                onOpenMenu: () => ReaderSheets.showChapterMenu(
                                  context,
                                  chapter: chapter,
                                  onCopy: () =>
                                      ReaderExportAndLineSheets.copyChapter(
                                    context,
                                    chapter,
                                  ),
                                  onEdit: () => _editChapter(chapter),
                                  onExportLog: () =>
                                      ReaderExportAndLineSheets.exportRuntimeLog(
                                    context,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        // 实时流式区（仅局部响应 GenerationController，历史幕零重绘）
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                          sliver: SliverToBoxAdapter(
                            child: ListenableBuilder(
                              listenable: _controller,
                              builder: (ctx, _) =>
                                  _buildLiveArea(palette, cfg, fontSize),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                _buildBackToLatestButton(palette),
              ],
            ),
          ),

          // 3. 永远贴底稳如泰山的交互舱（建议分支折叠 + 断流续写条 + 自由输入）
          ListenableBuilder(
            listenable: _controller,
            builder: (ctx, _) => ReaderComposer(
              busy: _controller.isBusy,
              interrupted: _controller.isInterrupted,
              hasLiveBody: _controller.hasLiveBody,
              isEmptyHistory: _history.isEmpty,
              notice: _controller.notice,
              choices: _choices,
              choicesExpanded: _choicesExpanded,
              onToggleChoices: () =>
                  setState(() => _choicesExpanded = !_choicesExpanded),
              onPickChoice: (c) => _act(c),
              onStartOpening: () => _act(''),
              controller: _inputController,
              focusNode: _inputFocusNode,
              godMode: _godMode,
              onToggleGodMode: (v) => setState(() => _godMode = v),
              onSend: (text) => _act(text, godMode: _godMode),
              onCancel: _controller.cancel,
              onContinue: _continueInterrupted,
              onCommitInterrupted: _controller.commitInterruptedAsChapter,
              onRetry: _retryInterrupted,
              onDiscardInterrupted: _controller.discardInterrupted,
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildTopBar(
    ReadingPalette palette,
    SurfaceLadder ladder,
    AppConfig cfg,
  ) {
    final subtitleParts = <String>[
      if (_session.lines.length > 1) _session.line.name,
      '第 ${_history.length} 幕',
      Providers.resolveModelName(cfg),
    ];

    return Container(
      decoration: BoxDecoration(
        color: ladder.page.withValues(alpha: 0.96),
        border: Border(bottom: BorderSide(color: ladder.hairline, width: 0.8)),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 8, 6),
          child: Row(
            children: <Widget>[
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: () => Navigator.of(context).maybePop(),
                child: Icon(LucideIcons.arrowLeft, size: 19, color: palette.ink),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _showQuickModelSwitch,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
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
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                            fontFamilyFallback: AppTheme.serifFontFallback,
                          ),
                        ),
                        const SizedBox(height: 1),
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                subtitleParts.join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              LucideIcons.chevronDown,
                              size: 12,
                              color: palette.muted,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: _openTypographySheet,
                child: Icon(LucideIcons.type, size: 18, color: palette.ink),
              ),
              FButton.icon(
                variant: FButtonVariant.ghost,
                size: FButtonSizeVariant.sm,
                onPress: _openDrawer,
                child: Icon(
                  LucideIcons.panelRightOpen,
                  size: 18,
                  color: palette.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiveArea(
    ReadingPalette palette,
    AppConfig cfg,
    double fontSize,
  ) {
    final busy = _controller.isBusy;
    final hasLive = _controller.hasLiveOutput;
    final thought = _controller.liveThought;
    final preview = _controller.liveBodyPreview;

    if (!busy && !hasLive) {
      if (_controller.extractingInBackground) {
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 11,
                height: 11,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  valueColor: AlwaysStoppedAnimation<Color>(palette.muted),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '后台档案官正在同步世界状态…',
                style: TextStyle(fontSize: 11.5, color: palette.muted),
              ),
            ],
          ),
        );
      }
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (_controller.pendingAction.isNotEmpty)
          ReaderActionCard(
            action: _controller.pendingAction,
            godMode: _controller.godMode,
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: <Widget>[
              if (busy)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    valueColor: AlwaysStoppedAnimation<Color>(palette.accent),
                  ),
                )
              else
                Icon(
                  LucideIcons.circlePause,
                  size: 14,
                  color: palette.accent,
                ),
              const SizedBox(width: 8),
              Text(
                busy
                    ? (_controller.isThinkingPhase ? '正在推演思考…' : '正在落笔书写…')
                    : '已暂停（正文完整保留，可继续生成）',
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
          ThinkingCapsule(
            key: const ValueKey('live_thought_view'),
            thought: thought,
            isLiveThinking: _controller.isThinkingPhase,
            durationMs: _controller.liveThinkingDurationMs,
            initialExpanded: _controller.thoughtExpanded,
            onExpansionChanged: (v) => _controller.thoughtExpanded = v,
          ),
        if (preview.isNotEmpty)
          ReaderParagraphList(
            content: preview,
            config: cfg,
            fontSize: fontSize,
            color: palette.ink,
          ),
      ],
    );
  }

  Widget _buildBackToLatestButton(ReadingPalette palette) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (ctx, _) {
        final show = !_atBottom &&
            (_hasNewStreamingContent ||
                (_controller.isBusy && _controller.hasLiveOutput));
        return Positioned(
          right: 16,
          bottom: 14,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            offset: show ? Offset.zero : const Offset(0, 1.5),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: show ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !show,
                child: Material(
                  color: Colors.transparent,
                  elevation: 4,
                  borderRadius: BorderRadius.circular(20),
                  shadowColor: Colors.black.withValues(alpha: 0.22),
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
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            LucideIcons.arrowDown,
                            size: 14,
                            color: Theme.of(context).colorScheme.onPrimary,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            '有新内容流出',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onPrimary,
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
