import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../themes/app_theme.dart';

/// 现代贴底交互舱（吸收 Kelivo 固定底栏 + 建议行动药丸 + 断流续写提示条）。
///
/// 永远贴底稳如泰山，弹键盘丝滑顶起；上方挂接可折叠「建议决断」面板（阅读正文时自动收起），
/// 断流时原地显示「继续生成 / 直接保存 / 重试」操作条，绝不清空用户正在读的文字。
class ReaderComposer extends StatelessWidget {
  final bool busy;
  final bool interrupted;
  final bool hasLiveBody;
  final bool isEmptyHistory;
  final String notice;
  final List<String> choices;
  final bool choicesExpanded;
  final VoidCallback onToggleChoices;
  final ValueChanged<String> onPickChoice;
  final VoidCallback onStartOpening;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool godMode;
  final ValueChanged<bool> onToggleGodMode;
  final ValueChanged<String> onSend;
  final VoidCallback onCancel;
  final VoidCallback onContinue;
  final VoidCallback onCommitInterrupted;
  final VoidCallback onRetry;
  final VoidCallback onDiscardInterrupted;

  const ReaderComposer({
    super.key,
    required this.busy,
    required this.interrupted,
    required this.hasLiveBody,
    required this.isEmptyHistory,
    required this.notice,
    required this.choices,
    required this.choicesExpanded,
    required this.onToggleChoices,
    required this.onPickChoice,
    required this.onStartOpening,
    required this.controller,
    required this.focusNode,
    required this.godMode,
    required this.onToggleGodMode,
    required this.onSend,
    required this.onCancel,
    required this.onContinue,
    required this.onCommitInterrupted,
    required this.onRetry,
    required this.onDiscardInterrupted,
  });

  static const Color _kGodGold = Color(0xFFD4AF37);

