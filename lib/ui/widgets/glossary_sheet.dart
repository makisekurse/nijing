import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/annotation.dart';
import '../themes/app_theme.dart';

/// 词条与人物志的底部弹出层（统一 `forui` 视觉 + `LucideIcons`）。
///
/// 数据全部来自模型每幕随文附带的 `<glossary>` / `<cast>` 结构块或后台档案官抽取，
/// 应用本身不维护任何本地词表 —— 换任何题材的世界书都能直接用。
class AnnotationSheet {
  AnnotationSheet._();

  static Future<void> showGlossary(
    BuildContext context,
    List<GlossaryEntry> entries,
  ) {
    return _show(
      context,
      icon: LucideIcons.bookMarked,
      title: '本幕词条',
      emptyHint: '本幕没有新词条。',
      children: entries
          .map(
            (e) => _Row(title: e.term, body: e.explanation),
          )
          .toList(),
    );
  }

  static Future<void> showCast(
    BuildContext context,
    List<CastEntry> entries,
  ) {
    return _show(
      context,
      icon: LucideIcons.users,
      title: '本幕人物',
      emptyHint: '本幕没有新人物。',
      children: entries
          .map(
            (e) => _Row(
              title: e.name,
              body: <String>[
                if (e.role.isNotEmpty) e.role,
                if (e.stance.isNotEmpty) '立场：${e.stance}',
              ].join(' · '),
            ),
          )
          .toList(),
    );
  }

  static Future<void> _show(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String emptyHint,
    required List<Widget> children,
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
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
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
                      Icon(icon, size: 17, color: palette.accent),
                      const SizedBox(width: 8),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Flexible(
                    child: children.isEmpty
                        ? Text(
                            emptyHint,
                            style: TextStyle(
                              fontSize: 13,
                              color: palette.muted,
                            ),
                          )
                        : ListView(
                            shrinkWrap: true,
                            physics: const ClampingScrollPhysics(),
                            children: children,
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final String body;

  const _Row({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FCard(
        child: Padding(
          padding: const EdgeInsets.all(13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: palette.accent,
                ),
              ),
              if (body.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.6,
                    color: palette.ink.withValues(alpha: 0.9),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
