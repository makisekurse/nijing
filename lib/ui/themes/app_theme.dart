import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';

import 'surface_ladder.dart';

/// 阅读面专用色板（与 [SurfaceLadder] 及 `forui` [FColors] 同源派生）。
class ReadingPalette extends ThemeExtension<ReadingPalette> {
  /// 阅读页底
  final Color page;

  /// 正文墨色
  final Color ink;

  /// 次要文字（日期、署名、提示）
  final Color muted;

  /// 极淡分隔线
  final Color rule;

  /// 强调色（幕首标记、你的行动、进行中）
  final Color accent;

  /// 选项卡底色
  final Color chip;

  /// 选项卡描边
  final Color chipBorder;

  /// 顶底毛玻璃遮罩底色
  final Color scrim;

  const ReadingPalette({
    required this.page,
    required this.ink,
    required this.muted,
    required this.rule,
    required this.accent,
    required this.chip,
    required this.chipBorder,
    required this.scrim,
  });

  @override
  ReadingPalette copyWith({
    Color? page,
    Color? ink,
    Color? muted,
    Color? rule,
    Color? accent,
    Color? chip,
    Color? chipBorder,
    Color? scrim,
  }) =>
      ReadingPalette(
        page: page ?? this.page,
        ink: ink ?? this.ink,
        muted: muted ?? this.muted,
        rule: rule ?? this.rule,
        accent: accent ?? this.accent,
        chip: chip ?? this.chip,
        chipBorder: chipBorder ?? this.chipBorder,
        scrim: scrim ?? this.scrim,
      );

