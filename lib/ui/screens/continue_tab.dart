import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/save_slot.dart';
import '../themes/app_theme.dart';
import '../widgets/world_book_cover.dart';

/// 「继续」标签页（`forui` 卡片 + 出版物书封 + HCT 阶梯层次）。
class ContinueTab extends StatelessWidget {
  final List<SaveSlot> slots;
  final String? activeSlotId;
  final ValueChanged<SaveSlot> onOpen;
  final ValueChanged<SaveSlot> onMenu;
  final VoidCallback onNewSession;
  final VoidCallback? onImportSample;

  const ContinueTab({
    super.key,
    required this.slots,
    required this.activeSlotId,
    required this.onOpen,
    required this.onMenu,
    required this.onNewSession,
    this.onImportSample,
  });

  SaveSlot? get _active {
    if (slots.isEmpty) return null;
    if (activeSlotId != null) {
      for (final s in slots) {
        if (s.id == activeSlotId) return s;
      }
    }
    return slots.first;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final active = _active;

    if (slots.isEmpty) {
      return _empty(context, palette);
    }

    final others = slots.where((s) => s.id != active?.id).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '继续推演',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                      fontFamilyFallback: AppTheme.serifFontFallback,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '回到你正在经历的世界线',
                    style: TextStyle(fontSize: 13, color: palette.muted),
                  ),
                ],
              ),
            ),
            FButton.icon(
              variant: FButtonVariant.outline,
              size: FButtonSizeVariant.sm,
              onPress: () {
                HapticFeedback.lightImpact();
                onNewSession();
              },
              child: const Icon(LucideIcons.plus, size: 18),
            ),
          ],
        ),
        const SizedBox(height: 18),
        if (active != null) _activeHeroCard(context, palette, active),
        const SizedBox(height: 14),
        FButton(
          variant: FButtonVariant.outline,
          prefix: const Icon(LucideIcons.sparkles, size: 16),
          onPress: () {
            HapticFeedback.lightImpact();
            onNewSession();
          },
          child: const Text('开启一段新的推演'),
        ),
        if (others.isNotEmpty) ...<Widget>[
          const SizedBox(height: 26),
          FTileGroup(
            label: Text(
              '最近推演',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: palette.muted,
                letterSpacing: 0.6,
              ),
            ),
            children: <FTileMixin>[
              for (final s in others)
                FTile(
                  prefix: WorldBookCover(
                    book: s.worldBook,
                    chapterCount: s.chapterCount,
                    width: 42,
                    height: 56,
                    compact: true,
                  ),
                  title: Text(
                    s.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    s.summaryLine,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  suffix: Icon(
                    LucideIcons.chevronRight,
                    size: 16,
                    color: palette.muted,
                  ),
                  onPress: () {
                    HapticFeedback.selectionClick();
                    onOpen(s);
                  },
                  onLongPress: () => onMenu(s),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _activeHeroCard(
    BuildContext context,
    ReadingPalette palette,
    SaveSlot slot,
  ) {
    final ws = slot.worldState;
    return GestureDetector(
      onLongPress: () => onMenu(slot),
      child: FCard(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  WorldBookCover(
                    book: slot.worldBook,
                    chapterCount: slot.chapterCount,
                    width: 78,
                    height: 108,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: <Widget>[
                            FBadge(
                              variant: FBadgeVariant.secondary,
                              child: Text('第 ${slot.chapterCount} 幕'),
                            ),
                            if (slot.lines.length > 1)
                              FBadge(
                                variant: FBadgeVariant.outline,
                                child: Text(slot.activeLine.name),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          slot.worldBook.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                            color: palette.ink,
                            fontFamilyFallback: AppTheme.serifFontFallback,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (ws.inlineSummary.isNotEmpty)
                          Text(
                            ws.inlineSummary,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.5,
                              color: palette.muted,
                            ),
                          )
                        else if (slot.worldBook.era.trim().isNotEmpty)
                          Text(
                            slot.worldBook.era.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: palette.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                  FButton.icon(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.xs,
                    onPress: () => onMenu(slot),
                    child: Icon(
                      LucideIcons.ellipsis,
                      size: 18,
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              FButton(
                prefix: const Icon(LucideIcons.play, size: 16),
                onPress: () {
                  HapticFeedback.lightImpact();
                  onOpen(slot);
                },
                child: const Text('继续进入'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, ReadingPalette palette) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: FCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
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
                      LucideIcons.bookOpen,
                      size: 22,
                      color: palette.accent,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '书房里还没有翻开的故事',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                      fontFamilyFallback: AppTheme.serifFontFallback,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '先挑选或创建一本世界书，也可以一键导入示例世界书立刻开局。',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.65,
                      color: palette.muted,
                    ),
                  ),
                  const SizedBox(height: 22),
                  FButton(
                    prefix: const Icon(LucideIcons.plus, size: 16),
                    onPress: onNewSession,
                    child: const Text('开始一段新的推演'),
                  ),
                  if (onImportSample != null) ...<Widget>[
                    const SizedBox(height: 10),
                    FButton(
                      variant: FButtonVariant.outline,
                      prefix: const Icon(LucideIcons.bookmarkPlus, size: 16),
                      onPress: onImportSample,
                      child: const Text('一键导入示例《决胜西南1949》'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
}
