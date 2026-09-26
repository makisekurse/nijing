import 'package:flutter/material.dart';

import '../../data/prefs_store.dart';
import '../../data/secure_store.dart';
import '../../models/app_config.dart';
import '../../services/file_export_service.dart';
import '../../services/llm_client.dart';
import '../../services/providers.dart';
import '../../services/runtime_log.dart';
import '../../services/text_layout.dart';
import '../themes/app_theme.dart';

/// 设置分区。
///
/// 2026-09-25 改：以前「我的」页面有三个入口（模型设置 / 阅读设置 / 推演参数），
/// 但点进去**都是同一个长页面**，三块内容全混在一起 —— 用户反馈
/// 「虽然分为三个模块，但点进去内容混杂在一起并未分开」。
///
/// 现在每个入口只渲染自己那一段，标题也跟着变。
/// [all] 是给阅读页菜单里的「设置」用的（那里需要一页看全）。
enum SettingsSection { model, advanced, reading, debug, all }

/// 设置页。
///
/// 注意：这里**没有「剧本进度管理」** —— 那部分已由「世界书」取代，
/// 世界书的增删改在首页的「世界」标签页里。
class SettingsScreen extends StatefulWidget {
  final AppConfig config;
  final ValueChanged<AppConfig> onConfigChanged;

  /// 只显示哪一个分区。默认全部（阅读页菜单用）。
  final SettingsSection section;

