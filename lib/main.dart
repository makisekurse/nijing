import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    as flutter_l10n;
import 'package:forui/forui.dart';
import 'package:provider/provider.dart';

import 'core/app_info.dart';
import 'data/prefs_store.dart';
import 'models/app_config.dart';
import 'services/runtime_log.dart';
import 'state/config_provider.dart';
import 'state/library_provider.dart';
import 'ui/screens/home_shell.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/settings_screen.dart';
import 'ui/themes/app_theme.dart';

const String kConfigKey = ConfigProvider.kConfigKey;
const String kFirstRunKey = 'nijing_first_run_done';
const String kThemeMigratedKey = ConfigProvider.kThemeMigratedKey;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    final ctx = details.context == null ? '' : ' (${details.context})';
    RuntimeLog.e('Flutter', '${details.exceptionAsString()}$ctx');
    if (previousFlutterOnError != null) {
      previousFlutterOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    RuntimeLog.e('Platform', '$error');
    return false;
  };

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
    ),
  );

  final config = await ConfigProvider.loadInitialConfig();
  final firstRun = (await PrefsStore.getString(kFirstRunKey)) != 'done';

  runApp(HistSimApp(initialConfig: config, showOnboarding: firstRun));
}

class HistSimApp extends StatefulWidget {
  final AppConfig initialConfig;
  final bool showOnboarding;

  const HistSimApp({
    super.key,
    required this.initialConfig,
    required this.showOnboarding,
  });

  /// 同时提供 `forui`（`package:material_ui` / `package:cupertino_ui`）与
  /// `flutter_localizations`（`package:flutter/material.dart` / `cupertino.dart`）双轨本地化委托，
  /// 彻底杜绝中文等非英文系统下 `SelectionArea` / `TextField` 找不到 `MaterialLocalizations` 导致灰屏崩溃。
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    ...FLocalizations.localizationsDelegates,
    flutter_l10n.GlobalMaterialLocalizations.delegate,
    flutter_l10n.GlobalCupertinoLocalizations.delegate,
  ];

  /// 取 `FLocalizations` 与 `flutter_localizations` 双边共同支持的语言交集，避免任意设备语言触发缺失委托警告。
  static final List<Locale> supportedLocales = List<Locale>.unmodifiable(
    FLocalizations.supportedLocales.where(
      (Locale locale) =>
          flutter_l10n.GlobalMaterialLocalizations.delegate
              .isSupported(locale) &&
          flutter_l10n.GlobalCupertinoLocalizations.delegate
              .isSupported(locale),
    ),
  );

  /// 生产与同构测试共用的根宿主包装（严禁人为套假 Material `Scaffold`）：
  /// - `FTheme` 注入 `forui` 触控与色阶体系；
  /// - `Material(type: MaterialType.transparency)` 为全应用路由及 `forui` 容器内的材质控件兜底祖先；
  /// - `FToaster` 承接全应用无 `Scaffold` 依赖的 Toast 提示。
  static Widget buildAppShell(
    BuildContext context, {
    required FThemeData fTheme,
    Widget? child,
  }) =>
      FTheme(
        data: fTheme,
        child: Material(
          type: MaterialType.transparency,
          child: FToaster(
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      );

  /// 构造与生产环境完全同构的 `MaterialApp`（供测试直接挂载任意页面而不套假 `Scaffold`）。
  static Widget buildHostApp({
    required String themeMode,
    required Widget home,
    GlobalKey<NavigatorState>? navigatorKey,
  }) {
    final fTheme = AppTheme.getForuiTheme(themeMode);
    final mTheme = AppTheme.getTheme(themeMode);
    return MaterialApp(
      title: AppInfo.appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: mTheme,
      localizationsDelegates: localizationsDelegates,
      supportedLocales: supportedLocales,
      builder: (context, child) => buildAppShell(
        context,
        fTheme: fTheme,
        child: child,
      ),
      home: home,
    );
  }

  @override
  State<HistSimApp> createState() => _HistSimAppState();
}

class _HistSimAppState extends State<HistSimApp> with WidgetsBindingObserver {
  late final ConfigProvider _configProvider;
  late final LibraryProvider _libraryProvider;
  late bool _onboarding;
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _configProvider = ConfigProvider(widget.initialConfig);
    _libraryProvider = LibraryProvider()..reload();
    _onboarding = widget.showOnboarding;
    WidgetsBinding.instance.addObserver(this);
    RuntimeLog.i('App', '启动 · ${AppInfo.appName} v${AppInfo.versionLabel}');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _configProvider.dispose();
    _libraryProvider.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      PrefsStore.flush();
    }
  }

  Future<void> _finishOnboarding({required bool openSettings}) async {
    await PrefsStore.setString(kFirstRunKey, 'done');
    if (!mounted) return;
    setState(() => _onboarding = false);
    if (openSettings) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = _navKey.currentContext;
        if (ctx == null) return;
        Navigator.of(ctx).push(
          MaterialPageRoute<void>(
            builder: (_) => const SettingsScreen(section: SettingsSection.model),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: <ChangeNotifierProvider<ChangeNotifier>>[
        ChangeNotifierProvider<ConfigProvider>.value(value: _configProvider),
        ChangeNotifierProvider<LibraryProvider>.value(value: _libraryProvider),
      ],
      child: Consumer<ConfigProvider>(
        builder: (context, cfgProvider, _) {
          return HistSimApp.buildHostApp(
            themeMode: cfgProvider.config.themeMode,
            navigatorKey: _navKey,
            home: _onboarding
                ? OnboardingScreen(
                    onConfigure: () => _finishOnboarding(openSettings: true),
                    onSkip: () => _finishOnboarding(openSettings: false),
                  )
                : const HomeShell(),
          );
        },
      ),
    );
  }
}
