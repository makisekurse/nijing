import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/chapter_node.dart';
import '../../models/world_state.dart';
import '../../services/runtime_log.dart';
import 'glossary_sheet.dart';
import 'thought_sheet.dart';

/// 阅读页底部弹层、对话框与文件导出合集（从巨型 ReaderScreen 抽离）。
class ReaderSheets {
  ReaderSheets._();

  static void showWorldState(BuildContext context, WorldState s) {
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
                            '还没有世界状态。\n推演一幕之后，这里会记录此刻的时间、地点、人物关系与未决之事。',
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

  static Widget _stateSection(ThemeData theme, String title, String body) =>
      Padding(
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

  static void showChapterMenu(
    BuildContext context, {
    required ChapterNode chapter,
    required VoidCallback onCopy,
    required VoidCallback onEdit,
    required VoidCallback onExportLog,
  }) {
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
                    onCopy();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.edit_note_rounded),
                  title: const Text('修改错字 / 编辑本幕'),
                  subtitle: const Text('就地修正本幕正文中的错别字并保存'),
                  onTap: () {
                    Navigator.pop(ctx);
                    onEdit();
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
                    showRawOutput(context, chapter);
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
                    onExportLog();
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

  static void showRawOutput(BuildContext context, ChapterNode chapter) {
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
                            fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: chapter.rawOutput),
                        );
                        if (ctx.mounted) Navigator.pop(ctx);
                        if (context.mounted) {
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

  static Future<String?> showEditChapterDialog(
    BuildContext context,
    ChapterNode chapter,
  ) async {
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
    return saved;
  }
}
