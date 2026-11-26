import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_info.dart';
import '../../models/app_config.dart';
import '../../models/chapter_node.dart';
import '../../models/world_book.dart';
import '../themes/app_theme.dart';
import 'glossary_sheet.dart';
import 'reader_paragraph.dart';
import 'thinking_capsule.dart';

/// 阅读页顶部的出版物扉页（Claude 书卷衬线美学）。
class ReaderFrontispiece extends StatelessWidget {
  final WorldBook book;

  const ReaderFrontispiece({super.key, required this.book});

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 26),
      padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.rule, width: 0.8)),
      ),
      child: Column(
        children: <Widget>[
          Text(
            AppInfo.appName,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 3.2,
              fontWeight: FontWeight.w600,
              color: palette.accent,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            book.name,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w700,
              height: 1.35,
              color: palette.ink,
              fontFamilyFallback: AppTheme.serifFontFallback,
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
          Container(
            width: 32,
            height: 1.5,
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '你扮演：${book.playerRole.trim()}',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.55,
              color: palette.muted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 玩家行动引用卡片（HCT 次级色阶 + 精致竖线）。
class ReaderActionCard extends StatelessWidget {
  final String action;
  final bool godMode;

  const ReaderActionCard({
    super.key,
    required this.action,
    this.godMode = false,
  });

  static const Color _kGodGold = Color(0xFFD4AF37);

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);
    final stripe = godMode ? _kGodGold : palette.accent;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16, top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: ladder.containerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: godMode
              ? _kGodGold.withValues(alpha: 0.4)
              : ladder.hairlineStrong,
          width: 0.8,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 3,
            height: 18,
            margin: const EdgeInsets.only(top: 2, right: 10),
            decoration: BoxDecoration(
              color: stripe,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  godMode ? '主宰敕令' : '你的行动',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: stripe,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  action,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.55,
                    color: palette.ink,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 单幕历史章节（无厚边框书页流 + 内联思考胶囊 + 幕底极简微操作条）。
class ReaderChapterCard extends StatelessWidget {
  final ChapterNode chapter;
  final AppConfig config;
  final double fontSize;
  final bool isLastChapter;
  final bool busy;
  final VoidCallback onCopy;
  final VoidCallback onEdit;
  final VoidCallback onBranchHere;
  final VoidCallback? onReroll;
  final VoidCallback onOpenMenu;
  final VoidCallback? onOpenState;

  const ReaderChapterCard({
    super.key,
    required this.chapter,
    required this.config,
    required this.fontSize,
    required this.isLastChapter,
    required this.busy,
    required this.onCopy,
    required this.onEdit,
    required this.onBranchHere,
    this.onReroll,
    required this.onOpenMenu,
    this.onOpenState,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);
    final act = chapter.playerAction;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (act != null && act.trim().isNotEmpty)
          ReaderActionCard(action: act, godMode: chapter.godMode),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: <Widget>[
              Text(
                chapter.title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                  color: palette.accent,
                  fontFamilyFallback: AppTheme.serifFontFallback,
                ),
              ),
              if (chapter.date.trim().isNotEmpty) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 7),
                  child: Text(
                    '·',
                    style: TextStyle(color: palette.muted),
                  ),
                ),
                Expanded(
                  child: Text(
                    chapter.date.trim(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: palette.muted),
                  ),
                ),
              ] else
                const Spacer(),
              if (chapter.stateDiffSummary.isNotEmpty)
                SelectionContainer.disabled(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: onOpenState,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: palette.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        chapter.stateDiffSummary,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: palette.accent,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (chapter.thought.trim().isNotEmpty)
          ThinkingCapsule(
            thought: chapter.thought,
            isLiveThinking: false,
            durationMs: chapter.thinkingDurationMs,
          ),
        ReaderParagraphList(
          content: chapter.content,
          config: config,
          fontSize: fontSize,
          color: palette.ink,
        ),
        // 幕底极简微操作栏（对标 Kelivo / DeepSeek 消息底部操作行）
        SelectionContainer.disabled(
          child: Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 14),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _actionBtn(palette, LucideIcons.copy, '复制', onCopy),
                _actionBtn(palette, LucideIcons.pencil, '编辑', onEdit),
                if (!busy)
                  _actionBtn(
                    palette,
                    LucideIcons.gitBranch,
                    '分岔',
                    onBranchHere,
                  ),
                if (isLastChapter && !busy && onReroll != null)
                  _actionBtn(
                    palette,
                    LucideIcons.rotateCcw,
                    '重写',
                    onReroll!,
                  ),
                if (chapter.glossary.isNotEmpty)
                  _actionBtn(
                    palette,
                    LucideIcons.bookMarked,
                    '词条(${chapter.glossary.length})',
                    () => AnnotationSheet.showGlossary(
                      context,
                      chapter.glossary,
                    ),
                  ),
                if (chapter.cast.isNotEmpty)
                  _actionBtn(
                    palette,
                    LucideIcons.users,
                    '人物(${chapter.cast.length})',
                    () => AnnotationSheet.showCast(context, chapter.cast),
                  ),
                _iconOnly(palette, LucideIcons.ellipsis, onOpenMenu),
              ],
            ),
          ),
        ),
        Container(
          height: 0.8,
          margin: const EdgeInsets.only(bottom: 20),
          color: ladder.hairline,
        ),
      ],
    );
  }

  Widget _actionBtn(
    ReadingPalette palette,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 13.5, color: palette.muted),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11.5, color: palette.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconOnly(
    ReadingPalette palette,
    IconData icon,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
        child: Icon(icon, size: 14.5, color: palette.muted),
      ),
    );
  }
}
