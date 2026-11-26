import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../data/secure_store.dart';
import '../../models/app_config.dart';
import '../../models/model_profile.dart';
import '../../services/llm_client.dart';
import '../../services/providers.dart';
import '../../state/config_provider.dart';
import '../themes/app_theme.dart';
import 'remote_model_picker_sheet.dart';

/// 设置页「模型与接口」完整面板（`forui` 骨架 + 分槽独立加密 Key + 动态 `/models` + 跨厂商主辅双模型）。
class SettingsModelSection extends StatefulWidget {
  final AppConfig config;
  final ConfigProvider? configProvider;
  final void Function(AppConfig next, {bool immediate}) onApply;

  const SettingsModelSection({
    super.key,
    required this.config,
    required this.configProvider,
    required this.onApply,
  });

  @override
  State<SettingsModelSection> createState() => _SettingsModelSectionState();
}

class _SettingsModelSectionState extends State<SettingsModelSection> {
  late TextEditingController _keyCtrl;
  late TextEditingController _wsCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _baseUrlCtrl;

  late TextEditingController _auxModelCtrl;
  late TextEditingController _auxBaseUrlCtrl;
  late TextEditingController _auxKeyCtrl;

  bool _obscure = true;
  bool _obscureAux = true;
  bool _testing = false;
  String _testResult = '';

  AppConfig get _cfg => widget.config;

