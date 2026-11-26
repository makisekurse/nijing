import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../../services/providers.dart';
import '../../state/config_provider.dart';
import '../themes/app_theme.dart';
import 'settings_screen.dart';

/// 「我的」标签页（基于 `forui` `FTileGroup` 苹果/Linear 风格分组卡片）。
class ProfileTab extends StatelessWidget {
  final ValueChanged<SettingsSection> onOpenSection;
  final VoidCallback onOpenAbout;
  final VoidCallback onDataManage;
  final String versionLabel;
  final String worldCountLabel;
  final String slotCountLabel;

  const ProfileTab({
    super.key,
    required this.onOpenSection,
    required this.onOpenAbout,
    required this.onDataManage,
    required this.versionLabel,
    required this.worldCountLabel,
    required this.slotCountLabel,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final config = context.watch<ConfigProvider>().config;
    final providerMeta = Providers.byId(config.apiProvider);
    final activeModel = Providers.resolveModelName(config);
    final themeLabel = AppTheme.presets
        .firstWhere(
          (p) => p.id == config.themeMode,
          orElse: () => AppTheme.presets.first,
        )
        .label;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
      children: <Widget>[
        Text(
          '我的',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: palette.ink,
            fontFamilyFallback: AppTheme.serifFontFallback,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '算力接入、双模型分工、纸墨排版与本地数据',
          style: TextStyle(fontSize: 13, color: palette.muted),
        ),
        const SizedBox(height: 18),
        FTileGroup(
          label: const Text('引擎与模型'),
          children: <FTileMixin>[
            FTile(
              prefix: Icon(LucideIcons.cpu, size: 18, color: palette.accent),
              title: const Text('模型与接口'),
              subtitle: Text(
                '${providerMeta.shortLabel} · $activeModel'
                '${config.enableAuxModel && config.auxModelName.trim().isNotEmpty ? '（辅：${config.auxModelName.trim()}）' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              suffix: Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: palette.muted,
              ),
              onPress: () {
                HapticFeedback.selectionClick();
                onOpenSection(SettingsSection.model);
              },
            ),
            FTile(
              prefix:
                  Icon(LucideIcons.slidersHorizontal, size: 18, color: palette.accent),
              title: const Text('推演参数'),
              subtitle: Text(
                '目标 ${config.maxWords} 字 · 温度 ${config.temperature.toStringAsFixed(2)}'
                '${config.enableBackgroundExtract ? ' · 后台异步解耦' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              suffix: Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: palette.muted,
              ),
              onPress: () {
                HapticFeedback.selectionClick();
                onOpenSection(SettingsSection.advanced);
              },
            ),
          ],
        ),
        const SizedBox(height: 18),
        FTileGroup(
          label: const Text('阅读与外观'),
          children: <FTileMixin>[
            FTile(
              prefix:
                  Icon(LucideIcons.palette, size: 18, color: palette.accent),
              title: const Text('阅读与排版'),
              subtitle: Text(
                '$themeLabel主题 · ${config.serifReading ? '书卷衬线' : '默认无衬线'} · 行距 ${config.lineHeight.toStringAsFixed(1)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              suffix: Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: palette.muted,
              ),
              onPress: () {
                HapticFeedback.selectionClick();
                onOpenSection(SettingsSection.reading);
              },
            ),
          ],
        ),
        const SizedBox(height: 18),
        FTileGroup(
          label: const Text('数据与排障'),
          children: <FTileMixin>[
            FTile(
              prefix:
                  Icon(LucideIcons.database, size: 18, color: palette.accent),
              title: const Text('本机数据管理'),
              subtitle: Text('$worldCountLabel · $slotCountLabel'),
              suffix: Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: palette.muted,
              ),
              onPress: () {
                HapticFeedback.selectionClick();
                onDataManage();
              },
            ),
            FTile(
              prefix:
                  Icon(LucideIcons.terminal, size: 18, color: palette.accent),
              title: const Text('调试与运行日志'),
              subtitle: Text(config.logEnabled ? '运行日志已开启' : '默认关闭，零性能开销'),
              suffix: Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: palette.muted,
              ),
              onPress: () {
                HapticFeedback.selectionClick();
                onOpenSection(SettingsSection.debug);
              },
            ),
            FTile(
              prefix: Icon(LucideIcons.info, size: 18, color: palette.accent),
              title: const Text('关于拟境'),
              subtitle: Text('版本 $versionLabel'),
              suffix: Icon(
                LucideIcons.chevronRight,
                size: 16,
                color: palette.muted,
              ),
              onPress: () {
                HapticFeedback.selectionClick();
                onOpenAbout();
              },
            ),
          ],
        ),
      ],
    );
  }
}
