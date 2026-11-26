import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../models/app_config.dart';
import '../../services/providers.dart';
import '../themes/app_theme.dart';

/// 远端模型动态拉取与搜索选择器（借鉴 Cherry Studio / Kelivo `GET /models`）。
class RemoteModelPickerSheet {
  RemoteModelPickerSheet._();

  static Future<String?> show(
    BuildContext context, {
    required AppConfig config,
    required String apiKey,
    String? workspaceId,
    String currentModel = '',
  }) {
    return showFSheet<String>(
      context: context,
      side: FLayout.btt,
      mainAxisMaxRatio: 0.85,
      builder: (ctx) => _RemoteModelPickerBody(
        config: config,
        apiKey: apiKey,
        workspaceId: workspaceId,
        currentModel: currentModel,
      ),
    );
  }
}

class _RemoteModelPickerBody extends StatefulWidget {
  final AppConfig config;
  final String apiKey;
  final String? workspaceId;
  final String currentModel;

  const _RemoteModelPickerBody({
    required this.config,
    required this.apiKey,
    this.workspaceId,
    required this.currentModel,
  });

  @override
  State<_RemoteModelPickerBody> createState() => _RemoteModelPickerBodyState();
}

class _RemoteModelPickerBodyState extends State<_RemoteModelPickerBody> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _loading = true;
  String _error = '';
  List<RemoteModelInfo> _all = <RemoteModelInfo>[];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final list = await Providers.fetchRemoteModels(
        config: widget.config,
        apiKey: widget.apiKey,
        workspaceId: widget.workspaceId,
      );
      if (!mounted) return;
      setState(() {
        _all = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<RemoteModelInfo> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return _all
        .where(
          (m) =>
              m.id.toLowerCase().contains(q) ||
              m.ownedBy.toLowerCase().contains(q),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);
    final items = _filtered;

    return Container(
      decoration: BoxDecoration(
        color: palette.page,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(top: BorderSide(color: ladder.hairlineStrong, width: 0.8)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
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
                  Icon(LucideIcons.cloudDownload, size: 17, color: palette.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '从远端接口拉取模型',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: palette.ink,
                      ),
                    ),
                  ),
                  FButton.icon(
                    variant: FButtonVariant.ghost,
                    size: FButtonSizeVariant.xs,
                    onPress: _loading ? null : _fetch,
                    child: Icon(
                      LucideIcons.refreshCw,
                      size: 16,
                      color: palette.muted,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FTextField(
                control: FTextFieldControl.managed(
                  controller: _searchCtrl,
                  onChange: (v) => setState(() => _query = v.text),
                ),
                hint: '搜索模型名，例如 qwen4 / deepseek / claude / gemini…',
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                palette.accent,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '正在请求 /models 列表…',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: palette.muted,
                              ),
                            ),
                          ],
                        ),
                      )
                    : _error.isNotEmpty
                        ? Center(
                            child: FCard(
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text(
                                      _error,
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        height: 1.6,
                                        color: palette.ink,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    FButton(
                                      variant: FButtonVariant.outline,
                                      size: FButtonSizeVariant.sm,
                                      onPress: _fetch,
                                      child: const Text('重试拉取'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        : items.isEmpty
                            ? Center(
                                child: Text(
                                  '没有匹配「$_query」的模型',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: palette.muted,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                itemCount: items.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 6),
                                itemBuilder: (_, i) {
                                  final m = items[i];
                                  final isCurrent =
                                      m.id == widget.currentModel.trim();
                                  return InkWell(
                                    borderRadius: BorderRadius.circular(11),
                                    onTap: () {
                                      HapticFeedback.selectionClick();
                                      Navigator.pop(context, m.id);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 13,
                                        vertical: 11,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isCurrent
                                            ? palette.accent
                                                .withValues(alpha: 0.12)
                                            : ladder.card,
                                        borderRadius: BorderRadius.circular(11),
                                        border: Border.all(
                                          color: isCurrent
                                              ? palette.accent
                                              : ladder.hairlineStrong,
                                          width: isCurrent ? 1.2 : 0.8,
                                        ),
                                      ),
                                      child: Row(
                                        children: <Widget>[
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: <Widget>[
                                                Text(
                                                  m.id,
                                                  style: TextStyle(
                                                    fontSize: 13.5,
                                                    fontWeight: isCurrent
                                                        ? FontWeight.w700
                                                        : FontWeight.w500,
                                                    color: palette.ink,
                                                  ),
                                                ),
                                                if (m.ownedBy.isNotEmpty)
                                                  Text(
                                                    m.ownedBy,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: palette.muted,
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                          if (isCurrent)
                                            Icon(
                                              LucideIcons.check,
                                              size: 16,
                                              color: palette.accent,
                                            ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