  @override
  void initState() {
    super.initState();
    _keyCtrl = TextEditingController();
    _wsCtrl = TextEditingController(text: _cfg.workspaceId);
    _modelCtrl = TextEditingController(text: _cfg.modelName);
    _baseUrlCtrl = TextEditingController(text: _cfg.baseUrl);
    _auxModelCtrl = TextEditingController(text: _cfg.auxModelName);
    _auxBaseUrlCtrl = TextEditingController(text: _cfg.auxBaseUrl);
    _auxKeyCtrl = TextEditingController();
    _loadKeysForCurrentProvider();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _wsCtrl.dispose();
    _modelCtrl.dispose();
    _baseUrlCtrl.dispose();
    _auxModelCtrl.dispose();
    _auxBaseUrlCtrl.dispose();
    _auxKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadKeysForCurrentProvider() async {
    final mainKey = await SecureStore.readKeyForProvider(_cfg.apiProvider);
    final auxKey = await SecureStore.readAuxDedicatedKey();
    if (!mounted) return;
    setState(() {
      _keyCtrl.text = mainKey;
      _auxKeyCtrl.text = auxKey;
    });
  }

  Future<void> _switchProvider(String providerId) async {
    if (providerId == _cfg.apiProvider) return;
    HapticFeedback.selectionClick();
    final p = Providers.byId(providerId);
    final savedKey = await SecureStore.readKeyForProvider(
      providerId,
      fallbackToLegacy: false,
    );
    if (!mounted) return;
    _keyCtrl.text = savedKey;
    _modelCtrl.text = p.defaultModel;
    _baseUrlCtrl.text = '';
    setState(() => _testResult = '');
    widget.onApply(
      _cfg.copyWith(
        apiProvider: providerId,
        modelName: p.defaultModel,
        baseUrl: '',
        reasoningDialect: 'auto',
      ),
      immediate: true,
    );
  }

  Future<void> _pickRemoteModel({required bool forAux}) async {
    final targetCfg = forAux ? _cfg.resolveAuxConfig() : _cfg;
    final key = forAux
        ? (_auxKeyCtrl.text.trim().isNotEmpty
            ? _auxKeyCtrl.text.trim()
            : await SecureStore.readAuxKeyForConfig(_cfg))
        : _keyCtrl.text.trim();
    if (!mounted) return;
    final picked = await RemoteModelPickerSheet.show(
      context,
      config: targetCfg,
      apiKey: key,
      workspaceId: targetCfg.workspaceId,
      currentModel: forAux ? _auxModelCtrl.text : _modelCtrl.text,
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    if (forAux) {
      _auxModelCtrl.text = picked;
      widget.onApply(_cfg.copyWith(auxModelName: picked), immediate: true);
    } else {
      _modelCtrl.text = picked;
      widget.onApply(_cfg.copyWith(modelName: picked), immediate: true);
    }
  }

  Future<void> _saveAsProfile() async {
    final nameCtrl = TextEditingController(
      text:
          '${Providers.byId(_cfg.apiProvider).shortLabel} · ${Providers.resolveModelName(_cfg)}',
    );
    final name = await showFDialog<String>(
      context: context,
      builder: (ctx, style, anim) => FDialog(
        animation: anim,
        style: style,
        builder: (c, s) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('另存为模型档案', style: s.titleTextStyle),
              const SizedBox(height: 6),
              Text(
                '将当前接口、模型、思考设置与独立加密 Key 打包保存，以后可在设置页或阅读页顶栏一键切换。',
                style: s.bodyTextStyle,
              ),
              const SizedBox(height: 12),
              FTextField(
                control: FTextFieldControl.managed(controller: nameCtrl),
                autofocus: true,
                hint: '例如：百炼 Qwen4 主力',
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FButton(
                      size: FButtonSizeVariant.sm,
                      onPress: () => Navigator.pop(c, nameCtrl.text),
                      child: const Text('保存档案'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    nameCtrl.dispose();
    if (name == null || !mounted) return;

    final p = widget.configProvider;
    if (p != null) {
      await p.saveCurrentAsProfile(name: name, apiKey: _keyCtrl.text.trim());
    } else {
      final profile = ModelProfile(
        id: ModelProfile.newId(),
        name: name.trim().isEmpty ? _cfg.modelName : name.trim(),
        apiProvider: _cfg.apiProvider,
        baseUrl: _cfg.baseUrl,
        workspaceId: _cfg.workspaceId,
        modelName: _cfg.modelName,
        reasoningDialect: _cfg.reasoningDialect,
        enableThinking: _cfg.enableThinking,
        thinkingBudget: _cfg.thinkingBudget,
        reasoningEffort: _cfg.reasoningEffort,
      );
      if (_keyCtrl.text.trim().isNotEmpty) {
        await SecureStore.writeKeyForProfile(profile.id, _keyCtrl.text.trim());
      }
      widget.onApply(
        _cfg.copyWith(savedProfiles: <ModelProfile>[..._cfg.savedProfiles, profile]),
        immediate: true,
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存模型档案「$name」')),
      );
    }
  }

  Future<void> _applyProfile(ModelProfile profile) async {
    HapticFeedback.selectionClick();
    String key = '';
    final p = widget.configProvider;
    if (p != null) {
      key = await p.applyProfile(profile);
    } else {
      key = await SecureStore.readKeyForProfile(
        profile.id,
        fallbackProviderId: profile.apiProvider,
      );
      widget.onApply(_cfg.applyProfile(profile), immediate: true);
    }
    if (!mounted) return;
    _keyCtrl.text = key;
    _wsCtrl.text = profile.workspaceId;
    _modelCtrl.text = profile.modelName;
    _baseUrlCtrl.text = profile.baseUrl;
    setState(() => _testResult = '');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换至档案「${profile.name}」')),
    );
  }

  Future<void> _deleteProfile(ModelProfile profile) async {
    final p = widget.configProvider;
    if (p != null) {
      await p.deleteProfile(profile.id);
    } else {
      await SecureStore.deleteProfileKey(profile.id);
      widget.onApply(
        _cfg.copyWith(
          savedProfiles:
              _cfg.savedProfiles.where((e) => e.id != profile.id).toList(),
        ),
        immediate: true,
      );
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final err = await LlmClient().testConnection(
      config: _cfg,
      apiKey: _keyCtrl.text.trim(),
      workspaceId: _cfg.workspaceId.trim(),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = err == null ? '✅ 连接成功，模型接口响应正常。' : '❌ $err';
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);
    final provider = Providers.byId(_cfg.apiProvider);
    final quickModels = switch (_cfg.apiProvider) {
      'deepseek' => Providers.deepseekModels,
      'custom' => Providers.customSampleModels,
      _ => Providers.bailianModels,
    };
    final retiredDs = _cfg.apiProvider == 'deepseek' &&
        Providers.isRetiredDeepSeekModel(_cfg.modelName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // 1. 已保存的多模型档案一键切换区
        if (_cfg.savedProfiles.isNotEmpty) ...<Widget>[
          FTileGroup(
            label: const Text('已保存的模型档案（一键切换 · 独立加密 Key）'),
            children: <FTileMixin>[
              for (final prof in _cfg.savedProfiles)
                FTile(
                  prefix: Icon(
                    LucideIcons.cpu,
                    size: 16,
                    color: palette.accent,
                  ),
                  title: Text(prof.name),
                  subtitle: Text(
                    '${Providers.byId(prof.apiProvider).shortLabel} · ${prof.modelName}',
                  ),
                  suffix: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (prof.modelName == _cfg.modelName &&
                          prof.apiProvider == _cfg.apiProvider)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Icon(
                            LucideIcons.check,
                            size: 16,
                            color: palette.accent,
                          ),
                        ),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _deleteProfile(prof),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            LucideIcons.trash2,
                            size: 15,
                            color: palette.muted,
                          ),
                        ),
                      ),
                    ],
                  ),
                  onPress: () => _applyProfile(prof),
                ),
            ],
          ),
          const SizedBox(height: 16),
        ],

        // 2. 主力模型与分槽加密 Key 配置卡片
        FCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '服务提供商',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    for (final opt in Providers.options)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: opt == Providers.options.last ? 0 : 8,
                          ),
                          child: _segPill(
                            label: opt.shortLabel,
                            selected: _cfg.apiProvider == opt.id,
                            palette: palette,
                            ladder: ladder,
                            onTap: () => _switchProvider(opt.id),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                FTextField(
                  control: FTextFieldControl.managed(
                    controller: _keyCtrl,
                    onChange: (v) {
                      SecureStore.writeKeyForProvider(
                        _cfg.apiProvider,
                        v.text.trim(),
                      );
                    },
                  ),
                  label: Text('${provider.shortLabel} API Key（分槽加密独立存储）'),
                  hint: 'sk-xxxx',
                  obscureText: _obscure,
                  suffixBuilder: (_, _, _) => IconButton(
                    icon: Icon(
                      _obscure ? LucideIcons.eyeOff : LucideIcons.eye,
                      size: 17,
                      color: palette.muted,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                  description: Text(
                    SecureStore.isDegraded
                        ? '当前设备不支持系统密钥链，Key 仅驻留本次运行内存。'
                        : '不同服务商的 Key 分槽加密保存在本机，切换厂商互不覆盖、绝不串 Key。',
                  ),
                ),
                const SizedBox(height: 14),
                if (_cfg.apiProvider == 'bailian') ...<Widget>[
                  FTextField(
                    control: FTextFieldControl.managed(
                      controller: _wsCtrl,
                      onChange: (v) => widget.onApply(
                        _cfg.copyWith(workspaceId: v.text.trim()),
                      ),
                    ),
                    label: const Text('华北 2 业务空间 ID（选填）'),
                    hint: '填了自动走专属加速域名',
                  ),
                  const SizedBox(height: 14),
                ],
                if (_cfg.apiProvider == 'custom') ...<Widget>[
                  FTextField(
                    control: FTextFieldControl.managed(
                      controller: _baseUrlCtrl,
                      onChange: (v) => widget.onApply(
                        _cfg.copyWith(baseUrl: v.text.trim()),
                      ),
                    ),
                    label: const Text('Base URL'),
                    hint: 'https://api.example.com/v1',
                  ),
                  const SizedBox(height: 14),
                ],
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Expanded(
                      child: FTextField(
                        control: FTextFieldControl.managed(
                          controller: _modelCtrl,
                          onChange: (v) => widget.onApply(
                            _cfg.copyWith(modelName: v.text),
                          ),
                        ),
                        label: const Text('主力模型代码'),
                        hint: provider.defaultModel.isEmpty
                            ? '例如 qwen4-max / deepseek-v4-pro'
                            : provider.defaultModel,
                      ),
                    ),
                    const SizedBox(width: 8),
                    FButton(
                      variant: FButtonVariant.outline,
                      size: FButtonSizeVariant.md,
                      mainAxisSize: MainAxisSize.min,
                      prefix: const Icon(LucideIcons.cloudDownload, size: 15),
                      onPress: () => _pickRemoteModel(forAux: false),
                      child: const Text('拉取'),
                    ),
                  ],
                ),
                if (retiredDs) ...<Widget>[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .error
                          .withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '提示：DeepSeek 官方已退役旧版 ${_cfg.modelName}，建议点击下方升级为 deepseek-flash 或 deepseek-v4-pro。',
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: palette.ink,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: quickModels
                      .map(
                        (m) => _miniChip(
                          label: m,
                          selected: _cfg.modelName.trim() == m,
                          palette: palette,
                          ladder: ladder,
                          onTap: () {
                            _modelCtrl.text = m;
                            widget.onApply(
                              _cfg.copyWith(modelName: m),
                              immediate: true,
                            );
                          },
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 14),
                Text(
                  provider.hint,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.55,
                    color: palette.muted,
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FButton(
                        variant: FButtonVariant.outline,
                        size: FButtonSizeVariant.sm,
                        prefix: _testing
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(LucideIcons.wifi, size: 15),
                        onPress: _testing ? null : _test,
                        child: Text(_testing ? '测试中…' : '测试连接'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FButton(
                        variant: FButtonVariant.secondary,
                        size: FButtonSizeVariant.sm,
                        prefix: const Icon(LucideIcons.bookmarkPlus, size: 15),
                        onPress: _saveAsProfile,
                        child: const Text('另存为档案'),
                      ),
                    ),
                  ],
                ),
                if (_testResult.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  SelectableText(
                    _testResult,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.55,
                      color: palette.ink,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // 3. 深度思考与推理方言控制
        FCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '开启深度思考（Thinking）',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: palette.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            '自动适配百炼 Qwen4、DeepSeek V4（thinking.type）与推理中转，正文流出后胶囊自动收起。',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.45,
                              color: palette.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    FSwitch(
                      value: _cfg.enableThinking,
                      onChange: (v) => widget.onApply(
                        _cfg.copyWith(enableThinking: v),
                        immediate: true,
                      ),
                    ),
                  ],
                ),
                if (_cfg.enableThinking) ...<Widget>[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: FDivider(),
                  ),
                  Text(
                    _cfg.apiProvider == 'deepseek'
                        ? '推理力度（reasoning_effort）'
                        : '思考预算（tokens）',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: palette.muted,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_cfg.apiProvider == 'deepseek')
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: const <List<String>>[
                        <String>['low', '轻度 low'],
                        <String>['high', '高强度 high'],
                        <String>['max', '极限 max'],
                      ]
                          .map(
                            (opt) => _miniChip(
                              label: opt[1],
                              selected: _cfg.reasoningEffort == opt[0],
                              palette: palette,
                              ladder: ladder,
                              onTap: () => widget.onApply(
                                _cfg.copyWith(reasoningEffort: opt[0]),
                                immediate: true,
                              ),
                            ),
                          )
                          .toList(),
                    )
                  else
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: const <List<String>>[
                        <String>['0', '自由不限'],
                        <String>['1024', '1k'],
                        <String>['2048', '2k'],
                        <String>['4096', '4k'],
                        <String>['8192', '8k'],
                      ]
                          .map(
                            (opt) => _miniChip(
                              label: opt[1],
                              selected: '${_cfg.thinkingBudget}' == opt[0],
                              palette: palette,
                              ladder: ladder,
                              onTap: () => widget.onApply(
                                _cfg.copyWith(
                                  thinkingBudget: int.tryParse(opt[0]) ?? 0,
                                ),
                                immediate: true,
                              ),
                            ),
                          )
                          .toList(),
                    ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // 4. 跨厂商主辅双模型分工（后台档案官 + 编年史快模型）
        FCard(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: FAccordion(
              children: <FAccordionItemMixin>[
                FAccordionItem(
                  title: const Text('主辅双模型分工（后台档案官 · 可选）'),
                  initiallyExpanded: _cfg.enableAuxModel,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '开启后，后台世界状态抽取与编年史压缩将路由至独立便宜快模型（如 qwen3.8-flash / deepseek-flash），不开启则自动复用主模型并强制禁思考。',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: palette.muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FSwitch(
                            value: _cfg.enableAuxModel,
                            onChange: (v) {
                              var nextAuxModel = _cfg.auxModelName;
                              if (v && nextAuxModel.trim().isEmpty) {
                                final auxProvId = _cfg.auxApiProvider.isEmpty
                                    ? _cfg.apiProvider
                                    : _cfg.auxApiProvider;
                                final rec =
                                    Providers.byId(auxProvId).recommendedAuxModel;
                                if (rec.isNotEmpty) {
                                  nextAuxModel = rec;
                                  _auxModelCtrl.text = rec;
                                }
                              }
                              widget.onApply(
                                _cfg.copyWith(
                                  enableAuxModel: v,
                                  auxModelName: nextAuxModel,
                                ),
                                immediate: true,
                              );
                            },
                          ),
                        ],
                      ),
                      if (_cfg.enableAuxModel) ...<Widget>[
                        const SizedBox(height: 12),
                        Text(
                          '辅助模型服务商（支持跨厂商）',
                          style: TextStyle(fontSize: 12, color: palette.muted),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: <Widget>[
                            for (final opt in Providers.options)
                              Expanded(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    right:
                                        opt == Providers.options.last ? 0 : 6,
                                  ),
                                  child: _segPill(
                                    label: opt.shortLabel,
                                    selected: (_cfg.auxApiProvider.isEmpty
                                            ? _cfg.apiProvider
                                            : _cfg.auxApiProvider) ==
                                        opt.id,
                                    palette: palette,
                                    ladder: ladder,
                                    onTap: () {
                                      final rec = opt.recommendedAuxModel;
                                      if (rec.isNotEmpty) {
                                        _auxModelCtrl.text = rec;
                                      }
                                      widget.onApply(
                                        _cfg.copyWith(
                                          auxApiProvider: opt.id,
                                          auxModelName: rec.isNotEmpty
                                              ? rec
                                              : _cfg.auxModelName,
                                        ),
                                        immediate: true,
                                      );
                                    },
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: <Widget>[
                            Expanded(
                              child: FTextField(
                                control: FTextFieldControl.managed(
                                  controller: _auxModelCtrl,
                                  onChange: (v) => widget.onApply(
                                    _cfg.copyWith(auxModelName: v.text.trim()),
                                  ),
                                ),
                                label: const Text('辅助模型代码'),
                                hint: '例如 qwen3.8-flash / deepseek-flash',
                              ),
                            ),
                            const SizedBox(width: 8),
                            FButton(
                              variant: FButtonVariant.outline,
                              size: FButtonSizeVariant.md,
                              mainAxisSize: MainAxisSize.min,
                              onPress: () => _pickRemoteModel(forAux: true),
                              child: const Text('拉取'),
                            ),
                          ],
                        ),
                        if ((_cfg.auxApiProvider.isEmpty
                                ? _cfg.apiProvider
                                : _cfg.auxApiProvider) ==
                            'custom') ...<Widget>[
                          const SizedBox(height: 12),
                          FTextField(
                            control: FTextFieldControl.managed(
                              controller: _auxBaseUrlCtrl,
                              onChange: (v) => widget.onApply(
                                _cfg.copyWith(auxBaseUrl: v.text.trim()),
                              ),
                            ),
                            label: const Text('辅助接口 Base URL（留空复用主端点）'),
                            hint: 'https://api.example.com/v1',
                          ),
                        ],
                        const SizedBox(height: 12),
                        FTextField(
                          control: FTextFieldControl.managed(
                            controller: _auxKeyCtrl,
                            onChange: (v) =>
                                SecureStore.writeAuxKey(v.text.trim()),
                          ),
                          label: const Text('辅助模型专属 Key（留空自动用对应服务商槽位 Key）'),
                          hint: '跨厂商且未配置过对应服务商时可在此单独填',
                          obscureText: _obscureAux,
                          suffixBuilder: (_, _, _) => IconButton(
                            icon: Icon(
                              _obscureAux
                                  ? LucideIcons.eyeOff
                                  : LucideIcons.eye,
                              size: 16,
                              color: palette.muted,
                            ),
                            onPressed: () =>
                                setState(() => _obscureAux = !_obscureAux),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _segPill({
    required String label,
    required bool selected,
    required ReadingPalette palette,
    required dynamic ladder,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? palette.accent.withValues(alpha: 0.16) : ladder.containerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? palette.accent : ladder.hairlineStrong,
            width: selected ? 1.2 : 0.8,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? palette.accent : palette.ink,
          ),
        ),
      ),
    );
  }

  Widget _miniChip({
    required String label,
    required bool selected,
    required ReadingPalette palette,
    required dynamic ladder,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? palette.accent.withValues(alpha: 0.16) : ladder.containerLow,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected ? palette.accent : ladder.hairlineStrong,
            width: selected ? 1.2 : 0.8,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? palette.accent : palette.ink,
          ),
        ),
      ),
    );
  }
}
