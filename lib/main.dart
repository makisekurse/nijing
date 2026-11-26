import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
          final mode = cfgProvider.config.themeMode;
          final fTheme = AppTheme.getForuiTheme(mode);
          final mTheme = AppTheme.getTheme(mode);

          return MaterialApp(
            title: AppInfo.appName,
            debugShowCheckedModeBanner: false,
            navigatorKey: _navKey,
            theme: mTheme,
            localizationsDelegates: FLocalizations.localizationsDelegates,
            supportedLocales: FLocalizations.supportedLocales,
            builder: (context, child) => FTheme(
              data: fTheme,
              child: child ?? const SizedBox.shrink(),
            ),
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
