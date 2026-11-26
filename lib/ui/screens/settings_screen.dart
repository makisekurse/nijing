import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../data/prefs_store.dart';
import '../../models/app_config.dart';
import '../../services/file_export_service.dart';
import '../../services/runtime_log.dart';
import '../../services/text_layout.dart';
import '../../state/config_provider.dart';
import '../themes/app_theme.dart';
import '../widgets/settings_model_section.dart';

enum SettingsSection { model, advanced, reading, debug, all }

/// 设置页（v2.0 瘦身重构：`forui` 触控骨架 + `ConfigProvider` 响应式状态）。
class SettingsScreen extends StatefulWidget {
  final AppConfig? config;
  final ValueChanged<AppConfig>? onConfigChanged;
  final SettingsSection section;

  const SettingsScreen({
    super.key,
    this.config,
    this.onConfigChanged,
    this.section = SettingsSection.all,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppConfig _localConfig;

  @override
  void initState() {
    super.initState();
    _localConfig = widget.config ?? AppConfig();
  }

  ConfigProvider? _maybeProvider() {
    try {
      return Provider.of<ConfigProvider>(context, listen: false);
    } catch (_) {
      return null;
    }
  }

  AppConfig _readConfig(BuildContext context) {
    final p = _maybeProvider();
    if (p != null) {
      return context.watch<ConfigProvider>().config;
    }
    return _localConfig;
  }

  void _apply(AppConfig next, {bool immediate = false}) {
    setState(() => _localConfig = next);
    final p = _maybeProvider();
    if (p != null) {
      p.updateConfig(next, immediate: immediate);
    } else {
      widget.onConfigChanged?.call(next);
      final raw = next.encode();
      if (immediate) {
        PrefsStore.setString('nijing_config_v1', raw);
      } else {
        PrefsStore.setStringDebounced('nijing_config_v1', raw);
      }
    }
  }

  bool _shows(SettingsSection s) =>
      widget.section == SettingsSection.all || widget.section == s;

  String get _title {
    switch (widget.section) {
      case SettingsSection.model:
        return '模型与接口';
      case SettingsSection.advanced:
        return '推演参数';
      case SettingsSection.reading:
        return '阅读与排版';
      case SettingsSection.debug:
        return '调试与日志';
      case SettingsSection.all:
        return '设置';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = _readConfig(context);
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: Text(_title),
        prefixes: <Widget>[
          FHeaderAction.back(onPress: () => Navigator.of(context).maybePop()),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 48),
        children: <Widget>[
          if (_shows(SettingsSection.model)) ...<Widget>[
            SettingsModelSection(
              config: cfg,
              configProvider: _maybeProvider(),
              onApply: _apply,
            ),
            if (widget.section == SettingsSection.all)
              const SizedBox(height: 22),
          ],
          if (_shows(SettingsSection.advanced)) ...<Widget>[
            _buildAdvancedSection(cfg, palette),
            if (widget.section == SettingsSection.all)
              const SizedBox(height: 22),
          ],
          if (_shows(SettingsSection.reading)) ...<Widget>[
            _buildReadingSection(cfg, palette, ladder),
            if (widget.section == SettingsSection.all)
              const SizedBox(height: 22),
          ],
          if (_shows(SettingsSection.debug)) _buildDebugSection(cfg, palette),
        ],
      ),
    );
  }

  // ---------- 推演参数 ----------

  Widget _buildAdvancedSection(AppConfig cfg, ReadingPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FTileGroup(
          label: const Text('推演行为'),
          children: <FTileMixin>[
            FTile(
              prefix:
                  Icon(LucideIcons.sparkles, size: 17, color: palette.accent),
              title: const Text('主宰模式（最高权限）'),
              subtitle: const Text('玩家意志即不可撼动的既成事实，AI 绝对顺从展开'),
              suffix: FSwitch(
                value: cfg.godMode,
                onChange: (v) => _apply(cfg.copyWith(godMode: v), immediate: true),
              ),
            ),
            FTile(
              prefix:
                  Icon(LucideIcons.layers, size: 17, color: palette.accent),
              title: const Text('后台异步解耦档案官'),
              subtitle: const Text('主模型专心写小说正文，状态/人物/词条在后台零阻塞提取'),
              suffix: FSwitch(
                value: cfg.enableBackgroundExtract,
                onChange: (v) => _apply(
                  cfg.copyWith(enableBackgroundExtract: v),
                  immediate: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        FCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _sliderBlock(
                  palette: palette,
                  label: '发散程度（temperature）',
                  display: cfg.temperature.toStringAsFixed(2),
                  value: cfg.temperature,
                  min: 0.1,
                  max: 1.4,
                  onChanged: (v) => _apply(cfg.copyWith(temperature: v)),
                ),
                const SizedBox(height: 8),
                _sliderBlock(
                  palette: palette,
                  label: '单幕目标字数',
                  display: '${cfg.maxWords} 字',
                  value: cfg.maxWords.toDouble().clamp(200, 3000),
                  min: 200,
                  max: 3000,
                  divisions: 56,
                  onChanged: (v) => _apply(cfg.copyWith(maxWords: v.round())),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------- 阅读与排版 ----------

  Widget _buildReadingSection(
    AppConfig cfg,
    ReadingPalette palette,
    dynamic ladder,
  ) {
    final activePreset = AppTheme.presets.firstWhere(
      (p) => p.id == cfg.themeMode,
      orElse: () => AppTheme.presets.first,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      '纸墨主题',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: palette.ink,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      activePreset.desc,
                      style: TextStyle(fontSize: 12, color: palette.muted),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    for (final preset in AppTheme.presets)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: preset == AppTheme.presets.last ? 0 : 8,
                          ),
                          child: _themeCard(cfg, preset, palette, ladder),
                        ),
                      ),
                  ],
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 14),
                  child: FDivider(),
                ),
                _optionRow(
                  label: '字号',
                  options: const <List<String>>[
                    <String>['sm', '小'],
                    <String>['md', '中'],
                    <String>['lg', '大'],
                  ],
                  selected: cfg.fontSize,
                  palette: palette,
                  ladder: ladder,
                  onPick: (v) =>
                      _apply(cfg.copyWith(fontSize: v), immediate: true),
                ),
                const SizedBox(height: 10),
                _sliderBlock(
                  palette: palette,
                  label: '行距',
                  display: cfg.lineHeight.toStringAsFixed(1),
                  value: cfg.lineHeight,
                  min: 1.4,
                  max: 2.6,
                  divisions: 12,
                  onChanged: (v) => _apply(cfg.copyWith(lineHeight: v)),
                ),
                const SizedBox(height: 6),
                _optionRow(
                  label: '首行缩进',
                  options: TextLayout.indentOptions,
                  selected: '${cfg.paragraphIndent}',
                  palette: palette,
                  ladder: ladder,
                  onPick: (v) => _apply(
                    cfg.copyWith(paragraphIndent: int.tryParse(v) ?? 0),
                    immediate: true,
                  ),
                ),
                const SizedBox(height: 10),
                _optionRow(
                  label: '段间距',
                  options: TextLayout.spacingOptions,
                  selected: cfg.paragraphSpacing,
                  palette: palette,
                  ladder: ladder,
                  onPick: (v) =>
                      _apply(cfg.copyWith(paragraphSpacing: v), immediate: true),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        FTileGroup(
          label: const Text('阅读体验细节'),
          children: <FTileMixin>[
            FTile(
              prefix:
                  Icon(LucideIcons.bookType, size: 17, color: palette.accent),
              title: const Text('书卷衬线阅读'),
              subtitle: const Text('正文切换为典雅宋体风格，支持电报引用与加粗/斜体排版'),
              suffix: FSwitch(
                value: cfg.serifReading,
                onChange: (v) =>
                    _apply(cfg.copyWith(serifReading: v), immediate: true),
              ),
            ),
            FTile(
              prefix: Icon(
                LucideIcons.arrowDownToLine,
                size: 17,
                color: palette.accent,
              ),
              title: const Text('打开时跳至最新一幕'),
              suffix: FSwitch(
                value: cfg.autoScrollToLatest,
                onChange: (v) => _apply(
                  cfg.copyWith(autoScrollToLatest: v),
                  immediate: true,
                ),
              ),
            ),
            FTile(
              prefix: Icon(LucideIcons.sun, size: 17, color: palette.accent),
              title: const Text('阅读防熄屏'),
              suffix: FSwitch(
                value: cfg.keepScreenOn,
                onChange: (v) =>
                    _apply(cfg.copyWith(keepScreenOn: v), immediate: true),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------- 调试与日志 ----------

  Widget _buildDebugSection(AppConfig cfg, ReadingPalette palette) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        FTileGroup(
          label: const Text('诊断日志'),
          children: <FTileMixin>[
            FTile(
              prefix:
                  Icon(LucideIcons.terminal, size: 17, color: palette.accent),
              title: const Text('记录运行日志'),
              subtitle: const Text('内存环形缓冲，所有加密 API Key 自动精准脱敏'),
              suffix: FSwitch(
                value: cfg.logEnabled,
                onChange: (v) => _apply(
                  cfg.copyWith(
                    logEnabled: v,
                    verboseLog: v ? cfg.verboseLog : false,
                  ),
                  immediate: true,
                ),
              ),
            ),
            FTile(
              prefix:
                  Icon(LucideIcons.fileCode, size: 17, color: palette.accent),
              title: const Text('详细日志（含 SSE 原始帧）'),
              suffix: FSwitch(
                value: cfg.verboseLog,
                onChange: (v) => _apply(
                  cfg.copyWith(verboseLog: v, logEnabled: v || cfg.logEnabled),
                  immediate: true,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ValueListenableBuilder<int>(
          valueListenable: RuntimeLog.revision,
          builder: (context, _, _) => FCard(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    RuntimeLog.enabled
                        ? '当前已记录 ${RuntimeLog.count} 条${RuntimeLog.verbose ? '（详细模式）' : ''}'
                        : '日志未开启',
                    style: TextStyle(fontSize: 12.5, color: palette.muted),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: FButton(
                          variant: FButtonVariant.outline,
                          size: FButtonSizeVariant.sm,
                          prefix: const Icon(LucideIcons.download, size: 15),
                          onPress: RuntimeLog.enabled && RuntimeLog.count > 0
                              ? _exportLog
                              : null,
                          child: const Text('导出日志'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      FButton(
                        variant: FButtonVariant.ghost,
                        size: FButtonSizeVariant.sm,
                        mainAxisSize: MainAxisSize.min,
                        prefix: const Icon(LucideIcons.trash2, size: 15),
                        onPress: RuntimeLog.count > 0 ? _clearLog : null,
                        child: const Text('清空'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

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
        await FileExportService.shareText(title: '拟境 · 运行日志', text: text);
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.success
              ? '运行日志已保存至：${res.path}'
              : '导出失败：${res.message}',
        ),
      ),
    );
  }

  Future<void> _clearLog() async {
    RuntimeLog.clear();
    if (mounted) setState(() {});
  }

  Widget _themeCard(
    AppConfig cfg,
    ThemePreset preset,
    ReadingPalette palette,
    dynamic ladder,
  ) {
    final selected = cfg.themeMode == preset.id;
    final swatch = AppTheme.paletteOfId(preset.id);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        HapticFeedback.selectionClick();
        _apply(cfg.copyWith(themeMode: preset.id), immediate: true);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 6),
        decoration: BoxDecoration(
          color: swatch.page,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? palette.accent : ladder.hairlineStrong,
            width: selected ? 1.8 : 0.8,
          ),
        ),
        child: Column(
          children: <Widget>[
            Container(
              width: 18,
              height: 4,
              decoration: BoxDecoration(
                color: swatch.accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              preset.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: swatch.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionRow({
    required String label,
    required List<List<String>> options,
    required String selected,
    required ReadingPalette palette,
    required dynamic ladder,
    required ValueChanged<String> onPick,
  }) {
    return Row(
      children: <Widget>[
        Text(label, style: TextStyle(fontSize: 13.5, color: palette.ink)),
        const Spacer(),
        for (final opt in options)
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: () {
                HapticFeedback.selectionClick();
                onPick(opt[0]);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: selected == opt[0]
                      ? palette.accent.withValues(alpha: 0.16)
                      : ladder.containerLow,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: selected == opt[0]
                        ? palette.accent
                        : ladder.hairlineStrong,
                    width: selected == opt[0] ? 1.2 : 0.8,
                  ),
                ),
                child: Text(
                  opt[1],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        selected == opt[0] ? FontWeight.w600 : FontWeight.normal,
                    color: selected == opt[0] ? palette.accent : palette.ink,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _sliderBlock({
    required ReadingPalette palette,
    required String label,
    required String display,
    required double value,
    required double min,
    required double max,
    int? divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(label, style: TextStyle(fontSize: 13.5, color: palette.ink)),
            const Spacer(),
            Text(
              display,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: palette.accent,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: palette.accent,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
