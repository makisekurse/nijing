import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../themes/app_theme.dart';

/// 现代呼吸感思考胶囊（对标 DeepSeek / Kelivo）。
///
/// - 思考进行中：左侧脉动微光点 + 实时秒表（「深度思考中 · 4.2 秒」），可随时展开查看；
/// - 正文开始流出：自动收成极简一行（「已深度思考 8.6 秒」），绝不霸占阅读视野；
/// - 也直接用于已落定章节的历史思维链折叠回看。
class ThinkingCapsule extends StatefulWidget {
  final String thought;
  final bool isLiveThinking;
  final int durationMs;
  final bool initialExpanded;
  final ValueChanged<bool>? onExpansionChanged;

  const ThinkingCapsule({
    super.key,
    required this.thought,
    this.isLiveThinking = false,
    this.durationMs = 0,
    this.initialExpanded = false,
    this.onExpansionChanged,
  });

  @override
  State<ThinkingCapsule> createState() => _ThinkingCapsuleState();
}

class _ThinkingCapsuleState extends State<ThinkingCapsule> {
  late bool _expanded;
  bool _userPinnedOpen = false;
  final ScrollController _scroll = ScrollController();
  bool _userScrolledUp = false;
  Timer? _ticker;
  int _liveMs = 0;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initialExpanded;
    _liveMs = widget.durationMs;
    _scroll.addListener(_onScroll);
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant ThinkingCapsule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.durationMs > _liveMs) {
      _liveMs = widget.durationMs;
    }
    // 正文一旦开始流出（isLiveThinking 从 true 变 false），若用户未手动钉开则自动折成一行
    if (oldWidget.isLiveThinking && !widget.isLiveThinking && !_userPinnedOpen) {
      if (_expanded) {
        _expanded = false;
        widget.onExpansionChanged?.call(false);
      }
    }
    if (oldWidget.isLiveThinking != widget.isLiveThinking) {
      _syncTicker();
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

  void _syncTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (widget.isLiveThinking) {
      _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
        if (!mounted) return;
        setState(() => _liveMs += 200);
      });
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    _userScrolledUp =
        (_scroll.position.maxScrollExtent - _scroll.position.pixels) > 24;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  String _formatDuration(int ms) {
    if (ms <= 0) return '';
    final sec = ms / 1000.0;
    if (sec < 10) return '${sec.toStringAsFixed(1)} 秒';
    return '${sec.round()} 秒';
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);
    final durLabel = _formatDuration(
      widget.durationMs > 0 ? widget.durationMs : _liveMs,
    );

    final title = widget.isLiveThinking
        ? (durLabel.isEmpty ? '深度思考中…' : '深度思考中 · $durLabel')
        : (durLabel.isEmpty ? '已深度思考' : '已深度思考 $durLabel');

    return SelectionContainer.disabled(
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: ladder.containerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: widget.isLiveThinking
                ? palette.accent.withValues(alpha: 0.32)
                : ladder.hairlineStrong,
            width: 0.8,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() {
                  _expanded = !_expanded;
                  _userPinnedOpen = _expanded;
                });
                widget.onExpansionChanged?.call(_expanded);
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
                child: Row(
                  children: <Widget>[
                    if (widget.isLiveThinking)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.8,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(palette.accent),
                        ),
                      )
                    else
                      Icon(
                        LucideIcons.brainCircuit,
                        size: 15,
                        color: palette.accent,
                      ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: widget.isLiveThinking
                              ? palette.accent
                              : palette.muted,
                        ),
                      ),
                    ),
                    Text(
                      '${widget.thought.length} 字',
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.muted.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      _expanded
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 16,
                      color: palette.muted,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: ladder.hairline, width: 0.8),
                  ),
                ),
                constraints: const BoxConstraints(maxHeight: 240),
                child: Scrollbar(
                  controller: _scroll,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    physics: const ClampingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    child: SelectableText(
                      widget.thought.trim().isEmpty
                          ? '（模型正在构思局势…）'
                          : widget.thought.trim(),
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.72,
                        color: palette.ink.withValues(alpha: 0.78),
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