  @override
  ReadingPalette lerp(ThemeExtension<ReadingPalette>? other, double t) {
    if (other is! ReadingPalette) return this;
    return ReadingPalette(
      page: Color.lerp(page, other.page, t)!,
      ink: Color.lerp(ink, other.ink, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      rule: Color.lerp(rule, other.rule, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      chip: Color.lerp(chip, other.chip, t)!,
      chipBorder: Color.lerp(chipBorder, other.chipBorder, t)!,
      scrim: Color.lerp(scrim, other.scrim, t)!,
    );
  }
}

class _ThemeBundle {
  final FThemeData forui;
  final ThemeData material;
  final ReadingPalette reading;
  final SurfaceLadder ladder;

  const _ThemeBundle({
    required this.forui,
    required this.material,
    required this.reading,
    required this.ladder,
  });
}

/// 拟境 v2.0 主题体系：`forui` 触控设计系统 + Claude 文学纸墨配色 + HCT 五级容器阶梯。
///
/// 保留四套用户熟悉的皮肤 ID（`mirage` / `vintage` / `dark` / `parchment`），
/// 视觉质感全面升级：告别纯黑惨白与 1px 死灰框，呈现温润纸墨、柔和明度阶梯与优雅书卷气。
class AppTheme {
  AppTheme._();

  /// 中文文学衬线字体回退链（用于书名扉页、幕首及开启「衬线阅读」时的正文）。
  static const List<String> serifFontFallback = <String>[
    'Noto Serif CJK SC',
    'Noto Serif SC',
    'Source Han Serif SC',
    'Songti SC',
    'STSong',
    'SimSun',
    'Georgia',
    'serif',
  ];

  static final _ThemeBundle _mirage = _createBundle(
    debugLabel: 'Nijing Mirage Dark',
    brightness: Brightness.dark,
    page: const Color(0xFF0E1218),
    ink: const Color(0xFFDCE3EB),
    muted: const Color(0xFF8390A0),
    accent: const Color(0xFF82AAC9),
    onAccent: const Color(0xFF0A141E),
    destructive: const Color(0xFFE06C75),
  );

  /// 时代报章（Claude 象牙暖纸 + 暖炭墨 + 赤陶砖红）
  static final _ThemeBundle _vintage = _createBundle(
    debugLabel: 'Nijing Vintage Editorial',
    brightness: Brightness.light,
    page: const Color(0xFFFAF9F5),
    ink: const Color(0xFF141413),
    muted: const Color(0xFF7B7870),
    accent: const Color(0xFFC96442),
    onAccent: const Color(0xFFFAF9F5),
    destructive: const Color(0xFFB9382C),
  );

  /// 暗夜墨石（Claude 橄榄暖炭黑 + 暖象牙墨 + 琥珀暖橘）
  static final _ThemeBundle _dark = _createBundle(
    debugLabel: 'Nijing Warm Slate Dark',
    brightness: Brightness.dark,
    page: const Color(0xFF141413),
    ink: const Color(0xFFEBE8E1),
    muted: const Color(0xFF938F86),
    accent: const Color(0xFFD98856),
    onAccent: const Color(0xFF1A120B),
    destructive: const Color(0xFFE0685A),
  );

  /// 素雅宣纸（温润宣白 + 古墨 + 赭石褐）
  static final _ThemeBundle _parchment = _createBundle(
    debugLabel: 'Nijing Parchment Light',
    brightness: Brightness.light,
    page: const Color(0xFFF6F3EB),
    ink: const Color(0xFF23201C),
    muted: const Color(0xFF857E71),
    accent: const Color(0xFF6B5842),
    onAccent: const Color(0xFFFAF8F3),
    destructive: const Color(0xFFB43F34),
  );

  static ThemeData get mirage => _mirage.material;
  static ThemeData get vintage => _vintage.material;
  static ThemeData get dark => _dark.material;
  static ThemeData get parchment => _parchment.material;

  static const List<ThemePreset> presets = <ThemePreset>[
    ThemePreset(id: 'mirage', label: '拟境', desc: '冷调深墨 · 雾蓝微光'),
    ThemePreset(id: 'vintage', label: '纸墨', desc: '象牙暖纸 · 赤陶书卷'),
    ThemePreset(id: 'dark', label: '墨石', desc: '暖炭夜读 · 琥珀柔光'),
    ThemePreset(id: 'parchment', label: '宣纸', desc: '素雅古纸 · 赭墨白描'),
  ];

  static const String defaultId = 'mirage';

  static _ThemeBundle _bundleOf(String mode) {
    switch (mode) {
      case 'mirage':
        return _mirage;
      case 'dark':
        return _dark;
      case 'parchment':
        return _parchment;
      case 'vintage':
      default:
        return _vintage;
    }
  }

  static ThemeData getTheme(String mode) => _bundleOf(mode).material;

  static FThemeData getForuiTheme(String mode) => _bundleOf(mode).forui;

  static ReadingPalette readingOf(BuildContext context) =>
      Theme.of(context).extension<ReadingPalette>() ?? _mirage.reading;

  static SurfaceLadder ladderOf(BuildContext context) =>
      Theme.of(context).extension<SurfaceLadder>() ?? _mirage.ladder;

  static ReadingPalette paletteOfId(String id) => _bundleOf(id).reading;

  static double getFontSize(String size) {
    switch (size) {
      case 'sm':
        return 15.0;
      case 'lg':
        return 19.5;
      case 'md':
      default:
        return 17.0;
    }
  }

  static _ThemeBundle _createBundle({
    required String debugLabel,
    required Brightness brightness,
    required Color page,
    required Color ink,
    required Color muted,
    required Color accent,
    required Color onAccent,
    required Color destructive,
  }) {
    final isDark = brightness == Brightness.dark;
    final ladder = SurfaceLadder.derive(
      page: page,
      ink: ink,
      brightness: brightness,
    );

    final fColors = FColors(
      brightness: brightness,
      systemOverlayStyle:
          isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      barrier: isDark ? const Color(0x99000000) : const Color(0x4D000000),
      background: ladder.page,
      foreground: ink,
      primary: accent,
      primaryForeground: onAccent,
      secondary: ladder.container,
      secondaryForeground: ink,
      muted: ladder.containerLow,
      mutedForeground: muted,
      destructive: destructive,
      destructiveForeground: const Color(0xFFFAFAFA),
      error: destructive,
      errorForeground: const Color(0xFFFAFAFA),
      card: ladder.card,
      border: ladder.hairlineStrong,
    );

    final fTheme = FThemeData(
      debugLabel: debugLabel,
      colors: fColors,
      touch: true,
    );

    final reading = ReadingPalette(
      page: ladder.page,
      ink: ink,
      muted: muted,
      rule: ladder.hairline,
      accent: accent,
      chip: ladder.card,
      chipBorder: ladder.hairlineStrong,
      scrim: ladder.page.withValues(alpha: 0.90),
    );

    final colorScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
    ).copyWith(
      brightness: brightness,
      primary: accent,
      onPrimary: onAccent,
      surface: ladder.page,
      onSurface: ink,
      surfaceContainerLowest: ladder.containerLowest,
      surfaceContainerLow: ladder.containerLow,
      surfaceContainer: ladder.container,
      surfaceContainerHigh: ladder.containerHigh,
      surfaceContainerHighest: ladder.containerHighest,
      outline: ladder.hairlineStrong,
      outlineVariant: ladder.hairline,
      error: destructive,
    );

    final material = ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: ladder.page,
      canvasColor: ladder.page,
      cardColor: ladder.card,
      dividerColor: ladder.hairline,
      colorScheme: colorScheme,
      extensions: <ThemeExtension<dynamic>>[reading, ladder],
      appBarTheme: AppBarTheme(
        backgroundColor: ladder.page,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: ladder.page,
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: DividerThemeData(
        color: ladder.hairline,
        thickness: 0.8,
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: ladder.card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: ladder.hairlineStrong, width: 0.8),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: ladder.card,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        filled: true,
        fillColor: ladder.containerLow,
        labelStyle: TextStyle(fontSize: 13, color: muted),
        hintStyle: TextStyle(fontSize: 13, color: muted.withValues(alpha: 0.65)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: ladder.hairlineStrong, width: 0.8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: ladder.hairlineStrong, width: 0.8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: accent, width: 1.4),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: ladder.containerHighest,
        contentTextStyle: TextStyle(color: ink, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: ladder.hairlineStrong, width: 0.8),
        ),
      ),
    );

    return _ThemeBundle(
      forui: fTheme,
      material: material,
      reading: reading,
      ladder: ladder,
    );
  }
}

class ThemePreset {
  final String id;
  final String label;
  final String desc;

  const ThemePreset({
    required this.id,
    required this.label,
    this.desc = '',
  });
}
