import 'package:flutter/material.dart';
import 'package:forui/forui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../../core/app_info.dart';
import '../themes/app_theme.dart';
import '../themes/surface_ladder.dart';

/// 首次启动引导页（`forui` 触控骨架 + Claude 文学纸墨留白美学）。
class OnboardingScreen extends StatelessWidget {
  final VoidCallback onConfigure;
  final VoidCallback onSkip;

  const OnboardingScreen({
    super.key,
    required this.onConfigure,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final palette = AppTheme.readingOf(context);
    final ladder = AppTheme.ladderOf(context);

    return FScaffold(
      childPad: false,
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(26, 28, 26, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (constraints.maxHeight - 52).clamp(0.0, double.infinity),
              ),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Spacer(),
                    FBadge(
                      variant: FBadgeVariant.outline,
                      child: Text(
                        AppInfo.appNameEn.toUpperCase(),
                        style: const TextStyle(letterSpacing: 2.2, fontSize: 11),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      AppInfo.appName,
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        color: palette.ink,
                        fontFamilyFallback: AppTheme.serifFontFallback,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      AppInfo.slogan,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.6,
                        color: palette.muted,
                      ),
                    ),
                    const SizedBox(height: 24),
                    FCard(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          children: <Widget>[
                            _featureRow(
                              palette,
                              ladder,
                              icon: LucideIcons.bookOpen,
                              title: '一本世界书',
                              body: '你演谁、身处什么时代、用什么文风，全由世界书决定。支持文件导入与内置示例一键体验。',
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: FDivider(),
                            ),
                            _featureRow(
                              palette,
                              ladder,
                              icon: LucideIcons.sparkles,
                              title: '自由接入前沿模型',
                              body: '直连百炼 Qwen4、DeepSeek V4 或任意 OpenAI 兼容接口；支持主辅双模型分工，分槽加密互不串 Key。',
                            ),
                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: FDivider(),
                            ),
                            _featureRow(
                              palette,
                              ladder,
                              icon: LucideIcons.shieldCheck,
                              title: '纯粹留在本地',
                              body: '世界书、世界线存档与加密 API Key 全部留在设备本地，零中转、零追踪。',
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Spacer(),
                    FButton(
                      prefix: const Icon(LucideIcons.plug, size: 17),
                      onPress: onConfigure,
                      child: const Text('配置模型接口'),
                    ),
                    const SizedBox(height: 10),
                    FButton(
                      variant: FButtonVariant.ghost,
                      onPress: onSkip,
                      child: const Text('先逛逛，稍后再配'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _featureRow(
    ReadingPalette palette,
    SurfaceLadder ladder, {
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: palette.accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 17, color: palette.accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: palette.ink,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: palette.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
