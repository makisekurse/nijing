import 'package:flutter/material.dart';

import '../../models/app_config.dart';
import '../../services/text_layout.dart';
import '../themes/app_theme.dart';

/// 统一文学正文段落组件（v2.0 升级）。
///
/// 1. 历史章节与流式预览严格复用，落定瞬间零排版跳变；
/// 2. 支持基础文学排版：电报/书信引用块（`> ...`）、行内加粗（`**...**`）、斜体（`*...*`）不露裸星号；
/// 3. 支持「书卷衬线阅读」字体切换与精准全角段首缩进。
class ReaderParagraph extends StatelessWidget {
  final String text;
  final double fontSize;
  final double lineHeight;
  final int indentLevel;
  final Color color;
  final TextAlign align;
  final bool serif;

  const ReaderParagraph({
    super.key,
    required this.text,
    required this.fontSize,
    required this.lineHeight,
    required this.indentLevel,
    required this.color,
    this.align = TextAlign.justify,
    this.serif = false,
  });

  static final RegExp _inlineFmt = RegExp(
    r'\*\*(.+?)\*\*|__(.+?)__|\*([^*\n]+?)\*',
  );

  /// 将行内基础 Markdown（加粗/斜体）解析为干净的 [InlineSpan] 列表，不露裸星号。
  static List<InlineSpan> parseInlineSpans(
    String input,
    TextStyle baseStyle,
  ) {
    if (!input.contains('*') && !input.contains('_')) {
      return <InlineSpan>[TextSpan(text: input)];
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final m in _inlineFmt.allMatches(input)) {
      if (m.start > cursor) {
        spans.add(TextSpan(text: input.substring(cursor, m.start)));
      }
      final boldA = m.group(1);
      final boldB = m.group(2);
      final italic = m.group(3);
      if (boldA != null || boldB != null) {
        spans.add(
          TextSpan(
            text: boldA ?? boldB,
            style: baseStyle.copyWith(fontWeight: FontWeight.w700),
          ),
        );
      } else if (italic != null) {
        spans.add(
          TextSpan(
            text: italic,
            style: baseStyle.copyWith(fontStyle: FontStyle.italic),
          ),
        );
      }
      cursor = m.end;
    }
    if (cursor < input.length) {
      spans.add(TextSpan(text: input.substring(cursor)));
    }
    return spans.isEmpty ? <InlineSpan>[TextSpan(text: input)] : spans;
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = TextStyle(
      fontSize: fontSize,
      height: lineHeight,
      letterSpacing: 0.35,
      color: color,
      fontFamilyFallback: serif ? AppTheme.serifFontFallback : null,
    );

    final trimmed = text.trimLeft();
    // 电报 / 公文 / 书信引用块（`> ...`）
    if (trimmed.startsWith('>')) {
      final quoteBody = trimmed.replaceFirst(RegExp(r'^>\s*'), '');
      final palette = AppTheme.readingOf(context);
      final ladder = AppTheme.ladderOf(context);
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        decoration: BoxDecoration(
          color: ladder.containerLow,
          borderRadius: const BorderRadius.horizontal(right: Radius.circular(10)),
          border: Border(
            left: BorderSide(color: palette.accent.withValues(alpha: 0.7), width: 2.5),
          ),
        ),
        child: Text.rich(
          TextSpan(
            children: parseInlineSpans(
              quoteBody,
              baseStyle.copyWith(
                fontSize: fontSize - 0.8,
                color: color.withValues(alpha: 0.90),
              ),
            ),
          ),
          style: baseStyle.copyWith(
            fontSize: fontSize - 0.8,
            color: color.withValues(alpha: 0.90),
          ),
        ),
      );
    }

    // 场景分隔线（`---` / `***`）渲染为克制的细线装饰
    if (RegExp(r'^[-*—─]{3,}$').hasMatch(trimmed)) {
      final palette = AppTheme.readingOf(context);
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Container(
            width: 48,
            height: 1,
            color: palette.rule,
          ),
        ),
      );
    }

    final indentPx = indentLevel * fontSize;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          if (indentPx > 0)
            WidgetSpan(
              child: SizedBox(width: indentPx, height: fontSize),
              alignment: PlaceholderAlignment.middle,
            ),
          ...parseInlineSpans(text, baseStyle),
        ],
      ),
      textAlign: align,
      style: baseStyle,
    );
  }
}

/// 将多段文本按阅读排版设置切段渲染。
class ReaderParagraphList extends StatelessWidget {
  final String content;
  final AppConfig config;
  final double fontSize;
  final Color color;

  const ReaderParagraphList({
    super.key,
    required this.content,
    required this.config,
    required this.fontSize,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final paragraphs = TextLayout.paragraphs(content);
    if (paragraphs.isEmpty) return const SizedBox.shrink();
    final gap = TextLayout.spacing(config.paragraphSpacing);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final para in paragraphs)
          Padding(
            padding: EdgeInsets.only(bottom: gap),
            child: ReaderParagraph(
              text: para,
              fontSize: fontSize,
              lineHeight: config.lineHeight,
              indentLevel: config.paragraphIndent,
              color: color,
              serif: config.serifReading,
            ),
          ),
      ],
    );
  }
}
