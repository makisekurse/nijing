import 'package:flutter/material.dart';

import '../../data/secure_store.dart';
import '../../data/world_book_repository.dart';
import '../../models/app_config.dart';
import '../../models/world_book.dart';
import '../../services/world_builder_service.dart';
import 'worldbook_editor_screen.dart';

/// 快速创建世界：一句自然语言 → AI 扩写成世界书 → 预览可编辑 → 才落库。
///
/// 失败不会卡住用户：一律提示并给「用空白模板手写」的退路。
class QuickCreateScreen extends StatefulWidget {
  final AppConfig config;

  const QuickCreateScreen({super.key, required this.config});

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

    final apiKey = await SecureStore.readApiKey();
    final res = await WorldBuilderService.buildWithResult(
      config: widget.config,
      apiKey: apiKey,
      description: text,
      workspaceId: widget.config.workspaceId,
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

  /// 生成结果不直接落库 —— 先让用户过一眼、可编辑，确认后才保存。
  Future<void> _previewAndSave(WorldBook book) async {
    final saved = await Navigator.of(context).push<WorldBook>(
      MaterialPageRoute<WorldBook>(
        builder: (_) => WorldBookEditorScreen(book: book, isPreview: true),
      ),
    );
    if (!mounted) return;
    if (saved != null) {
      await WorldBookRepository.upsert(saved);
      if (!mounted) return;
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
      await WorldBookRepository.upsert(saved);
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('创建世界')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        children: <Widget>[
          Text(
            '用一句话描述你想进入的世界',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '越具体越好：时代、地点、你是谁、想做什么。'
            '生成后可以逐项修改，确认了才会保存。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.7,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _desc,
            maxLines: 5,
            minLines: 3,
            enabled: !_busy,
            decoration: const InputDecoration(
              hintText: '例如：我想在 1936 年的北平扮演一名记者，尽量遵循历史，但允许改变历史。',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _examples
                .map(
                  (e) => ActionChip(
                    label: Text(
                      e.length > 18 ? '${e.substring(0, 18)}…' : e,
                      style: const TextStyle(fontSize: 12),
                    ),
                    onPressed: _busy
                        ? null
                        : () => setState(() => _desc.text = e),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _generate,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_rounded, size: 18),
              label: Text(_busy ? '正在生成…' : '生成世界'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: _busy ? null : _blankTemplate,
              child: const Text('不用 AI，我自己写'),
            ),
          ),
          if (_error.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.dividerColor),
              ),
              child: Text(
                _error,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.65,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
