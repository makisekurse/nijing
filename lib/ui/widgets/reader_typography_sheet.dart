import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/app_config.dart';
import '../../services/text_layout.dart';
import '../themes/app_theme.dart';

/// 阅读页内实时排版调节面板（借鉴 Anx Reader / 微信读书）。
///
/// 呼出后半透明叠在底部，实时拖动行距、切皮肤、切字号或衬线书卷体，
/// 背后正文所见即所得立刻生效，无需退回“我的 → 阅读设置”盲调。
class ReaderTypographySheet {
  ReaderTypographySheet._();

  static Future<void> show(
    BuildContext context, {
    required AppConfig Function() readConfig,
    required ValueChanged<AppConfig> onApply,
  }) {
    return showFSheet<void>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.72,
      builder: (ctx) => _TypographyBody(
        readConfig: readConfig,
        onApply: onApply,
      ),
    );
  }
}

class _TypographyBody extends StatefulWidget {
  final AppConfig Function() readConfig;
  final ValueChanged<AppConfig> onApply;

  const _TypographyBody({
    required this.readConfig,
    required this.onApply,
  });

  @override
  State<_TypographyBody> createState() => _TypographyBodyState();
}

class _TypographyBodyState extends State<_TypographyBody> {
  late AppConfig _cfg;

  @override
  void initState() {
    super.initState();
    _cfg = widget.readConfig();
  }

  void _update(AppConfig next) {
    setState(() => _cfg = next);
    widget.onApply(next);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return Container(
      decoration: BoxDecoration(
        color: palette.page,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: ladder.hairlineStrong, width: 0.8)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
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
                  Icon(LucideIcons.type, size: 17, color: palette.accent),
                  const SizedBox(width: 8),
                  Text(
                    '实时阅读排版',
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 四套纸墨主题色卡
              Text(
                '纸墨主题',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.muted,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  for (final preset in AppTheme.presets)
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(
                          right: preset == AppTheme.presets.last ? 0 : 8,
                        ),
                        child: _themePill(preset, palette, ladder),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),

              // 书卷衬线切换 + 字号
              Row(
                children: <Widget>[
                  Text(
                    '字号',
                    style: TextStyle(fontSize: 13.5, color: palette.ink),
                  ),
                  const Spacer(),
                  for (final opt in const <List<String>>[
                    <String>['sm', '小'],
                    <String>['md', '中'],
                    <String>['lg', '大'],
                  ])
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _segChip(
                        label: opt[1],
                        selected: _cfg.fontSize == opt[0],
                        palette: palette,
                        ladder: ladder,
                        onTap: () => _update(_cfg.copyWith(fontSize: opt[0])),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),

              // 行距滑杆
              Row(
                children: <Widget>[
                  Text(
                    '行距',
                    style: TextStyle(fontSize: 13.5, color: palette.ink),
                  ),
                  const Spacer(),
                  Text(
                    _cfg.lineHeight.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.accent,
                    ),
                  ),
                ],
              ),
              Slider(
                value: _cfg.lineHeight.clamp(1.4, 2.6),
                min: 1.4,
                max: 2.6,
                divisions: 12,
                activeColor: palette.accent,
                onChanged: (v) => _update(_cfg.copyWith(lineHeight: v)),
              ),

              // 首行缩进 + 段间距
              Row(
                children: <Widget>[
                  Text(
                    '首行缩进',
                    style: TextStyle(fontSize: 13.5, color: palette.ink),
                  ),
                  const Spacer(),
                  for (final opt in TextLayout.indentOptions)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _segChip(
                        label: opt[1],
                        selected: '${_cfg.paragraphIndent}' == opt[0],
                        palette: palette,
                        ladder: ladder,
                        onTap: () => _update(
                          _cfg.copyWith(
                            paragraphIndent: int.tryParse(opt[0]) ?? 0,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Text(
                    '段间距',
                    style: TextStyle(fontSize: 13.5, color: palette.ink),
                  ),
                  const Spacer(),
                  for (final opt in TextLayout.spacingOptions)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: _segChip(
                        label: opt[1],
                        selected: _cfg.paragraphSpacing == opt[0],
                        palette: palette,
                        ladder: ladder,
                        onTap: () =>
                            _update(_cfg.copyWith(paragraphSpacing: opt[0])),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              FTileGroup(
                children: <FTileMixin>[
                  FTile(
                    prefix: Icon(
                      LucideIcons.bookType,
                      size: 16,
                      color: palette.accent,
                    ),
                    title: const Text('书卷衬线字体'),
                    subtitle: const Text('正文切换为典雅宋体文学排版'),
                    suffix: FSwitch(
                      value: _cfg.serifReading,
                      onChange: (v) => _update(_cfg.copyWith(serifReading: v)),
                    ),
                  ),
                  FTile(
                    prefix: Icon(
                      LucideIcons.sun,
                      size: 16,
                      color: palette.accent,
                    ),
                    title: const Text('阅读防熄屏'),
                    suffix: FSwitch(
                      value: _cfg.keepScreenOn,
                      onChange: (v) => _update(_cfg.copyWith(keepScreenOn: v)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _themePill(
    ThemePreset preset,
    ReadingPalette palette,
    dynamic ladder,
  ) {
    final selected = _cfg.themeMode == preset.id;
    final swatch = AppTheme.paletteOfId(preset.id);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        HapticFeedback.selectionClick();
        _update(_cfg.copyWith(themeMode: preset.id));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: swatch.page,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? palette.accent : ladder.hairlineStrong,
            width: selected ? 1.8 : 0.8,
          ),
        ),
        child: Column(
          children: <Widget>[
            Container(
              width: 16,
              height: 4,
              decoration: BoxDecoration(
                color: swatch.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              preset.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: swatch.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _segChip({
    required String label,
    required bool selected,
    required ReadingPalette palette,
    required dynamic ladder,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? palette.accent.withValues(alpha: 0.16) : ladder.card,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? palette.accent : ladder.hairlineStrong,
            width: selected ? 1.2 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? palette.accent : palette.ink,
          ),
        ),
      ),
    );
  }
}