  void _submit() {
    final text = controller.text.trim();
    if (text.isEmpty || busy) return;
    HapticFeedback.lightImpact();
    controller.clear();
    focusNode.unfocus();
    onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return Container(
      decoration: BoxDecoration(
        color: ladder.page.withValues(alpha: 0.96),
        border: Border(top: BorderSide(color: ladder.hairline, width: 0.8)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 1. 断流/暂停原地续写操作条（Kelivo response_truncation_notice 范式）
              if (interrupted && hasLiveBody && !busy) ...<Widget>[
                _buildInterruptedBanner(context, palette, ladder),
                const SizedBox(height: 8),
              ] else if (notice.isNotEmpty && !busy) ...<Widget>[
                _buildNoticeStrip(palette, ladder),
                const SizedBox(height: 8),
              ],

              // 2. 无开篇且尚无历史时的「开始推演」引导按钮
              if (!busy && !interrupted && isEmptyHistory && choices.isEmpty) ...<Widget>[
                FButton(
                  prefix: const Icon(LucideIcons.sparkles, size: 16),
                  onPress: () {
                    HapticFeedback.lightImpact();
                    onStartOpening();
                  },
                  child: const Text('推开第一幕'),
                ),
                const SizedBox(height: 8),
              ],

              // 3. 可折叠「建议决断」面板（不抢阅读视野）
              if (!busy && !interrupted && choices.isNotEmpty) ...<Widget>[
                _buildChoicesPanel(palette, ladder),
                const SizedBox(height: 8),
              ],

              // 4. 固定底部输入舱
              _buildInputBar(context, palette, ladder),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInterruptedBanner(
    BuildContext context,
    ReadingPalette palette,
    dynamic ladder,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: ladder.container,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: palette.accent.withValues(alpha: 0.35),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(LucideIcons.circlePause, size: 15, color: palette.accent),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  notice.isNotEmpty ? notice : '推演已暂停，上方正文完整保留',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: palette.ink,
                  ),
                ),
              ),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: onDiscardInterrupted,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(LucideIcons.x, size: 15, color: palette.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: FButton(
                  size: FButtonSizeVariant.xs,
                  prefix: const Icon(LucideIcons.play, size: 13),
                  onPress: () {
                    HapticFeedback.lightImpact();
                    onContinue();
                  },
                  child: const Text('继续生成'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FButton(
                  variant: FButtonVariant.secondary,
                  size: FButtonSizeVariant.xs,
                  prefix: const Icon(LucideIcons.check, size: 13),
                  onPress: () {
                    HapticFeedback.lightImpact();
                    onCommitInterrupted();
                  },
                  child: const Text('直接落幕'),
                ),
              ),
              const SizedBox(width: 8),
              FButton.icon(
                variant: FButtonVariant.outline,
                size: FButtonSizeVariant.xs,
                onPress: () {
                  HapticFeedback.lightImpact();
                  onRetry();
                },
                child: const Icon(LucideIcons.rotateCcw, size: 14),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNoticeStrip(ReadingPalette palette, dynamic ladder) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: ladder.container,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: ladder.hairlineStrong, width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(LucideIcons.info, size: 15, color: palette.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice,
              style: TextStyle(fontSize: 12, height: 1.5, color: palette.ink),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChoicesPanel(ReadingPalette palette, dynamic ladder) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            HapticFeedback.selectionClick();
            onToggleChoices();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            child: Row(
              children: <Widget>[
                Icon(LucideIcons.compass, size: 13, color: palette.accent),
                const SizedBox(width: 6),
                Text(
                  '建议决断（${choices.length}）',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.muted,
                  ),
                ),
                const Spacer(),
                Text(
                  choicesExpanded ? '收起' : '展开',
                  style: TextStyle(fontSize: 11.5, color: palette.accent),
                ),
                const SizedBox(width: 3),
                Icon(
                  choicesExpanded
                      ? LucideIcons.chevronDown
                      : LucideIcons.chevronUp,
                  size: 14,
                  color: palette.accent,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          crossFadeState: choicesExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          secondChild: const SizedBox.shrink(),
          firstChild: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 196),
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                children: <Widget>[
                  for (var i = 0; i < choices.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: i == choices.length - 1 ? 0 : 7,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(13),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          onPickChoice(choices[i]);
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: ladder.card,
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(
                              color: ladder.hairlineStrong,
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Container(
                                width: 20,
                                height: 20,
                                margin: const EdgeInsets.only(top: 1),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: palette.accent.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: palette.accent,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  choices[i],
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    height: 1.48,
                                    color: palette.ink,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInputBar(
    BuildContext context,
    ReadingPalette palette,
    dynamic ladder,
  ) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
      decoration: BoxDecoration(
        color: ladder.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: godMode ? _kGodGold : ladder.hairlineStrong,
          width: godMode ? 1.4 : 0.8,
        ),
        boxShadow: godMode
            ? <BoxShadow>[
                BoxShadow(
                  color: _kGodGold.withValues(alpha: 0.16),
                  blurRadius: 12,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 3, right: 6),
            child: Tooltip(
              message: godMode ? '主宰模式已开启（绝对意志）' : '点击开启主宰模式',
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: busy
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        onToggleGodMode(!godMode);
                      },
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: godMode
                        ? _kGodGold.withValues(alpha: 0.18)
                        : ladder.containerLow,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: godMode ? _kGodGold : Colors.transparent,
                      width: 0.8,
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    LucideIcons.sparkles,
                    size: 16,
                    color: godMode
                        ? _kGodGold
                        : palette.muted.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              enabled: !busy,
              maxLines: 4,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _submit(),
              style: TextStyle(
                fontSize: 14.5,
                height: 1.45,
                color: palette.ink,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                hintText: busy
                    ? '推演生成中…'
                    : (godMode
                        ? '【主宰模式】写下世界必须服从的意志…'
                        : '写下你的行动、指令或对白…'),
                hintStyle: TextStyle(
                  fontSize: 13.5,
                  color: godMode
                      ? _kGodGold.withValues(alpha: 0.78)
                      : palette.muted.withValues(alpha: 0.72),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: busy
                ? InkWell(
                    borderRadius: BorderRadius.circular(11),
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      onCancel();
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .error
                            .withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(11),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        LucideIcons.square,
                        size: 15,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                : InkWell(
                    borderRadius: BorderRadius.circular(11),
                    onTap: _submit,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: godMode ? _kGodGold : palette.accent,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        godMode ? LucideIcons.zap : LucideIcons.arrowUp,
                        size: 17,
                        color: godMode
                            ? const Color(0xFF1A1405)
                            : Theme.of(context).colorScheme.onPrimary,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
