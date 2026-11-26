import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/chapter_node.dart';
import '../../models/world_book.dart';
import '../../models/world_line.dart';
import '../../models/world_state.dart';
import '../../services/file_export_service.dart';
import '../../services/runtime_log.dart';
import '../../services/story_export_service.dart';
import '../themes/app_theme.dart';
import 'app_toast.dart';

/// 阅读页的故事导出、日志导出与世界线分岔选择弹层（统一 `forui` 视觉与 `LucideIcons`）。
class ReaderExportAndLineSheets {
  ReaderExportAndLineSheets._();

  static Future<void> copyChapter(
    BuildContext context,
    ChapterNode chapter,
  ) async {
    final sb = StringBuffer();
    sb.writeln(
      chapter.date.trim().isEmpty
          ? chapter.title
          : '${chapter.title} · ${chapter.date.trim()}',
    );
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
    AppToast.show(context, '本幕已复制到剪贴板');
  }

  static void showExportSheet(
    BuildContext context, {
    required WorldBook book,
    required WorldLine line,
    required List<ChapterNode> history,
    required String chronicle,
    required WorldState worldState,
  }) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    showFSheet<void>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.85,
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: palette.page,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: ladder.hairlineStrong, width: 0.8)),
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
                    '导出推演故事',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '将当前世界线的长篇小说按章节规范排版导出。支持保存为物理文件至系统下载目录，以及系统原生分享与复制。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: palette.muted,
                    ),
                  ),
                  const SizedBox(height: 14),
                  FTileGroup(
                    children: <FTileMixin>[
                      FTile(
                        prefix: const Icon(LucideIcons.fileText, size: 17),
                        title: const Text('导出为 Markdown 文件（.md）'),
                        subtitle: const Text('保存至系统下载目录，带标题层级、抉择与大事记'),
                        onPress: () async {
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
                      FTile(
                        prefix: const Icon(LucideIcons.fileDown, size: 17),
                        title: const Text('导出为纯文本文件（.txt）'),
                        subtitle: const Text('保存至系统下载目录，带全角缩进与分段的小说纯文本'),
                        onPress: () async {
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
                    ],
                  ),
                  const SizedBox(height: 10),
                  FTileGroup(
                    children: <FTileMixin>[
                      FTile(
                        prefix: const Icon(LucideIcons.copy, size: 17),
                        title: const Text('复制为 Markdown 格式'),
                        subtitle: const Text('仅复制结构化 Markdown 文本到剪贴板'),
                        onPress: () async {
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
                            AppToast.show(
                              context,
                              'Markdown 故事已复制到剪贴板（${md.length} 字）',
                            );
                          }
                        },
                      ),
                      FTile(
                        prefix: const Icon(LucideIcons.clipboardCopy, size: 17),
                        title: const Text('复制为纯文本小说'),
                        subtitle: const Text('仅复制纯文本小说内容到剪贴板'),
                        onPress: () async {
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
                            AppToast.show(
                              context,
                              '纯文本小说已复制到剪贴板（${txt.length} 字）',
                            );
                          }
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

    AppToast.show(
      context,
      res.success
          ? '已导出保存至：${res.path}（已同时复制到剪贴板）'
          : '保存失败：${res.message}（已复制到剪贴板）',
      duration: const Duration(seconds: 6),
      actionLabel: '系统分享',
      onAction: () => _shareOrFallback(
        path: res.success ? res.path : null,
        title: '${book.name} · 推演故事',
        text: content,
        mimeType: mimeType,
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
    AppToast.show(
      context,
      res.success
          ? '运行日志（${RuntimeLog.count} 条）已保存至：${res.path}'
          : '导出失败：${res.message}',
      duration: const Duration(seconds: 6),
      actionLabel: '系统分享',
      onAction: () => _shareOrFallback(
        path: res.success ? res.path : null,
        title: '拟境 · 运行日志',
        text: text,
        mimeType: 'text/plain',
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

  static void showBranchPicker(
    BuildContext context, {
    required List<ChapterNode> history,
    required ValueChanged<int> onPickIndex,
  }) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    showFSheet<void>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.82,
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: palette.page,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: ladder.hairlineStrong, width: 0.8)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
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
                  Row(
                    children: <Widget>[
                      Icon(LucideIcons.gitBranch, size: 17, color: palette.accent),
                      const SizedBox(width: 8),
                      Text(
                        '从哪一幕分岔？',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '保留到该幕为止的剧情，之后重新做选择。当前世界线会原样保留，不会丢。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.55,
                      color: palette.muted,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      physics: const ClampingScrollPhysics(),
                      itemCount: history.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, i) {
                        final node = history[i];
                        return FTappable(
                          onPress: () {
                            Navigator.pop(ctx);
                            onPickIndex(i);
                          },
                          child: FCard(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 10,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '第 ${node.chapterIndex} 幕'
                                    '${node.date.isEmpty ? '' : ' · ${node.date}'}',
                                    style: TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: palette.ink,
                                    ),
                                  ),
                                  if ((node.playerAction ?? '').trim().isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 3),
                                    Text(
                                      node.playerAction!.trim(),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: palette.muted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
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
