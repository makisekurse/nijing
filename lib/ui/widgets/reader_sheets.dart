import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/chapter_node.dart';
import '../../services/runtime_log.dart';
import '../themes/app_theme.dart';
import 'app_toast.dart';
import 'glossary_sheet.dart';
import 'thought_sheet.dart';

/// 阅读页底部弹层与编辑对话框合集（统一 `forui` 触控视觉 + `LucideIcons`）。
class ReaderSheets {
  ReaderSheets._();

  static void showChapterMenu(
    BuildContext context, {
    required ChapterNode chapter,
    required VoidCallback onCopy,
    required VoidCallback onEdit,
    required VoidCallback onExportLog,
  }) {
    final palette = AppTheme.readingOf(context);
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
                    chapter.title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FTileGroup(
                    children: <FTileMixin>[
                      FTile(
                        prefix: const Icon(LucideIcons.copy, size: 17),
                        title: const Text('复制本幕'),
                        subtitle: const Text('标题 + 你的行动 + 正文'),
                        onPress: () {
                          Navigator.pop(ctx);
                          onCopy();
                        },
                      ),
                      FTile(
                        prefix: const Icon(LucideIcons.pencil, size: 17),
                        title: const Text('修改错字 / 编辑本幕'),
                        subtitle: const Text('就地修正本幕正文中的错别字并保存'),
                        onPress: () {
                          Navigator.pop(ctx);
                          onEdit();
                        },
                      ),
                      if (chapter.thought.isNotEmpty)
                        FTile(
                          prefix: const Icon(LucideIcons.brainCircuit, size: 17),
                          title: const Text('推演思考'),
                          subtitle: const Text('查看模型生成本幕时的思维链过程'),
                          onPress: () {
                            Navigator.pop(ctx);
                            ThoughtSheet.show(
                              context,
                              title: chapter.title,
                              thought: chapter.thought,
                            );
                          },
                        ),
                      if (chapter.glossary.isNotEmpty)
                        FTile(
                          prefix: const Icon(LucideIcons.bookMarked, size: 17),
                          title: const Text('本幕词条'),
                          onPress: () {
                            Navigator.pop(ctx);
                            AnnotationSheet.showGlossary(
                              context,
                              chapter.glossary,
                            );
                          },
                        ),
                      if (chapter.cast.isNotEmpty)
                        FTile(
                          prefix: const Icon(LucideIcons.users, size: 17),
                          title: const Text('本幕人物'),
                          onPress: () {
                            Navigator.pop(ctx);
                            AnnotationSheet.showCast(context, chapter.cast);
                          },
                        ),
                      FTile(
                        prefix: const Icon(LucideIcons.fileCode, size: 17),
                        title: const Text('查看原始输出'),
                        subtitle: Text(
                          chapter.rawOutput.isEmpty
                              ? '本幕没有留存原始输出'
                              : '模型返回的原文，用于排查格式问题',
                        ),
                        enabled: chapter.rawOutput.isNotEmpty,
                        onPress: () {
                          Navigator.pop(ctx);
                          showRawOutput(context, chapter);
                        },
                      ),
                      FTile(
                        prefix: const Icon(LucideIcons.terminal, size: 17),
                        title: const Text('导出运行日志'),
                        subtitle: Text(
                          RuntimeLog.enabled
                              ? '本次会话已记录 ${RuntimeLog.count} 条，用于排查生成异常'
                              : '日志未开启 —— 请先在「我的 → 调试与日志」里打开',
                        ),
                        enabled: RuntimeLog.enabled && RuntimeLog.count > 0,
                        onPress: () {
                          Navigator.pop(ctx);
                          onExportLog();
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

  static void showRawOutput(BuildContext context, ChapterNode chapter) {
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
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: palette.muted.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      Icon(LucideIcons.fileCode, size: 17, color: palette.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '模型原始输出',
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                          ),
                        ),
                      ),
                      FButton(
                        variant: FButtonVariant.outline,
                        size: FButtonSizeVariant.xs,
                        mainAxisSize: MainAxisSize.min,
                        prefix: const Icon(LucideIcons.copy, size: 14),
                        onPress: () async {
                          await Clipboard.setData(
                            ClipboardData(text: chapter.rawOutput),
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            AppToast.show(context, '原始输出已复制');
                          }
                        },
                        child: const Text('复制'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: ladder.containerLow,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: ladder.hairlineStrong, width: 0.8),
                      ),
                      child: SingleChildScrollView(
                        physics: const ClampingScrollPhysics(),
                        child: SelectableText(
                          chapter.rawOutput,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.6,
                            fontFamily: 'monospace',
                            color: palette.ink.withValues(alpha: 0.88),
                          ),
                        ),
                      ),
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

  static Future<String?> showEditChapterDialog(
    BuildContext context,
    ChapterNode chapter,
  ) async {
    final ctrl = TextEditingController(text: chapter.content);
    final saved = await showFDialog<String>(
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
              Text('修改正文 · ${chapter.title}', style: s.titleTextStyle),
              const SizedBox(height: 12),
              FTextField.multiline(
                control: FTextFieldControl.managed(controller: ctrl),
                autofocus: true,
                minLines: 6,
                maxLines: 14,
                hint: '输入修正后的正文内容…',
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
                      child: const Text('保存修改'),
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
    return saved;
  }
}
