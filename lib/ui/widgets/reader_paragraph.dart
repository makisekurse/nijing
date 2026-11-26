import 'package:flutter/material.dart';

import '../../models/app_config.dart';
import '../../services/text_layout.dart';

/// 统一正文段落组件：历史章节与流式预览严格复用，杜绝流式落定瞬间排版跳变。
class ReaderParagraph extends StatelessWidget {
  final String text;
  final double fontSize;
  final double lineHeight;
  final int indentLevel;
  final Color color;
  final TextAlign align;

  const ReaderParagraph({
    super.key,
    required this.text,
    required this.fontSize,
    required this.lineHeight,
    required this.indentLevel,
    required this.color,
    this.align = TextAlign.justify,
  });

  @override
  Widget build(BuildContext context) {
    final indentPx = indentLevel * fontSize;
    return Text.rich(
      TextSpan(
        children: <InlineSpan>[
          if (indentPx > 0)
            WidgetSpan(
              child: SizedBox(width: indentPx, height: fontSize),
              alignment: PlaceholderAlignment.middle,
            ),
          TextSpan(text: text),
        ],
      ),
      textAlign: align,
      style: TextStyle(
        fontSize: fontSize,
        height: lineHeight,
        letterSpacing: 0.4,
        color: color,
      ),
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
            ),
          ),
      ],
    );
  }
}
