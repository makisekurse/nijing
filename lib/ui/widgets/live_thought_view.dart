import 'package:flutter/material.dart';

import '../themes/app_theme.dart';

/// 流式思考面板：生成过程中实时展示模型的思维链。
///
/// 关键改进：
/// 1. 隔离在 `SelectionContainer.disabled` 内部，避免与阅读器外层 `SelectionArea` 产生手势/选区打架；
/// 2. 展开后绝不自动关闭；用户主动向上查阅时不强制拽底。
class LiveThoughtView extends StatefulWidget {
  final String thought;
  final bool initialExpanded;
  final ValueChanged<bool>? onExpansionChanged;

  const LiveThoughtView({
    super.key,
    required this.thought,
    this.initialExpanded = false,
    this.onExpansionChanged,
  });

  @override
  State<LiveThoughtView> createState() => _LiveThoughtViewState();
}

class _LiveThoughtViewState extends State<LiveThoughtView> {
  late bool _expanded;
  final ScrollController _scroll = ScrollController();
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initialExpanded;
    _scroll.addListener(_onInternalScroll);
  }

  void _onInternalScroll() {
    if (!_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final cur = _scroll.position.pixels;
    _userScrolledUp = (max - cur) > 28;
  }

  @override
  void didUpdateWidget(covariant LiveThoughtView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialExpanded != oldWidget.initialExpanded &&
        widget.initialExpanded != _expanded) {
      _expanded = widget.initialExpanded;
    }
    if (_expanded &&
        !_userScrolledUp &&
        widget.thought.length != oldWidget.thought.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients || _userScrolledUp) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_onInternalScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    return SelectionContainer.disabled(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: palette.scrim,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: palette.rule),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () {
                setState(() => _expanded = !_expanded);
                widget.onExpansionChanged?.call(_expanded);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: <Widget>[
                    Icon(
                      Icons.psychology_outlined,
                      size: 16,
                      color: palette.accent,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _expanded ? '推演思考（点击收起）' : '推演思考（点击展开）',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: palette.accent,
                        ),
                      ),
                    ),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: palette.accent,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 240),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: Scrollbar(
                    controller: _scroll,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      physics: const ClampingScrollPhysics(),
                      child: SelectableText(
                        widget.thought.trim().isEmpty
                            ? '（模型还在思考…）'
                            : widget.thought.trim(),
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.7,
                          color: palette.ink.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
