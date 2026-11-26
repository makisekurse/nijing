import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/chapter_node.dart';
import '../../models/world_book.dart';
import '../../models/world_line.dart';
import '../../models/world_state.dart';
import '../themes/app_theme.dart';
import '../themes/surface_ladder.dart';
import 'world_line_tree.dart';

/// 右侧统一世界信息抽屉（`forui` `showFSheet(side: FLayout.rtl)`）。
///
/// 一站式聚合「世界观察 / 目录 / 世界线 / 档案与工具」，彻底消灭旧版顶栏堆 5 个小图标
/// 且“更多”菜单里又原样重复列一遍的混乱入口。
class ReaderDrawer {
  ReaderDrawer._();

  static Future<void> show(
    BuildContext context, {
    required WorldBook book,
    required WorldState worldState,
    required String chronicle,
    required List<ChapterNode> history,
    required List<WorldLine> lines,
    required String activeLineId,
    required bool busy,
    required ValueChanged<int> onJumpToChapter,
    required ValueChanged<WorldLine> onSelectLine,
    required ValueChanged<WorldLine> onRenameLine,
    required ValueChanged<WorldLine> onDeleteLine,
    required VoidCallback onPickBranch,
    required VoidCallback onOpenCast,
    required VoidCallback onOpenChronicle,
    required VoidCallback onExportStory,
    required VoidCallback onOpenTypography,
    required VoidCallback onOpenSettings,
    required VoidCallback onRerollLast,
  }) {
    return showFSheet<void>(
      context: context,
      side: FLayout.rtl,
      mainAxisMaxRatio: 0.86,
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: _ReaderDrawerContent(
          book: book,
          worldState: worldState,
          chronicle: chronicle,
          history: history,
          lines: lines,
          activeLineId: activeLineId,
          busy: busy,
          onJumpToChapter: (idx) {
            Navigator.pop(ctx);
            onJumpToChapter(idx);
          },
          onSelectLine: (l) {
            Navigator.pop(ctx);
            onSelectLine(l);
          },
          onRenameLine: (l) {
            Navigator.pop(ctx);
            onRenameLine(l);
          },
          onDeleteLine: (l) {
            Navigator.pop(ctx);
            onDeleteLine(l);
          },
          onPickBranch: () {
            Navigator.pop(ctx);
            onPickBranch();
          },
          onOpenCast: () {
            Navigator.pop(ctx);
            onOpenCast();
          },
          onOpenChronicle: () {
            Navigator.pop(ctx);
            onOpenChronicle();
          },
          onExportStory: () {
            Navigator.pop(ctx);
            onExportStory();
          },
          onOpenTypography: () {
            Navigator.pop(ctx);
            onOpenTypography();
          },
          onOpenSettings: () {
            Navigator.pop(ctx);
            onOpenSettings();
          },
          onRerollLast: () {
            Navigator.pop(ctx);
            onRerollLast();
          },
        ),
      ),
    );
  }
}

class _ReaderDrawerContent extends StatefulWidget {
  final WorldBook book;
  final WorldState worldState;
  final String chronicle;
  final List<ChapterNode> history;
  final List<WorldLine> lines;
  final String activeLineId;
  final bool busy;
  final ValueChanged<int> onJumpToChapter;
  final ValueChanged<WorldLine> onSelectLine;
  final ValueChanged<WorldLine> onRenameLine;
  final ValueChanged<WorldLine> onDeleteLine;
  final VoidCallback onPickBranch;
  final VoidCallback onOpenCast;
  final VoidCallback onOpenChronicle;
  final VoidCallback onExportStory;
  final VoidCallback onOpenTypography;
  final VoidCallback onOpenSettings;
  final VoidCallback onRerollLast;

  const _ReaderDrawerContent({
    required this.book,
    required this.worldState,
    required this.chronicle,
    required this.history,
    required this.lines,
    required this.activeLineId,
    required this.busy,
    required this.onJumpToChapter,
    required this.onSelectLine,
    required this.onRenameLine,
    required this.onDeleteLine,
    required this.onPickBranch,
    required this.onOpenCast,
    required this.onOpenChronicle,
    required this.onExportStory,
    required this.onOpenTypography,
    required this.onOpenSettings,
    required this.onRerollLast,
  });

  @override
  State<_ReaderDrawerContent> createState() => _ReaderDrawerContentState();
}

