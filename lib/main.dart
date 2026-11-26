import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_info.dart';
import 'data/prefs_store.dart';
import 'models/app_config.dart';
import 'services/runtime_log.dart';
import 'ui/screens/home_shell.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/themes/app_theme.dart';

const String kConfigKey = 'nijing_config_v1';
const String kFirstRunKey = 'nijing_first_run_done';

/// 主题迁移标记。见 [_loadConfig]。
const String kThemeMigratedKey = 'nijing_theme_migrated_v2';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  final config = await _loadConfig();
  final firstRun = (await PrefsStore.getString(kFirstRunKey)) != 'done';

  runApp(HistSimApp(initialConfig: config, showOnboarding: firstRun));
}

Future<AppConfig> _loadConfig() async {
  var config = AppConfig();
  final raw = await PrefsStore.getString(kConfigKey);
  if (raw != null && raw.isNotEmpty) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        config = AppConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {
      // 配置损坏时回落到默认值，不要让应用起不来。
    }
  }

  // ---- 一次性迁移：主题切到「拟境」----
  //
  // 老配置里存的主题（vintage / dark / parchment）都是按旧定位选的。
  // 只改 `AppConfig` 的默认值没用 —— 用户存过的旧值会一直生效，
  // 表现为「换了定位，主题还是那三个」。
  //
  // 用标记位保证**只迁一次**：之后用户在设置里怎么选就怎么算，
  // 不会每次启动都被强行改回去。
  // 迁移旧版独立存放的百炼 workspaceId 到 AppConfig
  if (config.workspaceId.trim().isEmpty) {
    final legacyWs = (await PrefsStore.getString('nijing_workspace_id')) ?? '';
    if (legacyWs.trim().isNotEmpty) {
      config = config.copyWith(workspaceId: legacyWs.trim());
      await PrefsStore.setString(kConfigKey, config.encode());
    }
  }

  final migrated = (await PrefsStore.getString(kThemeMigratedKey)) == 'done';
  if (!migrated) {
    config = config.copyWith(themeMode: AppTheme.defaultId);
    await PrefsStore.setString(kConfigKey, config.encode());
    await PrefsStore.setString(kThemeMigratedKey, 'done');
  }

  return config;
}

/// 把配置里的日志开关同步到 [RuntimeLog]。
void _syncLogFlags(AppConfig c) {
  RuntimeLog.enabled = c.logEnabled;
  RuntimeLog.verbose = c.verboseLog;
}

class HistSimApp extends StatefulWidget {
  final AppConfig initialConfig;
  final bool showOnboarding;

  const HistSimApp({
    super.key,
    required this.initialConfig,
    required this.showOnboarding,
  });

  @override
  State<HistSimApp> createState() => _HistSimAppState();
}

class _HistSimAppState extends State<HistSimApp> with WidgetsBindingObserver {
  late AppConfig _config;
  late bool _onboarding;

  @override
  void initState() {
    super.initState();
    _config = widget.initialConfig;
    _onboarding = widget.showOnboarding;
    WidgetsBinding.instance.addObserver(this);
    _syncLogFlags(_config);
    RuntimeLog.i('App', '启动 · ${AppInfo.appName} v${AppInfo.versionLabel}');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 退到后台 / 被系统回收前，把还在防抖窗口里的设置写入落盘。
  ///
  /// ⚠️ 2026-09-25 修：`PrefsStore.flush()` 之前**从未被调用**，
  /// 用户改完设置马上退出应用，改动就丢了 —— 表现为「设置没生效」。
  /// 现在离散选择已经改成立即落盘（见 SettingsScreen._apply），
  /// 这里再兜住输入框/滑杆那类防抖写入。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      PrefsStore.flush();
    }
  }

  void _updateConfig(AppConfig c) {
    setState(() => _config = c);
    _syncLogFlags(c);
  }

  Future<void> _finishOnboarding({required bool openSettings}) async {
    await PrefsStore.setString(kFirstRunKey, 'done');
    if (!mounted) return;
    setState(() => _onboarding = false);
    if (openSettings) {
      // 交给下一帧，确保 Navigator 已经挂上。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _navKey.currentContext;
        if (ctx == null) return;
        Navigator.of(ctx).push(
          MaterialPageRoute<void>(
            builder: (_) => SettingsScreen(
              config: _config,
              onConfigChanged: _updateConfig,
            ),
          ),
        );
      });
    }
  }

  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppInfo.appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      theme: AppTheme.getTheme(_config.themeMode),
      home: _onboarding
          ? OnboardingScreen(
              onConfigure: () => _finishOnboarding(openSettings: true),
              onSkip: () => _finishOnboarding(openSettings: false),
            )
          : HomeShell(
              config: _config,
              onConfigChanged: _updateConfig,
            ),
    );
  }
}
