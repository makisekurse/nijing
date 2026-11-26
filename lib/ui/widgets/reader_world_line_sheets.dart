import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/chapter_node.dart';
import '../../models/world_book.dart';
import '../../models/world_line.dart';
import '../../models/world_state.dart';
import '../../services/file_export_service.dart';
import '../../services/runtime_log.dart';
import '../../services/story_export_service.dart';
import '../themes/app_theme.dart';
import 'world_line_tree.dart';

/// 阅读页的故事导出、日志导出与世界线分岔管理弹层。
class ReaderExportAndLineSheets {
  ReaderExportAndLineSheets._();

  static Future<void> copyChapter(
    BuildContext context,
    ChapterNode chapter,
  ) async {
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
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本幕已复制到剪贴板')),
    );
  }

  static void showExportSheet(
    BuildContext context, {
    required WorldBook book,
    required WorldLine line,
    required List<ChapterNode> history,
    required String chronicle,
    required WorldState worldState,
  }) {
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
                      await exportStoryFile(
                        context,
                        book: book,
                        line: line,
                        history: history,
                        chronicle: chronicle,
                        worldState: worldState,
                        isMarkdown: true,
                      );
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.description_outlined),
                    title: const Text('导出为纯文本文件（.txt）'),
                    subtitle: const Text('保存至系统下载目录，带全角缩进与分段的小说纯文本'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      await exportStoryFile(
                        context,
                        book: book,
                        line: line,
                        history: history,
                        chronicle: chronicle,
                        worldState: worldState,
                        isMarkdown: false,
                      );
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
                        book: book,
                        line: line,
                        history: history,
                        chronicle: chronicle,
                        worldState: worldState,
                      );
                      await Clipboard.setData(ClipboardData(text: md));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content:
                                  Text('Markdown 故事已复制到剪贴板（${md.length} 字）')),
                        );
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.content_copy_rounded),
                    title: const Text('复制为纯文本小说'),
                    subtitle: const Text('仅复制纯文本小说内容到剪贴板'),
                    onTap: () async {
                      Navigator.pop(ctx);
                      final txt = StoryExportService.toPlainText(
                        book: book,
                        line: line,
                        history: history,
                        chronicle: chronicle,
                        worldState: worldState,
                      );
                      await Clipboard.setData(ClipboardData(text: txt));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('纯文本小说已复制到剪贴板（${txt.length} 字）')),
                        );
                      }
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

  static Future<void> exportStoryFile(
    BuildContext context, {
    required WorldBook book,
    required WorldLine line,
    required List<ChapterNode> history,
    required String chronicle,
    required WorldState worldState,
    required bool isMarkdown,
  }) async {
    final bookName = book.name.trim().isEmpty ? '推演故事' : book.name.trim();
    final lineName = line.name.trim().isEmpty ? '主线' : line.name.trim();
    final ts = FileExportService.formatTimestamp();
    final ext = isMarkdown ? 'md' : 'txt';
    final mimeType = isMarkdown ? 'text/markdown' : 'text/plain';
    final fileName =
        '拟境_${FileExportService.sanitizeFileName(bookName)}_${FileExportService.sanitizeFileName(lineName)}_第${history.length}幕_$ts.$ext';

    final content = isMarkdown
        ? StoryExportService.toMarkdown(
            book: book,
            line: line,
            history: history,
            chronicle: chronicle,
            worldState: worldState,
          )
        : StoryExportService.toPlainText(
            book: book,
            line: line,
            history: history,
            chronicle: chronicle,
            worldState: worldState,
          );

    final res = await FileExportService.exportFile(
      fileName: fileName,
      content: content,
      mimeType: mimeType,
    );
    await Clipboard.setData(ClipboardData(text: content));
    if (!context.mounted) return;

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
          onPressed: () => _shareOrFallback(
            path: res.success ? res.path : null,
            title: '${book.name} · 推演故事',
            text: content,
            mimeType: mimeType,
          ),
        ),
      ),
    );
  }

  static Future<void> exportRuntimeLog(BuildContext context) async {
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
    if (!context.mounted) return;
    if (res.success && res.path != null) {
      await _shareOrFallback(
        path: res.path,
        title: '拟境 · 运行日志',
        text: text,
        mimeType: 'text/plain',
      );
    }
    if (!context.mounted) return;
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
          onPressed: () => _shareOrFallback(
            path: res.success ? res.path : null,
            title: '拟境 · 运行日志',
            text: text,
            mimeType: 'text/plain',
          ),
        ),
      ),
    );
  }

  static Future<void> _shareOrFallback({
    required String? path,
    required String title,
    required String text,
    required String mimeType,
  }) async {
    if (path != null) {
      final ok = await FileExportService.shareFile(
        filePath: path,
        title: title,
        mimeType: mimeType,
      );
      if (ok) return;
    }
    await FileExportService.shareText(title: title, text: text);
  }

  static void showWorldLines(
    BuildContext context, {
    required List<WorldLine> lines,
    required String activeLineId,
    required bool canBranch,
    required ValueChanged<WorldLine> onSelect,
    required ValueChanged<WorldLine> onRename,
    required ValueChanged<WorldLine> onDelete,
    required VoidCallback onPickBranch,
  }) {
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
                    lines: lines,
                    activeLineId: activeLineId,
                    onSelect: (l) {
                      Navigator.pop(ctx);
                      onSelect(l);
                    },
                    onRename: (l) {
                      Navigator.pop(ctx);
                      onRename(l);
                    },
                    onDelete: (l) {
                      Navigator.pop(ctx);
                      onDelete(l);
                    },
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.call_split_rounded),
                  title: const Text('从某一幕分岔出新世界线'),
                  subtitle: const Text('保留到那一幕，之后重新做选择'),
                  enabled: canBranch,
                  onTap: () {
                    Navigator.pop(ctx);
                    onPickBranch();
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

  static void showBranchPicker(
    BuildContext context, {
    required List<ChapterNode> history,
    required ValueChanged<int> onPickIndex,
  }) {
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
                  '保留到该幕为止的剧情，之后重新做选择。当前世界线会原样保留，不会丢。',
                  style: TextStyle(fontSize: 11.5, height: 1.6, color: muted),
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  physics: const ClampingScrollPhysics(),
                  itemCount: history.length,
                  itemBuilder: (_, i) {
                    final node = history[i];
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
                        onPickIndex(i);
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
}
