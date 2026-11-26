import 'package:flutter/material.dart';
import 'package:forui/forui.dart';

import '../../models/chapter_node.dart';
import '../themes/app_theme.dart';

/// 编年史时间线（`forui` 骨架 + 精致纵轴卡片）。
class ChronicleScreen extends StatelessWidget {
  final List<ChapterNode> history;

  const ChronicleScreen({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('编年史'),
        prefixes: <Widget>[
          FHeaderAction.back(onPress: () => Navigator.of(context).maybePop()),
        ],
      ),
      child: history.isEmpty
          ? Center(
              child: Text(
                '还没有推演记录。',
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 36),
              itemCount: history.length,
              itemBuilder: (_, i) {
                final node = history[i];
                final excerpt = node.content.length > 96
                    ? '${node.content.substring(0, 96)}…'
                    : node.content;
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(
                        width: 22,
                        child: Column(
                          children: <Widget>[
                            Container(
                              width: 9,
                              height: 9,
                              margin: const EdgeInsets.only(top: 14),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: palette.accent,
                              ),
                            ),
                            if (i < history.length - 1)
                              Expanded(
                                child: Container(
                                  width: 1,
                                  color: ladder.hairlineStrong,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: FCard(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    node.date.trim().isEmpty
                                        ? '第 ${node.chapterIndex} 幕'
                                        : '第 ${node.chapterIndex} 幕 · ${node.date.trim()}',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                      color: palette.accent,
                                    ),
                                  ),
                                  if ((node.playerAction ?? '')
                                      .trim()
                                      .isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 6),
                                    Text(
                                      '决定：${node.playerAction!.trim()}',
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w600,
                                        height: 1.5,
                                        color: palette.ink,
                                      ),
                                    ),
                                  ],
                                  if (excerpt.trim().isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 6),
                                    Text(
                                      excerpt.trim(),
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        height: 1.6,
                                        color: palette.muted,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
