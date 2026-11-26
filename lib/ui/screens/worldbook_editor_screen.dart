import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/world_book_repository.dart';
import '../../models/world_book.dart';
import '../../services/file_export_service.dart';
import '../../state/library_provider.dart';
import '../themes/app_theme.dart';
import '../widgets/app_toast.dart';

/// 世界书编辑器（`forui` 骨架：首屏聚焦核心 3 项，进阶 9 项收纳进 `FAccordion`）。
class WorldBookEditorScreen extends StatefulWidget {
  final WorldBook book;
  final bool isPreview;

  const WorldBookEditorScreen({
    super.key,
    required this.book,
    this.isPreview = false,
  });

  @override
  State<WorldBookEditorScreen> createState() => _WorldBookEditorScreenState();
}

class _WorldBookEditorScreenState extends State<WorldBookEditorScreen> {
  late TextEditingController _name;
  late TextEditingController _era;
  late TextEditingController _worldview;
  late TextEditingController _playerRole;
  late TextEditingController _style;
  late TextEditingController _rules;
  late TextEditingController _opening;
  late TextEditingController _choices;
  late TextEditingController _goal;
  late TextEditingController _characters;
  late TextEditingController _factions;
  late TextEditingController _locations;
  late TextEditingController _dimensions;

  @override
  void initState() {
    super.initState();
    final b = widget.book;
    _name = TextEditingController(text: b.name);
    _era = TextEditingController(text: b.era);
    _worldview = TextEditingController(text: b.worldview);
    _playerRole = TextEditingController(text: b.playerRole);
    _style = TextEditingController(text: b.narrativeStyle);
    _rules = TextEditingController(text: b.extraRules);
    _opening = TextEditingController(text: b.openingScene);
    _choices = TextEditingController(text: b.openingChoices.join('\n'));
    _goal = TextEditingController(text: b.playerGoal);
    _characters = TextEditingController(text: b.keyCharacters);
    _factions = TextEditingController(text: b.keyFactions);
    _locations = TextEditingController(text: b.keyLocations);
    _dimensions = TextEditingController(text: b.stateDimensions);
  }

