import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_info.dart';
import '../../services/update_service.dart';
import '../themes/app_theme.dart';

/// 关于页（`forui` 极简卡片风格）。
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  bool _checking = false;
  String _result = '';

  Future<void> _checkUpdate() async {
    setState(() {
      _checking = true;
      _result = '';
    });
    final info = await UpdateService.checkLatest();
    if (!mounted) return;
    if (info == null) {
      setState(() {
        _checking = false;
        _result = '检查失败：无法访问更新服务（可能是网络问题）。';
      });
      return;
    }
    final newer = UpdateService.isNewer(info.tag, AppInfo.version);
    setState(() {
      _checking = false;
      _result = newer
          ? '发现新版本 ${info.tag}'
              '${info.apkSizeLabel.isEmpty ? '' : '（${info.apkSizeLabel}）'}'
              '\n下载：${info.apkUrl.isEmpty ? info.pageUrl : info.apkUrl}'
          : '已是最新版本（远端 ${info.tag}）。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);

    return FScaffold(
      childPad: false,
      header: FHeader.nested(
        title: const Text('关于拟境'),
        prefixes: <Widget>[
          FHeaderAction.back(onPress: () => Navigator.of(context).maybePop()),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 40),
        children: <Widget>[
          Center(
            child: Column(
              children: <Widget>[
                Text(
                  AppInfo.appName,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                    color: palette.ink,
                    fontFamilyFallback: AppTheme.serifFontFallback,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  AppInfo.slogan,
                  style: TextStyle(fontSize: 13, color: palette.muted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          FTileGroup(
            children: <FTileMixin>[
              FTile(
                prefix: Icon(LucideIcons.user, size: 16, color: palette.accent),
                title: const Text('开发者'),
                details: Text(AppInfo.developer),
              ),
              FTile(
                prefix: Icon(LucideIcons.tag, size: 16, color: palette.accent),
                title: const Text('版本号'),
                details: Text(AppInfo.version),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FButton(
            variant: FButtonVariant.outline,
            prefix: _checking
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.refreshCw, size: 16),
            onPress: _checking ? null : _checkUpdate,
            child: Text(_checking ? '正在检查更新…' : '检查更新'),
          ),
          if (_result.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            FCard(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  _result,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.65,
                    color: palette.ink,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 22),
          Center(
            child: Text(
              '世界书、世界线存档与加密密钥均仅留在设备本地。',
              style: TextStyle(fontSize: 11.5, color: palette.muted),
            ),
          ),
        ],
      ),
    );
  }
}
