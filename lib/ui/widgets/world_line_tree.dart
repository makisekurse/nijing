import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/world_line.dart';
import '../themes/app_theme.dart';

/// 世界线时空分岔树节点视图数据。
class _TreeNode {
  final WorldLine line;
  final List<_TreeNode> children = <_TreeNode>[];

  _TreeNode(this.line);
}

/// 世界线时空分岔树可视化组件。
///
/// 直观展示各世界线从第几幕分岔、走向、幕数进度与当前所在位置，支持一键直观切换。
class WorldLineTreeView extends StatelessWidget {
  final List<WorldLine> lines;
  final String activeLineId;
  final ValueChanged<WorldLine> onSelect;
  final ValueChanged<WorldLine> onRename;
  final ValueChanged<WorldLine> onDelete;

  const WorldLineTreeView({
    super.key,
    required this.lines,
    required this.activeLineId,
    required this.onSelect,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppTheme.readingOf(context);

    // 构建树形结构
    final nodesById = <String, _TreeNode>{};
    for (final l in lines) {
      nodesById[l.id] = _TreeNode(l);
    }

    final roots = <_TreeNode>[];
    for (final l in lines) {
      final node = nodesById[l.id]!;
      final parentId = l.parentLineId;
      if (parentId != null && nodesById.containsKey(parentId) && parentId != l.id) {
        nodesById[parentId]!.children.add(node);
      } else {
        roots.add(node);
      }
    }

    // 兜底保障：若存在孤立循环引用导致某些节点未挂载到 roots，强制将其作为根节点渲染，防丢失
    final visited = <String>{};
    void markVisited(_TreeNode n) {
      if (visited.add(n.line.id)) {
        for (final c in n.children) {
          markVisited(c);
        }
      }
    }
    for (final r in roots) {
      markVisited(r);
    }
    for (final l in lines) {
      if (!visited.contains(l.id)) {
        final fallbackRoot = nodesById[l.id]!;
        roots.add(fallbackRoot);
        markVisited(fallbackRoot);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < roots.length; i++)
          _buildNode(context, theme, palette, roots[i], depth: 0, isLastChild: i == roots.length - 1),
      ],
    );
  }

  Widget _buildNode(
    BuildContext context,
    ThemeData theme,
    ReadingPalette palette,
    _TreeNode node, {
    required int depth,
    required bool isLastChild,
  }) {
    final l = node.line;
    final isActive = l.id == activeLineId;
    final isRoot = depth == 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FTappable(
            onPress: isActive ? null : () => onSelect(l),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isActive
                    ? palette.accent.withValues(alpha: 0.12)
                    : theme.cardColor.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isActive ? palette.accent : palette.rule,
                  width: isActive ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: <Widget>[
                  // 树形节点图标：子分支使用清晰的转角分支箭头
                  Icon(
                    isRoot ? LucideIcons.gitBranch : LucideIcons.cornerDownRight,
                    size: 18,
                    color: isActive
                        ? palette.accent
                        : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 10),

                  // 信息体
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Flexible(
                              child: Text(
                                l.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                                  color: palette.ink,
                                ),
                              ),
                            ),
                            if (isActive) ...<Widget>[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: palette.accent,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '当前所在',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: <Widget>[
                            if (l.isBranch)
                              Container(
                                margin: const EdgeInsets.only(right: 6),
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: palette.accent.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  '从第 ${l.branchedAtChapter} 幕分岔',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: palette.accent,
                                  ),
                                ),
                              ),
                            Expanded(
                              child: Text(
                                '共 ${l.chapterCount} 幕${l.latestDate.isNotEmpty ? " · ${l.latestDate}" : ""}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: palette.muted,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // 更多操作（forui 原生触控按钮 + 底部弹层，彻底脱离 Material PopupMenuButton）
                  FButton.icon(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.xs,
                    onPress: () => _showLineActions(context, palette, l, isActive),
                    child: Icon(
                      LucideIcons.ellipsisVertical,
                      size: 16,
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 递归渲染子分支
          for (var j = 0; j < node.children.length; j++)
            _buildNode(
              context,
              theme,
              palette,
              node.children[j],
              depth: depth + 1,
              isLastChild: j == node.children.length - 1,
            ),
        ],
      ),
    );
  }

  void _showLineActions(
    BuildContext context,
    ReadingPalette palette,
    WorldLine line,
    bool isActive,
  ) {
    showFSheet<void>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.55,
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: palette.page,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: palette.rule, width: 0.8)),
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
                    line.name,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FTileGroup(
                    children: <FTileMixin>[
                      if (!isActive)
                        FTile(
                          prefix: const Icon(LucideIcons.arrowRightLeft, size: 16),
                          title: const Text('切换到此世界线'),
                          onPress: () {
                            Navigator.pop(ctx);
                            onSelect(line);
                          },
                        ),
                      FTile(
                        prefix: const Icon(LucideIcons.pencil, size: 16),
                        title: const Text('重命名'),
                        onPress: () {
                          Navigator.pop(ctx);
                          onRename(line);
                        },
                      ),
                      if (lines.length > 1)
                        FTile(
                          variant: FItemVariant.destructive,
                          prefix: const Icon(LucideIcons.trash2, size: 16),
                          title: const Text('删除此世界线'),
                          onPress: () {
                            Navigator.pop(ctx);
                            onDelete(line);
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