  const SettingsScreen({
    super.key,
    required this.config,
    required this.onConfigChanged,
    this.section = SettingsSection.all,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppConfig _config;

  late TextEditingController _keyCtrl;
  late TextEditingController _wsCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _baseUrlCtrl;

  bool _obscure = true;
  bool _testing = false;
  String _testResult = '';

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _keyCtrl = TextEditingController();
    _wsCtrl = TextEditingController();
    _modelCtrl = TextEditingController(text: _config.modelName);
    _baseUrlCtrl = TextEditingController(text: _config.baseUrl);
    _loadKey();
    _loadWorkspaceId();
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _wsCtrl.dispose();
    _modelCtrl.dispose();
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadKey() async {
    final k = await SecureStore.readApiKey();
    if (!mounted) return;
    setState(() => _keyCtrl.text = k);
  }

  Future<void> _loadWorkspaceId() async {
    final ws = await PrefsStore.getString(_kWorkspace) ?? '';
    if (!mounted) return;
    setState(() => _wsCtrl.text = ws);
  }

  static const String _kWorkspace = 'nijing_workspace_id';

  /// 当前所选主题的一句话说明。
  String _themeDesc() {
    for (final p in AppTheme.presets) {
      if (p.id == _config.themeMode) return p.desc;
    }
    return '';
  }

  /// 写入配置。
  ///
  /// [immediate] 用于**离散选择**（主题、字号、开关、选模型）——
  /// 这类操作点一下就定了，必须立刻落盘。
  ///
  /// ⚠️ 2026-09-25 修：以前一律走 700ms 防抖，用户改完主题马上退出应用，
  /// 改动就丢了 —— 表现为「设置没生效」。输入框与滑杆继续用防抖。
  void _apply(
    AppConfig next, {
    bool persistKey = false,
    bool immediate = false,
  }) {
    setState(() => _config = next);
    widget.onConfigChanged(next);

    final raw = next.encode();
    if (immediate) {
      PrefsStore.setString('nijing_config_v1', raw);
    } else {
      PrefsStore.setStringDebounced('nijing_config_v1', raw);
    }

    if (persistKey) {
      SecureStore.writeApiKey(_keyCtrl.text.trim());
    }
    PrefsStore.setStringDebounced(_kWorkspace, _wsCtrl.text.trim());
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = '';
    });
    final err = await LlmClient().testConnection(
      config: _config,
      apiKey: _keyCtrl.text.trim(),
      workspaceId: _wsCtrl.text.trim(),
    );
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = err == null ? '✅ 连接成功，模型可用。' : '❌ $err';
    });
  }

  bool _shows(SettingsSection s) =>
      widget.section == SettingsSection.all || widget.section == s;

  String get _title {
    switch (widget.section) {
      case SettingsSection.model:
        return '模型设置';
      case SettingsSection.advanced:
        return '推演参数';
      case SettingsSection.reading:
        return '阅读设置';
      case SettingsSection.debug:
        return '调试与日志';
      case SettingsSection.all:
        return '设置';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: <Widget>[
          if (_shows(SettingsSection.model)) ..._modelSection(theme),
          if (_shows(SettingsSection.advanced)) ..._advancedSection(theme),
          if (_shows(SettingsSection.reading)) ..._readingSection(theme),
          if (_shows(SettingsSection.debug)) ..._debugSection(theme),
        ],
      ),
    );
  }

  // ---------- 分区四：调试与日志 ----------

  List<Widget> _debugSection(ThemeData theme) => <Widget>[
        _section(theme, '调试与日志'),
        const SizedBox(height: 12),
        _switchRow(
          theme,
          '记录运行日志',
          '把请求参数、流式分块、解析判定与错误详情记到内存，供排查生成异常。'
              '不记录 API Key。默认关闭。',
          _config.logEnabled,
          (v) => _apply(
            _config.copyWith(
              logEnabled: v,
              // 关掉总开关时顺带关掉详细模式，避免留下一个无效的「开」
              verboseLog: v ? _config.verboseLog : false,
            ),
            immediate: true,
          ),
        ),
        _switchRow(
          theme,
          '详细日志（含模型原文）',
          '额外记录每一条 SSE 原始行与模型输出片段。数据量大，只在复现疑难问题时开。',
          _config.verboseLog,
          (v) => _apply(
            _config.copyWith(verboseLog: v, logEnabled: v || _config.logEnabled),
            immediate: true,
          ),
        ),
        const SizedBox(height: 12),
        ValueListenableBuilder<int>(
          valueListenable: RuntimeLog.revision,
          builder: (context, _, child) => Text(
            RuntimeLog.enabled
                ? '当前已记录 ${RuntimeLog.count} 条'
                    '${RuntimeLog.verbose ? '（详细模式）' : ''}'
                : '日志未开启',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: RuntimeLog.enabled && RuntimeLog.count > 0
                    ? _exportLog
                    : null,
                icon: const Icon(Icons.save_alt_rounded, size: 18),
                label: const Text('导出日志'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  side: BorderSide(color: theme.dividerColor),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: RuntimeLog.count > 0 ? _clearLog : null,
              icon: const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('清空'),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 12),
                side: BorderSide(color: theme.dividerColor),
              ),
            ),
          ],
        ),
      ];

  Future<void> _exportLog() async {
    final text = RuntimeLog.dump();
    final ts = FileExportService.formatTimestamp();
    final res = await FileExportService.exportFile(
      fileName: '拟境_运行日志_$ts.txt',
      content: text,
      mimeType: 'text/plain',
    );
    if (!mounted) return;
    if (res.success && res.path != null) {
      final ok = await FileExportService.shareFile(
        filePath: res.path!,
        title: '拟境 · 运行日志',
        mimeType: 'text/plain',
      );
      if (!ok) {
        await FileExportService.shareText(
          title: '拟境 · 运行日志',
          text: text,
        );
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(
          res.success
              ? '运行日志（${RuntimeLog.count} 条）已保存至：${res.path}'
              : '导出失败：${res.message}',
        ),
        action: SnackBarAction(
          label: '系统分享',
          onPressed: () async {
            if (res.success && res.path != null) {
              final ok = await FileExportService.shareFile(
                filePath: res.path!,
                title: '拟境 · 运行日志',
                mimeType: 'text/plain',
              );
              if (!ok) {
                await FileExportService.shareText(
                  title: '拟境 · 运行日志',
                  text: text,
                );
              }
            } else {
              await FileExportService.shareText(
                title: '拟境 · 运行日志',
                text: text,
              );
            }
          },
        ),
      ),
    );
  }

  Future<void> _clearLog() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(
          '清空当前 ${RuntimeLog.count} 条运行日志？',
          style: const TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    RuntimeLog.clear();
    if (!mounted) return;
    setState(() {});
  }

  // ---------- 分区一：模型 ----------

  List<Widget> _modelSection(ThemeData theme) {
    final provider = Providers.byId(_config.apiProvider);
    return <Widget>[
      _section(theme, 'AI 算力与模型接口'),
      const SizedBox(height: 12),

      DropdownButtonFormField<String>(
        initialValue: _config.apiProvider,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '服务提供商'),
        items: Providers.options
            .map(
              (p) => DropdownMenuItem<String>(
                value: p.id,
                child: Text(p.label, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: (v) {
          if (v == null) return;
          final p = Providers.byId(v);
          _modelCtrl.text = p.defaultModel;
          _baseUrlCtrl.text = '';
          _apply(
            _config.copyWith(
              apiProvider: v,
              modelName: p.defaultModel,
              baseUrl: '',
            ),
            immediate: true,
          );
        },
      ),
      const SizedBox(height: 14),

      TextField(
        controller: _keyCtrl,
        obscureText: _obscure,
        decoration: InputDecoration(
          labelText: 'API Key',
          hintText: 'sk-xxxx',
          suffixIcon: IconButton(
            icon: Icon(
              _obscure ? Icons.visibility_off : Icons.visibility,
              size: 20,
            ),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        onChanged: (_) => _apply(_config, persistKey: true),
      ),
      const SizedBox(height: 6),
      Text(
        SecureStore.isDegraded
            ? '⚠️ 当前设备不支持加密存储，Key 仅保存在本次运行的内存中。'
            : 'Key 以密文保存在本机，不会上传到任何服务器。',
        style: TextStyle(
          fontSize: 11.5,
          height: 1.6,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        ),
      ),
      const SizedBox(height: 14),

      if (_config.apiProvider == 'bailian') ...<Widget>[
        TextField(
          controller: _wsCtrl,
          decoration: const InputDecoration(
            labelText: '业务空间 ID（选填）',
            hintText: '华北2（北京）填了会改用专属域名，更稳定',
          ),
          onChanged: (_) => _apply(_config),
        ),
        const SizedBox(height: 14),
      ],

      TextField(
        controller: _modelCtrl,
        decoration: const InputDecoration(
          labelText: '模型代码',
          hintText: '例如 qwen3.8-flash',
        ),
        onChanged: (v) => _apply(_config.copyWith(modelName: v)),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: (_config.apiProvider == 'deepseek'
                ? Providers.deepseekModels
                : Providers.bailianModels)
            .map(
              (m) => ActionChip(
                label: Text(m, style: const TextStyle(fontSize: 12)),
                onPressed: () {
                  _modelCtrl.text = m;
                  _apply(_config.copyWith(modelName: m), immediate: true);
                },
              ),
            )
            .toList(),
      ),
      const SizedBox(height: 14),

      _switchRow(
        theme,
        '开启深度思考（Thinking 模式）',
        '开启后模型将先深入权衡局势再落笔成文，思考过程自动收纳进「推演思考」抽屉，正文不受影响；支持 Qwen 系列（如 qwen3.8-flash）、百炼及各类推理模型。',
        _config.enableThinking,
        (v) => _apply(_config.copyWith(enableThinking: v), immediate: true),
      ),
      const SizedBox(height: 14),

      if (_config.apiProvider == 'custom') ...<Widget>[
        TextField(
          controller: _baseUrlCtrl,
          decoration: const InputDecoration(
            labelText: 'Base URL',
            hintText: 'https://api.example.com/v1',
          ),
          onChanged: (v) => _apply(_config.copyWith(baseUrl: v)),
        ),
        const SizedBox(height: 14),
      ],

      OutlinedButton.icon(
        onPressed: _testing ? null : _test,
        icon: _testing
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.wifi_tethering_rounded, size: 18),
        label: Text(_testing ? '测试中…' : '测试连接'),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 12),
          side: BorderSide(color: theme.dividerColor),
        ),
      ),
      if (_testResult.isNotEmpty) ...<Widget>[
        const SizedBox(height: 10),
        SelectableText(
          _testResult,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.6,
            color: theme.colorScheme.onSurface,
          ),
        ),
      ],
      const SizedBox(height: 6),
      Text(
        provider.hint,
        style: TextStyle(
          fontSize: 11.5,
          height: 1.6,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
        ),
      ),
    ];
  }

  // ---------- 分区二：推演参数 ----------

  List<Widget> _advancedSection(ThemeData theme) => <Widget>[
        _section(theme, '推演参数'),
        const SizedBox(height: 6),
        _switchRow(
          theme,
          '主宰模式（绝对权限）',
          '开启后视玩家所有意志与推演走向为不可撼动的既定事实，AI 将绝对服从且全力配合展开',
          _config.godMode,
          (v) => _apply(_config.copyWith(godMode: v), immediate: true),
        ),
        const SizedBox(height: 10),
        _slider(
          theme,
          label: '发散程度（temperature）',
          value: _config.temperature,
          min: 0.1,
          max: 1.4,
          display: _config.temperature.toStringAsFixed(2),
          onChanged: (v) => _apply(_config.copyWith(temperature: v)),
        ),
        _slider(
          theme,
          label: '单幕目标字数',
          value: _config.maxWords.toDouble().clamp(200, 3000),
          min: 200,
          max: 3000,
          divisions: 56,
          display: '${_config.maxWords} 字',
          onChanged: (v) => _apply(_config.copyWith(maxWords: v.round())),
        ),
        const SizedBox(height: 4),
        Text(
          '这两个值会写进提示词。目标字数只影响模型的写作长度，'
          '实际输出会随剧情需要浮动。',
          style: TextStyle(
            fontSize: 11.5,
            height: 1.7,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
        ),
      ];

  // ---------- 分区三：阅读 ----------

  List<Widget> _readingSection(ThemeData theme) => <Widget>[
        _section(theme, '阅读体验'),
        const SizedBox(height: 12),

        // 四套皮肤用 Wrap 排 —— 用 Row+Expanded 的话每个只有 70dp 宽，
        // 「时代报章」这种四字标签会被挤到省略号。
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: AppTheme.presets
              .map(
                (p) => _chip(
                  theme,
                  label: p.label,
                  swatch: AppTheme.paletteOfId(p.id).page,
                  selected: _config.themeMode == p.id,
                  onTap: () => _apply(
                    _config.copyWith(themeMode: p.id),
                    immediate: true,
                  ),
                ),
              )
              .toList(),
        ),
        if (_themeDesc().isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            _themeDesc(),
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
        const SizedBox(height: 12),

        Row(
          children: <Widget>[
            Text(
              '字号',
              style: TextStyle(
                fontSize: 13.5,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const Spacer(),
            for (final opt in <List<String>>[
              <String>['sm', '小'],
              <String>['md', '中'],
              <String>['lg', '大'],
            ])
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _chip(
                  theme,
                  label: opt[1],
                  selected: _config.fontSize == opt[0],
                  onTap: () => _apply(
                    _config.copyWith(fontSize: opt[0]),
                    immediate: true,
                  ),
                  compact: true,
                ),
              ),
          ],
        ),
        _slider(
          theme,
          label: '行距',
          value: _config.lineHeight,
          min: 1.4,
          max: 2.6,
          display: _config.lineHeight.toStringAsFixed(1),
          onChanged: (v) => _apply(_config.copyWith(lineHeight: v)),
        ),

        // 文字排版：段首缩进格数 + 段间距。
        // 以前是一个「首行缩进 开/关」的布尔开关 —— 但真正要调的是"缩几格"，
        // 而且那个开关因为分段逻辑的 bug 根本没生效过。
        _chipRow(
          theme,
          label: '段首缩进',
          options: TextLayout.indentOptions,
          selected: '${_config.paragraphIndent}',
          onPick: (v) => _apply(
            _config.copyWith(paragraphIndent: int.tryParse(v) ?? 0),
            immediate: true,
          ),
        ),
        _chipRow(
          theme,
          label: '段间距',
          options: TextLayout.spacingOptions,
          selected: _config.paragraphSpacing,
          onPick: (v) => _apply(
            _config.copyWith(paragraphSpacing: v),
            immediate: true,
          ),
        ),
        const SizedBox(height: 8),
        _switchRow(
          theme,
          '打开时跳到最新一幕',
          '从首页「继续进入」直接落在最新进度，不用手动翻到底',
          _config.autoScrollToLatest,
          (v) =>
              _apply(_config.copyWith(autoScrollToLatest: v), immediate: true),
        ),
        _switchRow(
          theme,
          '顶栏自动隐藏',
          '单击屏幕唤出，3 秒后自动淡出',
          _config.autoHideHeader,
          (v) => _apply(_config.copyWith(autoHideHeader: v), immediate: true),
        ),
        _switchRow(
          theme,
          '阅读防熄屏',
          '沉浸推演阅读时保持屏幕常亮，退出或切后台释放',
          _config.keepScreenOn,
          (v) => _apply(_config.copyWith(keepScreenOn: v), immediate: true),
        ),
      ];

  // ---------- 组件 ----------

  Widget _section(ThemeData theme, String title) => Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
          color: theme.colorScheme.primary,
        ),
      );

  Widget _chip(
    ThemeData theme, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    bool compact = false,
    /// 可选预览色 —— 主题选择用它显示这套皮肤的实际观感
    Color? swatch,
  }) {
    final primary = theme.colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 14 : 8,
          vertical: compact ? 6 : 9,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? primary.withValues(alpha: 0.12) : theme.cardColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? primary : theme.dividerColor,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            if (swatch != null) ...<Widget>[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: swatch,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.25),
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? primary : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行「标签 + 若干互斥选项」。
  Widget _chipRow(
    ThemeData theme, {
    required String label,
    required List<List<String>> options,
    required String selected,
    required ValueChanged<String> onPick,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            Text(
              label,
              style: TextStyle(
                fontSize: 13.5,
                color: theme.colorScheme.onSurface,
              ),
            ),
            const Spacer(),
            for (final opt in options)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _chip(
                  theme,
                  label: opt[1],
                  selected: selected == opt[0],
                  onTap: () => onPick(opt[0]),
                  compact: true,
                ),
              ),
          ],
        ),
      );

  Widget _switchRow(
    ThemeData theme,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: value,
        onChanged: onChanged,
        title: Text(title, style: const TextStyle(fontSize: 14)),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11.5)),
        activeThumbColor: theme.colorScheme.primary,
      );

  Widget _slider(
    ThemeData theme, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                label,
                style: TextStyle(
                  fontSize: 13.5,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              Text(
                display,
                style: TextStyle(
                  fontSize: 12.5,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: theme.colorScheme.primary,
            onChanged: onChanged,
          ),
        ],
      );
}
