import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/annotation.dart';
import '../../models/chapter_node.dart';
import '../themes/app_theme.dart';

/// 人物志（`forui` 卡片流）。
class CastScreen extends StatelessWidget {
  final List<ChapterNode> history;

  const CastScreen({super.key, required this.history});

  List<CastEntry> _aggregate() {
    final map = <String, CastEntry>{};
    for (final node in history) {
      for (final e in node.cast) {
        final key = e.name.trim();
        if (key.isEmpty) continue;
        final prev = map[key];
        map[key] = prev == null ? e : prev.merge(e);
      }
    }
    final list = map.values.toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final entries = _aggregate();

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('人物志'),
        prefixes: <Widget>[
          FHeaderAction.back(onPress: () => Navigator.of(context).maybePop()),
        ],
      ),
      child: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(LucideIcons.users, size: 28, color: palette.muted),
                    const SizedBox(height: 12),
                    Text(
                      '还没有人物记录。\n推演几幕后，后台档案官会自动整理出场人物。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.7,
                        color: palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 36),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final e = entries[i];
                return FCard(
                  child: Padding(
                    padding: const EdgeInsets.all(15),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              e.name,
                              style: TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                color: palette.ink,
                                fontFamilyFallback: AppTheme.serifFontFallback,
                              ),
                            ),
                            if (e.role.isNotEmpty) ...<Widget>[
                              const SizedBox(width: 8),
                              Flexible(
                                child: FBadge(
                                  variant: FBadgeVariant.secondary,
                                  child: Text(
                                    e.role,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        if (e.stance.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            e.stance,
                            style: TextStyle(
                              fontSize: 13,
                              height: 1.55,
                              color: palette.muted,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
