import 'package:flutter/material.dart';

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
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: isActive ? null : () => onSelect(l),
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
                    isRoot
                        ? (isActive ? Icons.hub_rounded : Icons.hub_outlined)
                        : Icons.subdirectory_arrow_right_rounded,
                    size: 20,
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

                  // 更多操作
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: palette.muted,
                    ),
                    onSelected: (v) {
                      switch (v) {
                        case 'switch':
                          onSelect(l);
                          break;
                        case 'rename':
                          onRename(l);
                          break;
                        case 'delete':
                          onDelete(l);
                          break;
                      }
                    },
                    itemBuilder: (_) => <PopupMenuEntry<String>>[
                      if (!isActive)
                        const PopupMenuItem<String>(
                          value: 'switch',
                          child: Text('切换到此世界线'),
                        ),
                      const PopupMenuItem<String>(
                        value: 'rename',
                        child: Text('重命名'),
                      ),
                      if (lines.length > 1)
                        const PopupMenuItem<String>(
                          value: 'delete',
                          child: Text('删除此世界线'),
                        ),
                    ],
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
}
