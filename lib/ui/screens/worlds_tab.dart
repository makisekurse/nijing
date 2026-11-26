import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/world_book.dart';
import '../themes/app_theme.dart';
import '../widgets/world_book_cover.dart';

/// 「世界」书房标签页（`forui` 卡片 + 出版物书封 + 文件/示例导入）。
class WorldsTab extends StatelessWidget {
  final List<WorldBook> books;
  final Map<String, int> progressByBook;
  final VoidCallback onCreate;
  final VoidCallback onImport;
  final VoidCallback? onImportSample;
  final ValueChanged<WorldBook> onEdit;
  final ValueChanged<WorldBook> onMenu;
  final ValueChanged<WorldBook> onStartSession;

  const WorldsTab({
    super.key,
    required this.books,
    required this.progressByBook,
    required this.onCreate,
    required this.onImport,
    this.onImportSample,
    required this.onEdit,
    required this.onMenu,
    required this.onStartSession,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);

    return CustomScrollView(
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '世界书房',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: palette.ink,
                    fontFamilyFallback: AppTheme.serifFontFallback,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '一本世界书即一座舞台。你演谁、身处何世、用何笔法，尽在于此。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.55,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FButton(
                        variant: FButtonVariant.outline,
                        prefix: const Icon(LucideIcons.folderInput, size: 16),
                        onPress: () {
                          HapticFeedback.lightImpact();
                          onImport();
                        },
                        child: const Text('导入'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FButton(
                        prefix: const Icon(LucideIcons.plus, size: 16),
                        onPress: () {
                          HapticFeedback.lightImpact();
                          onCreate();
                        },
                        child: const Text('创建世界'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (books.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 96),
              child: Center(
                child: FCard(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: palette.accent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            LucideIcons.library,
                            size: 22,
                            color: palette.accent,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          '书架尚空',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: palette.ink,
                            fontFamilyFallback: AppTheme.serifFontFallback,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '你可以一句话让 AI 扩写新世界、从手机导入 .json/.txt 文件，或直接体验内置示例。',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.65,
                            color: palette.muted,
                          ),
                        ),
                        if (onImportSample != null) ...<Widget>[
                          const SizedBox(height: 18),
                          FButton(
                            variant: FButtonVariant.secondary,
                            prefix: const Icon(
                              LucideIcons.bookmarkPlus,
                              size: 16,
                            ),
                            onPress: onImportSample,
                            child: const Text('一键导入示例《决胜西南1949》'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 100),
            sliver: SliverList.builder(
              itemCount: books.length,
              itemBuilder: (_, i) {
                final b = books[i];
                final progress = progressByBook[b.id] ?? 0;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _bookShelfCard(context, palette, b, progress),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _bookShelfCard(
    BuildContext context,
    ReadingPalette palette,
    WorldBook b,
    int progress,
  ) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onEdit(b);
      },
      onLongPress: () => onMenu(b),
      child: FCard(
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              WorldBookCover(
                book: b,
                chapterCount: progress,
                width: 72,
                height: 100,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            b.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: palette.ink,
                              fontFamilyFallback: AppTheme.serifFontFallback,
                            ),
                          ),
                        ),
                        FButton.icon(
                          variant: FButtonVariant.ghost,
                          size: FButtonSizeVariant.xs,
                          onPress: () => onMenu(b),
                          child: Icon(
                            LucideIcons.ellipsis,
                            size: 17,
                            color: palette.muted,
                          ),
                        ),
                      ],
                    ),
                    if (b.era.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 2),
                      Text(
                        b.era.trim(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: palette.accent),
                      ),
                    ],
                    if (b.playerRole.trim().isNotEmpty) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        '扮演：${b.playerRole.trim()}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.45,
                          color: palette.muted,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: FButton(
                            variant: b.isPlayable
                                ? (progress > 0
                                    ? FButtonVariant.primary
                                    : FButtonVariant.secondary)
                                : FButtonVariant.outline,
                            size: FButtonSizeVariant.sm,
                            prefix: Icon(
                              !b.isPlayable
                                  ? LucideIcons.circleAlert
                                  : (progress > 0
                                      ? LucideIcons.play
                                      : LucideIcons.bookOpen),
                              size: 15,
                            ),
                            onPress: b.isPlayable
                                ? () {
                                    HapticFeedback.lightImpact();
                                    onStartSession(b);
                                  }
                                : () => onEdit(b),
                            child: Text(
                              !b.isPlayable
                                  ? '补全必填项'
                                  : progress > 0
                                      ? '继续 · 第 $progress 幕'
                                      : '进入世界',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
