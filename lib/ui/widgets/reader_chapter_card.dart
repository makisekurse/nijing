import 'package:flutter/material.dart';

import '../../core/app_info.dart';
import '../../models/app_config.dart';
import '../../models/chapter_node.dart';
import '../../models/world_book.dart';
import '../themes/app_theme.dart';
import 'glossary_sheet.dart';
import 'reader_paragraph.dart';
import 'thought_sheet.dart';

/// 阅读页顶部的世界书扉页。
class ReaderFrontispiece extends StatelessWidget {
  final WorldBook book;

  const ReaderFrontispiece({super.key, required this.book});

  @override
  Widget build(BuildContext context) {
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
}

/// 玩家行动引用卡片。
class ReaderActionCard extends StatelessWidget {
  final String action;

  const ReaderActionCard({super.key, required this.action});

  @override
  Widget build(BuildContext context) {
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
              action,
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
}

/// 单幕历史章节视图（供 `SliverList.builder` 懒加载复用，不受流式刷新影响）。
class ReaderChapterCard extends StatelessWidget {
  final ChapterNode chapter;
  final AppConfig config;
  final double fontSize;
  final VoidCallback onOpenMenu;
  final VoidCallback onInteractiveTouch;

  const ReaderChapterCard({
    super.key,
    required this.chapter,
    required this.config,
    required this.fontSize,
    required this.onOpenMenu,
    required this.onInteractiveTouch,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppTheme.readingOf(context);
    final act = chapter.playerAction;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (act != null && act.trim().isNotEmpty)
          ReaderActionCard(action: act),
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
                onOpenMenu,
              ),
            ],
          ),
        ),
        ReaderParagraphList(
          content: chapter.content,
          config: config,
          fontSize: fontSize,
          color: palette.ink,
        ),
        Divider(height: 26, color: palette.rule),
      ],
    );
  }

  Widget _miniAction(ThemeData theme, IconData icon, VoidCallback onTap) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => onInteractiveTouch(),
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
}
