import 'package:flutter/material.dart';

import '../../models/world_book.dart';
import '../themes/app_theme.dart';

/// 程序化典雅书封组件（零外链、零体积开销，按世界书生成独一无二的出版物封面）。
class WorldBookCover extends StatelessWidget {
  final WorldBook book;
  final int chapterCount;
  final double width;
  final double height;
  final bool compact;

  const WorldBookCover({
    super.key,
    required this.book,
    this.chapterCount = 0,
    this.width = 72,
    this.height = 98,
    this.compact = false,
  });

  static const List<List<Color>> _palettes = <List<Color>>[
    // 墨青 + 雾金
    <Color>[Color(0xFF1A2836), Color(0xFF283E52), Color(0xFFD0A96C)],
    // 绛褐 + 宣白
    <Color>[Color(0xFF3A1F1D), Color(0xFF562C27), Color(0xFFE6C8A0)],
    // 松烟 + 玉青
    <Color>[Color(0xFF1B2E26), Color(0xFF2A453A), Color(0xFFC2D6C8)],
    // 靛紫 + 银灰
    <Color>[Color(0xFF232236), Color(0xFF353452), Color(0xFFC8C5E6)],
    // 檀木 + 琥珀
    <Color>[Color(0xFF2E241C), Color(0xFF47372A), Color(0xFFE3B987)],
    // 玄黑 + 赤陶
    <Color>[Color(0xFF1F2124), Color(0xFF31353B), Color(0xFFD97757)],
  ];

  List<Color> _pickColors() {
    final seed = '${book.id}_${book.name}'.codeUnits.fold<int>(
          0,
          (acc, c) => (acc * 31 + c) & 0x7FFFFFFF,
        );
    return _palettes[seed % _palettes.length];
  }

  @override
  Widget build(BuildContext context) {
    final colors = _pickColors();
    final bgTop = colors[0];
    final bgBottom = colors[1];
    final foil = colors[2];

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[bgTop, bgBottom],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(
          color: foil.withValues(alpha: 0.28),
          width: 0.8,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(compact ? 8 : 10),
        child: Stack(
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: _CoverPatternPainter(foil: foil),
              ),
            ),
            // 左侧装帧书脊压线
            Positioned(
              left: compact ? 6 : 8,
              top: 0,
              bottom: 0,
              child: Container(
                width: 1,
                color: Colors.white.withValues(alpha: 0.14),
              ),
            ),
            // 书名与装饰框
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? 11 : 14,
                compact ? 9 : 12,
                compact ? 7 : 10,
                compact ? 8 : 10,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: compact ? 14 : 20,
                    height: 1.5,
                    color: foil.withValues(alpha: 0.85),
                  ),
                  SizedBox(height: compact ? 6 : 8),
                  Expanded(
                    child: Text(
                      book.name,
                      maxLines: compact ? 3 : 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: compact ? 11.5 : 13,
                        fontWeight: FontWeight.w600,
                        height: 1.32,
                        color: const Color(0xFFF4F1EA),
                        fontFamilyFallback: AppTheme.serifFontFallback,
                      ),
                    ),
                  ),
                  if (chapterCount > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: foil.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: foil.withValues(alpha: 0.35),
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        '第 $chapterCount 幕',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w600,
                          color: foil,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverPatternPainter extends CustomPainter {
  final Color foil;

  const _CoverPatternPainter({required this.foil});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = foil.withValues(alpha: 0.08)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    // 极克制的古典双框暗纹
    final r = Rect.fromLTWH(size.width * 0.56, size.height * 0.54, size.width * 0.6, size.width * 0.6);
    canvas.drawOval(r, paint);
    canvas.drawOval(r.deflate(8), paint);
  }

  @override
  bool shouldRepaint(covariant _CoverPatternPainter oldDelegate) =>
      oldDelegate.foil != foil;
}