  @override
  void dispose() {
    for (final c in <TextEditingController>[
      _name,
      _era,
      _worldview,
      _playerRole,
      _style,
      _rules,
      _opening,
      _choices,
      _goal,
      _characters,
      _factions,
      _locations,
      _dimensions,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  WorldBook _collect() => widget.book.copyWith(
        name: _name.text.trim().isEmpty ? '未命名世界书' : _name.text.trim(),
        era: _era.text.trim(),
        worldview: _worldview.text.trim(),
        playerRole: _playerRole.text.trim(),
        narrativeStyle: _style.text.trim(),
        extraRules: _rules.text.trim(),
        openingScene: _opening.text.trim(),
        openingChoices: _choices.text
            .split('\n')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
        playerGoal: _goal.text.trim(),
        keyCharacters: _characters.text.trim(),
        keyFactions: _factions.text.trim(),
        keyLocations: _locations.text.trim(),
        stateDimensions: _dimensions.text.trim(),
      );

  Future<void> _save() async {
    HapticFeedback.lightImpact();
    final book = _collect();
    LibraryProvider? lib;
    try {
      lib = Provider.of<LibraryProvider>(context, listen: false);
    } catch (_) {}
    if (lib != null) {
      await lib.upsertBook(book);
    } else {
      await WorldBookRepository.upsert(book);
    }
    if (!mounted) return;
    Navigator.of(context).pop(book);
  }

  Future<void> _export() async {
    final book = _collect();
    final json = book.exportToJson();
    final ts = FileExportService.formatTimestamp();
    final safeName = FileExportService.sanitizeFileName(book.name);
    final fileName = '拟境_世界书_${safeName}_$ts.json';

    final res = await FileExportService.exportFile(
      fileName: fileName,
      content: json,
      mimeType: 'application/json',
    );
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    AppToast.show(
      context,
      res.success
          ? '世界书已保存至：${res.path}（已同时复制到剪贴板）'
          : '保存失败：${res.message}（已复制到剪贴板）',
      duration: const Duration(seconds: 6),
      actionLabel: '系统分享',
      onAction: () => FileExportService.shareText(
        title: '世界书 · ${book.name}',
        text: json,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: Text(widget.isPreview ? '预览并确认世界书' : '编辑世界书'),
        prefixes: <Widget>[
          FHeaderAction.back(onPress: () => Navigator.of(context).maybePop()),
        ],
        suffixes: <Widget>[
          FHeaderAction(
            icon: const Icon(LucideIcons.share2, size: 18),
            onPress: _export,
          ),
          FHeaderAction(
            icon: Icon(LucideIcons.check, size: 19, color: palette.accent),
            onPress: _save,
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 48),
        children: <Widget>[
          FCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(LucideIcons.bookOpen, size: 16, color: palette.accent),
                      const SizedBox(width: 7),
                      Text(
                        '核心设定（填完即可开局）',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: palette.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _singleField(_name, '世界书名 *', '例如：决胜西南1949'),
                  _singleField(_era, '时代与跨度', '例如：1949年10月 - 1952年7月'),
                  _multiField(
                    _worldview,
                    '世界观与背景设定 *',
                    '时代背景、局势、主要矛盾、地理与制度环境……模型据此推演',
                    minLines: 4,
                    maxLines: 8,
                  ),
                  _multiField(
                    _playerRole,
                    '你扮演的人物 *',
                    '身份、职务、年龄、性格、立场，例如「西南局第一书记，45岁」',
                    minLines: 2,
                    maxLines: 4,
                    last: true,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          FCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: FAccordion(
                children: <FAccordionItemMixin>[
                  FAccordionItem(
                    title: const Text('叙事风格、目标与世界禁忌'),
                    initiallyExpanded: widget.isPreview,
                    child: Column(
                      children: <Widget>[
                        const SizedBox(height: 8),
                        _multiField(
                          _goal,
                          '玩家目标',
                          '这一局你想做什么、想验证什么',
                          minLines: 2,
                          maxLines: 3,
                        ),
                        _multiField(
                          _style,
                          '叙事文风',
                          '例如：白描为主，沉稳遒劲，多用军情电报与公文语气',
                          minLines: 2,
                          maxLines: 3,
                        ),
                        _multiField(
                          _rules,
                          '世界规则与禁忌',
                          '你不希望出现的内容，或必须遵守的设定',
                          minLines: 2,
                          maxLines: 4,
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  FAccordionItem(
                    title: const Text('关键人物、势力、地点与状态维度'),
                    initiallyExpanded: widget.isPreview,
                    child: Column(
                      children: <Widget>[
                        const SizedBox(height: 8),
                        _multiField(
                          _characters,
                          '关键人物',
                          '一行一位：姓名 | 身份 | 立场',
                          minLines: 3,
                          maxLines: 6,
                        ),
                        _multiField(
                          _factions,
                          '关键势力',
                          '一行一方：名称 | 诉求 | 与主角的关系',
                          minLines: 2,
                          maxLines: 4,
                        ),
                        _multiField(
                          _locations,
                          '关键地点',
                          '一行一处：地名 | 意义',
                          minLines: 2,
                          maxLines: 4,
                        ),
                        _multiField(
                          _dimensions,
                          '状态维度模板',
                          '告诉后台档案官重点盯住哪些局势维度',
                          minLines: 2,
                          maxLines: 3,
                          last: true,
                        ),
                      ],
                    ),
                  ),
                  FAccordionItem(
                    title: const Text('自定义开篇场景与初始分支'),
                    initiallyExpanded: widget.isPreview,
                    child: Column(
                      children: <Widget>[
                        const SizedBox(height: 8),
                        _multiField(
                          _opening,
                          '开篇场景（留空则由模型自动起笔）',
                          '第一幕开局文字',
                          minLines: 3,
                          maxLines: 6,
                        ),
                        _multiField(
                          _choices,
                          '开篇分支（一行一条）',
                          '留空则第一幕分支也由模型生成',
                          minLines: 2,
                          maxLines: 4,
                          last: true,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          FButton(
            prefix: const Icon(LucideIcons.check, size: 17),
            onPress: _save,
            child: Text(widget.isPreview ? '确认并保存世界书' : '保存修改'),
          ),
        ],
      ),
    );
  }

  Widget _singleField(
    TextEditingController ctrl,
    String label,
    String hint,
  ) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: FTextField(
          control: FTextFieldControl.managed(controller: ctrl),
          label: Text(label),
          hint: hint,
        ),
      );

  Widget _multiField(
    TextEditingController ctrl,
    String label,
    String hint, {
    int minLines = 2,
    int maxLines = 4,
    bool last = false,
  }) =>
      Padding(
        padding: EdgeInsets.only(bottom: last ? 4 : 14),
        child: FTextField.multiline(
          control: FTextFieldControl.managed(controller: ctrl),
          label: Text(label),
          hint: hint,
          minLines: minLines,
          maxLines: maxLines,
        ),
      );
}