class _ReaderDrawerContentState extends State<_ReaderDrawerContent> {
  int _tab = 0; // 0: 局势 1: 目录 2: 世界线 3: 工具

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return Container(
      decoration: BoxDecoration(
        color: palette.page,
        border: Border(left: BorderSide(color: ladder.hairlineStrong, width: 0.8)),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          widget.book.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                            fontFamilyFallback: AppTheme.serifFontFallback,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '第 ${widget.history.length} 幕 · ${widget.lines.length} 条世界线',
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        ),
                      ],
                    ),
                  ),
                  FButton.icon(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.xs,
                    onPress: () => Navigator.pop(context),
                    child: Icon(LucideIcons.x, size: 17, color: palette.muted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: ladder.containerLow,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: ladder.hairline, width: 0.8),
                ),
                child: Row(
                  children: <Widget>[
                    _segTab(0, '局势', palette, ladder),
                    _segTab(1, '目录', palette, ladder),
                    _segTab(2, '世界线', palette, ladder),
                    _segTab(3, '工具', palette, ladder),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: switch (_tab) {
                0 => _buildStateTab(palette, ladder),
                1 => _buildTocTab(palette),
                2 => _buildLinesTab(palette),
                _ => _buildToolsTab(palette),
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _segTab(
    int idx,
    String label,
    ReadingPalette palette,
    SurfaceLadder ladder,
  ) {
    final active = _tab == idx;
    return Expanded(
      child: FTappable(
        onPress: () {
          HapticFeedback.selectionClick();
          setState(() => _tab = idx);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? ladder.card : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              color: active ? palette.ink : palette.muted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStateTab(ReadingPalette palette, SurfaceLadder ladder) {
    final s = widget.worldState;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: <Widget>[
        if (s.isEmpty)
          FCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '还没有世界状态记录。推演一幕后，后台档案官会自动在此整理时间、地点、人物态度与未决局势。',
                style: TextStyle(fontSize: 13, height: 1.65, color: palette.muted),
              ),
            ),
          )
        else ...<Widget>[
          FCard(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _kv(palette, LucideIcons.clock, '此刻时间',
                      s.time.isEmpty ? '—' : s.time),
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: FDivider(),
                  ),
                  _kv(palette, LucideIcons.mapPin, '当前位置',
                      s.location.isEmpty ? '—' : s.location),
                ],
              ),
            ),
          ),
          if (s.events.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _listBlock(palette, '正在发生', s.events),
          ],
          if (s.relations.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _listBlock(
              palette,
              '人物态度',
              s.relations.entries.map((e) => '${e.key} · ${e.value}').toList(),
            ),
          ],
          if (s.facts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            _listBlock(palette, '既成事实', s.facts),
          ],
        ],
        const SizedBox(height: 14),
        FTileGroup(
          children: <FTileMixin>[
            FTile(
              prefix: Icon(LucideIcons.users, size: 16, color: palette.accent),
              title: const Text('人物志'),
              suffix: const Icon(LucideIcons.chevronRight, size: 15),
              onPress: widget.onOpenCast,
            ),
            FTile(
              prefix:
                  Icon(LucideIcons.scrollText, size: 16, color: palette.accent),
              title: const Text('编年史时间线'),
              suffix: const Icon(LucideIcons.chevronRight, size: 15),
              onPress: widget.onOpenChronicle,
            ),
          ],
        ),
      ],
    );
  }

  Widget _kv(
    ReadingPalette palette,
    IconData icon,
    String label,
    String value,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, size: 15, color: palette.accent),
        const SizedBox(width: 8),
        SizedBox(
          width: 60,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: palette.muted),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: palette.ink,
            ),
          ),
        ),
      ],
    );
  }

  Widget _listBlock(
    ReadingPalette palette,
    String title,
    List<String> items,
  ) {
    return FCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: palette.accent,
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < items.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 6),
                child: Text(
                  '· ${items[i]}',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.55,
                    color: palette.ink.withValues(alpha: 0.9),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTocTab(ReadingPalette palette) {
    if (widget.history.isEmpty) {
      return Center(
        child: Text(
          '尚未开始第一幕',
          style: TextStyle(fontSize: 13, color: palette.muted),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: widget.history.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (_, i) {
        final node = widget.history[i];
        return FTappable(
          onPress: () => widget.onJumpToChapter(i),
          child: FCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        node.title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.ink,
                        ),
                      ),
                      if (node.date.trim().isNotEmpty) ...<Widget>[
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            node.date.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: palette.accent),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if ((node.playerAction ?? '').trim().isNotEmpty) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                      node.playerAction!.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildLinesTab(ReadingPalette palette) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: <Widget>[
        WorldLineTreeView(
          lines: widget.lines,
          activeLineId: widget.activeLineId,
          onSelect: widget.onSelectLine,
          onRename: widget.onRenameLine,
          onDelete: widget.onDeleteLine,
        ),
        const SizedBox(height: 12),
        FButton(
          variant: FButtonVariant.outline,
          prefix: const Icon(LucideIcons.gitBranch, size: 16),
          onPress: widget.busy || widget.history.isEmpty
              ? null
              : widget.onPickBranch,
          child: const Text('从任意一幕分岔新世界线'),
        ),
      ],
    );
  }

  Widget _buildToolsTab(ReadingPalette palette) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: <Widget>[
        FTileGroup(
          label: const Text('本局操作'),
          children: <FTileMixin>[
            FTile(
              prefix:
                  Icon(LucideIcons.rotateCcw, size: 16, color: palette.accent),
              title: const Text('重新生成最新一幕'),
              enabled: !widget.busy && widget.history.isNotEmpty,
              onPress: widget.onRerollLast,
            ),
            FTile(
              prefix:
                  Icon(LucideIcons.fileDown, size: 16, color: palette.accent),
              title: const Text('导出推演故事'),
              subtitle: const Text('Markdown / TXT 排版文件与分享'),
              onPress: widget.onExportStory,
            ),
          ],
        ),
        const SizedBox(height: 14),
        FTileGroup(
          label: const Text('偏好与模型'),
          children: <FTileMixin>[
            FTile(
              prefix: Icon(LucideIcons.type, size: 16, color: palette.accent),
              title: const Text('实时阅读排版'),
              subtitle: const Text('主题、衬线字体、字号与行距'),
              onPress: widget.onOpenTypography,
            ),
            FTile(
              prefix:
                  Icon(LucideIcons.settings, size: 16, color: palette.accent),
              title: const Text('完整设置与模型切换'),
              onPress: widget.onOpenSettings,
            ),
          ],
        ),
      ],
    );
  }
}
