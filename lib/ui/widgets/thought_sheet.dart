import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../themes/app_theme.dart';
import 'app_toast.dart';

/// 推演思考（思维链）展示弹层与面板（统一 `forui` 视觉 + `LucideIcons`）。
class ThoughtSheet extends StatelessWidget {
  final String title;
  final String thought;

  const ThoughtSheet({
    super.key,
    required this.title,
    required this.thought,
  });

  static Future<void> show(
    BuildContext context, {
    required String title,
    required String thought,
  }) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);
    return showFSheet<void>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.85,
      builder: (ctx) => Material(
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: palette.page,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(top: BorderSide(color: ladder.hairlineStrong, width: 0.8)),
          ),
          child: ThoughtSheet(
            title: title,
            thought: thought,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: palette.muted.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: <Widget>[
                Icon(LucideIcons.brainCircuit, size: 18, color: palette.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '推演思考 · $title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                      color: palette.ink,
                    ),
                  ),
                ),
                FButton(
                  variant: FButtonVariant.outline,
                  size: FButtonSizeVariant.xs,
                  mainAxisSize: MainAxisSize.min,
                  prefix: const Icon(LucideIcons.copy, size: 14),
                  onPress: () async {
                    await Clipboard.setData(ClipboardData(text: thought));
                    if (context.mounted) {
                      Navigator.pop(context);
                      AppToast.show(context, '思考链内容已复制');
                    }
                  },
                  child: const Text('复制'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: ladder.containerLow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ladder.hairlineStrong, width: 0.8),
                ),
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: SelectableText(
                    thought.trim(),
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.65,
                      color: palette.ink.withValues(alpha: 0.88),
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
