import 'package:flutter/material.dart';
import 'package:material_color_utilities/material_color_utilities.dart';

/// HCT 色彩空间五级明度阶梯（吸收 Kelivo `surface_ladder.dart` 设计范式）。
///
/// 保持色相（Hue）与色度（Chroma）恒定，仅通过 HCT Tone 明度微调生成 5 级柔和容器层次
/// 与 6%~14% 极淡微描边（hairline），彻底取代生硬的 1px 灰线框毛坯观感。
class SurfaceLadder extends ThemeExtension<SurfaceLadder> {
  final Color page;
  final Color card;
  final Color surfaceFill;
  final Color hairline;
  final Color hairlineStrong;
  final Color containerLowest;
  final Color containerLow;
  final Color container;
  final Color containerHigh;
  final Color containerHighest;

  const SurfaceLadder({
    required this.page,
    required this.card,
    required this.surfaceFill,
    required this.hairline,
    required this.hairlineStrong,
    required this.containerLowest,
    required this.containerLow,
    required this.container,
    required this.containerHigh,
    required this.containerHighest,
  });

  static Color shiftTone(Color base, double delta) {
    final hct = Hct.fromInt(base.toARGB32());
    return Color(
      Hct.from(hct.hue, hct.chroma, (hct.tone + delta).clamp(0.0, 100.0))
          .toInt(),
    );
  }

  static double toneOf(Color color) => Hct.fromInt(color.toARGB32()).tone;

  static Color atTone(Color base, double tone) {
    final hct = Hct.fromInt(base.toARGB32());
    return Color(Hct.from(hct.hue, hct.chroma, tone.clamp(0.0, 100.0)).toInt());
  }

  factory SurfaceLadder.derive({
    required Color page,
    required Color ink,
    required Brightness brightness,
  }) {
    final isDark = brightness == Brightness.dark;
    if (isDark) {
      final card = shiftTone(page, 6.5);
      return SurfaceLadder(
        page: page,
        card: card,
        surfaceFill: shiftTone(page, 9.5),
        hairline: ink.withValues(alpha: 0.10),
        hairlineStrong: ink.withValues(alpha: 0.22),
        containerLowest: shiftTone(page, -2.5),
        containerLow: shiftTone(page, 3.5),
        container: shiftTone(page, 6.5),
        containerHigh: shiftTone(page, 10.0),
        containerHighest: shiftTone(page, 14.0),
      );
    }

    // 浅色纸墨（Claude 象牙纸 / 宣纸）：页面为柔和纸底，卡片略提亮，次级容器微降 Tone
    final headroom = 100.0 - toneOf(page);
    final card = headroom >= 2.2 ? atTone(page, 99.2) : shiftTone(page, -1.8);
    return SurfaceLadder(
      page: page,
      card: card,
      surfaceFill: shiftTone(page, -3.2),
      hairline: ink.withValues(alpha: 0.08),
      hairlineStrong: ink.withValues(alpha: 0.18),
      containerLowest: atTone(page, 100.0),
      containerLow: shiftTone(page, -1.2),
      container: shiftTone(page, -2.6),
      containerHigh: shiftTone(page, -4.5),
      containerHighest: shiftTone(page, -7.0),
    );
  }

  @override
  SurfaceLadder copyWith({
    Color? page,
    Color? card,
    Color? surfaceFill,
    Color? hairline,
    Color? hairlineStrong,
    Color? containerLowest,
    Color? containerLow,
    Color? container,
    Color? containerHigh,
    Color? containerHighest,
  }) =>
      SurfaceLadder(
        page: page ?? this.page,
        card: card ?? this.card,
        surfaceFill: surfaceFill ?? this.surfaceFill,
        hairline: hairline ?? this.hairline,
        hairlineStrong: hairlineStrong ?? this.hairlineStrong,
        containerLowest: containerLowest ?? this.containerLowest,
        containerLow: containerLow ?? this.containerLow,
        container: container ?? this.container,
        containerHigh: containerHigh ?? this.containerHigh,
        containerHighest: containerHighest ?? this.containerHighest,
      );

  @override
  SurfaceLadder lerp(ThemeExtension<SurfaceLadder>? other, double t) {
    if (other is! SurfaceLadder) return this;
    return SurfaceLadder(
      page: Color.lerp(page, other.page, t)!,
      card: Color.lerp(card, other.card, t)!,
      surfaceFill: Color.lerp(surfaceFill, other.surfaceFill, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      hairlineStrong: Color.lerp(hairlineStrong, other.hairlineStrong, t)!,
      containerLowest: Color.lerp(containerLowest, other.containerLowest, t)!,
      containerLow: Color.lerp(containerLow, other.containerLow, t)!,
      container: Color.lerp(container, other.container, t)!,
      containerHigh: Color.lerp(containerHigh, other.containerHigh, t)!,
      containerHighest:
          Color.lerp(containerHighest, other.containerHighest, t)!,
    );
  }
}
