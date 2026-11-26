import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/secure_store.dart';
import '../../models/app_config.dart';
import '../../models/world_book.dart';
import '../../services/world_builder_service.dart';
import '../../state/config_provider.dart';
import '../themes/app_theme.dart';
import 'worldbook_editor_screen.dart';

/// AI 一句话快速创建世界书（`forui` 骨架 + 分槽密钥读取）。
class QuickCreateScreen extends StatefulWidget {
  final AppConfig? config;

  const QuickCreateScreen({super.key, this.config});

  @override
  State<QuickCreateScreen> createState() => _QuickCreateScreenState();
}

class _QuickCreateScreenState extends State<QuickCreateScreen> {
  final TextEditingController _desc = TextEditingController();
  bool _busy = false;
  String _error = '';

  static const List<String> _examples = <String>[
    '我想在 1936 年的北平扮演一名记者，尽量遵循历史，但允许改变历史。',
    '一个架空的晚唐江湖，我是刚接手镖局的少东家，想在乱世里活下去。',
    '近未来的一座海岛城市，我是一名负责调查异常事件的巡查员。',
  ];

  @override
  void dispose() {
    _desc.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final text = _desc.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '先写一句你想进入的世界。');
      return;
    }

    setState(() {
      _busy = true;
      _error = '';
    });

    ConfigProvider? cfgProvider;
    try {
      cfgProvider = Provider.of<ConfigProvider>(context, listen: false);
    } catch (_) {}

    final cfg = cfgProvider?.config ?? widget.config ?? AppConfig();
    final apiKey = cfgProvider != null
        ? await cfgProvider.resolveActiveMainKey()
        : await SecureStore.readMainKeyForConfig(cfg);

    final res = await WorldBuilderService.buildWithResult(
      config: cfg,
      apiKey: apiKey,
      description: text,
      workspaceId: cfg.workspaceId,
    );

    if (!mounted) return;
    setState(() => _busy = false);

    if (!res.isSuccess || res.book == null) {
      setState(() {
        _error = res.error ?? '生成失败，请重试或改用空白模板手写。';
      });
      return;
    }

    await _previewAndSave(res.book!);
  }

  Future<void> _previewAndSave(WorldBook book) async {
    final saved = await Navigator.of(context).push<WorldBook>(
      MaterialPageRoute<WorldBook>(
        builder: (_) => WorldBookEditorScreen(book: book, isPreview: true),
      ),
    );
    if (!mounted) return;
    if (saved != null) {
      Navigator.of(context).pop(saved);
    }
  }

  Future<void> _blankTemplate() async {
    final book = WorldBook.blank();
    final saved = await Navigator.of(context).push<WorldBook>(
      MaterialPageRoute<WorldBook>(
        builder: (_) => WorldBookEditorScreen(book: book),
      ),
    );
    if (!mounted) return;
    if (saved != null) {
      Navigator.of(context).pop(saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('快速创建世界'),
        prefixes: <Widget>[
          FHeaderAction.back(onPress: () => Navigator.of(context).maybePop()),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: <Widget>[
          Text(
            '用一句话描述你想进入的世界',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: palette.ink,
              fontFamilyFallback: AppTheme.serifFontFallback,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '越具体越好：时代、地点、你是谁、想做什么。AI 扩写完成后会先进入编辑器预览，由你确认再保存。',
            style: TextStyle(fontSize: 13, height: 1.6, color: palette.muted),
          ),
          const SizedBox(height: 16),
          FTextField.multiline(
            control: FTextFieldControl.managed(controller: _desc),
            enabled: !_busy,
            minLines: 4,
            maxLines: 6,
            hint: '例如：我想在 1936 年的北平扮演一名记者，尽量遵循历史，但允许改变历史。',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _examples
                .map(
                  (e) => FTappable(
                    onPress: _busy
                        ? null
                        : () {
                            HapticFeedback.selectionClick();
                            setState(() => _desc.text = e);
                          },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: ladder.card,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: ladder.hairlineStrong,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        e.length > 20 ? '${e.substring(0, 20)}…' : e,
                        style: TextStyle(fontSize: 12, color: palette.ink),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 20),
          FButton(
            prefix: _busy
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.sparkles, size: 17),
            onPress: _busy ? null : _generate,
            child: Text(_busy ? '正在扩写世界书…' : '生成世界书'),
          ),
          const SizedBox(height: 10),
          FButton(
            variant: FButtonVariant.ghost,
            onPress: _busy ? null : _blankTemplate,
            child: const Text('不用 AI，手动填写模板'),
          ),
          if (_error.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            FCard(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      LucideIcons.circleAlert,
                      size: 16,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error,
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: palette.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
