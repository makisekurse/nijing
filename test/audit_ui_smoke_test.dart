import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nijing/data/secure_store.dart';
import 'package:nijing/main.dart';
import 'package:nijing/models/annotation.dart';
import 'package:nijing/models/app_config.dart';
import 'package:nijing/models/chapter_node.dart';
import 'package:nijing/models/model_profile.dart';
import 'package:nijing/models/save_slot.dart';
import 'package:nijing/models/world_book.dart';
import 'package:nijing/models/world_line.dart';
import 'package:nijing/models/world_state.dart';
import 'package:nijing/services/providers.dart';
import 'package:nijing/state/config_provider.dart';
import 'package:nijing/state/library_provider.dart';
import 'package:nijing/ui/screens/onboarding_screen.dart';
import 'package:nijing/ui/screens/quick_create_screen.dart';
import 'package:nijing/ui/screens/reader_screen.dart';
import 'package:nijing/ui/screens/settings_screen.dart';
import 'package:nijing/ui/screens/worldbook_editor_screen.dart';
import 'package:nijing/ui/widgets/app_toast.dart';
import 'package:nijing/ui/widgets/glossary_sheet.dart';
import 'package:nijing/ui/widgets/reader_drawer.dart';
import 'package:nijing/ui/widgets/reader_sheets.dart';
import 'package:nijing/ui/widgets/reader_typography_sheet.dart';
import 'package:nijing/ui/widgets/reader_world_line_sheets.dart';
import 'package:nijing/ui/widgets/remote_model_picker_sheet.dart';
import 'package:nijing/ui/widgets/thought_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const MethodChannel _kSecureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final mockSecureMap = <String, String>{};

  setUp(() async {
    mockSecureMap.clear();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kSecureStorageChannel, (call) async {
      final args = (call.arguments as Map?) ?? <dynamic, dynamic>{};
      final key = args['key']?.toString();
      switch (call.method) {
        case 'read':
          return key == null ? null : mockSecureMap[key];
        case 'write':
          if (key != null) {
            mockSecureMap[key] = args['value']?.toString() ?? '';
          }
          return null;
        case 'delete':
          if (key != null) mockSecureMap.remove(key);
          return null;
        case 'deleteAll':
          mockSecureMap.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(mockSecureMap);
        default:
          return null;
      }
    });
    await SecureStore.clearAllKeys();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kSecureStorageChannel, null);
  });

  WorldBook sampleBook() => WorldBook(
        id: 'wb_smoke_1',
        name: '决胜西南1949',
        era: '1949年11月',
        worldview: '川黔边地大迂回大包围战役背景。',
        playerRole: '前线总指挥',
      );

  SaveSlot sampleSlot() {
    final book = sampleBook();
    final state = WorldState(
      time: '1949年11月18日 深夜',
      location: '秀山前沿指挥所',
      facts: const <String>['先遣纵队已渡过乌江'],
      relations: const <String, String>{'陈旅长': '坚决执行夜渡方案'},
      events: const <String>['敌军西撤动态尚不明朗'],
    );
    final ch1 = ChapterNode(
      chapterIndex: 1,
      title: '第 1 幕',
      date: '1949年11月18日 深夜',
      playerAction: '命先遣团立刻强渡乌江',
      content: '细雨打在油布地图上，电台滴滴答答响个不停。',
      choices: const <String>['立刻派二梯队跟进', '先查明南岸伏兵'],
      glossary: const <GlossaryEntry>[
        GlossaryEntry(term: '白马渡', explanation: '乌江中游险要渡口'),
      ],
      cast: const <CastEntry>[
        CastEntry(name: '陈旅长', role: '前卫旅旅长', stance: '坚定'),
      ],
      thought: '先确立战场紧迫感，再交代渡口水情。',
      thinkingDurationMs: 2400,
      stateDiffSummary: '移至秀山 · 新人物 1',
      godMode: true,
      rawOutput: '<date>1949年11月18日 深夜</date>\n细雨打在油布地图上。',
      worldStateAfter: state,
    );
    final mainLine = WorldLine(
      id: 'line_main',
      name: '主线',
      history: <ChapterNode>[ch1],
      chronicle: '1949年11月，我军隐蔽集结并抢占白马渡。',
      worldState: state,
    );
    final branchLine = WorldLine(
      id: 'line_branch_1',
      name: '世界线 1',
      history: <ChapterNode>[ch1],
      parentLineId: 'line_main',
      branchedAtChapter: 1,
      worldState: state,
    );
    return SaveSlot(
      id: 'slot_smoke_1',
      title: book.name,
      worldBook: book,
      lines: <WorldLine>[mainLine, branchLine],
      activeLineId: 'line_main',
    );
  }

  group('同构整页渲染与弹层冒烟测试（零假 Scaffold · 零 Material 崩溃 · 零溢出）', () {
    testWidgets('HistSimApp(HomeShell) 三 Tab 切换与 FScaffold 下 AppToast 零异常',
        (tester) async {
      await tester.pumpWidget(
        HistSimApp(initialConfig: AppConfig(), showOnboarding: false),
      );
      await tester.pumpAndSettle();

      expect(find.text('世界'), findsWidgets);
      expect(find.text('继续'), findsWidgets);
      expect(find.text('我的'), findsWidgets);

      // 切换三个 Tab
      await tester.tap(find.text('世界').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('继续').last);
      await tester.pumpAndSettle();

      // 在 FScaffold 页面内直接触发 AppToast（脱离 Material Scaffold 验证 P0-2）
      final ctx = tester.element(find.text('继续').last);
      AppToast.show(ctx, '同构环境提示测试成功');
      await tester.pumpAndSettle();
      expect(find.text('同构环境提示测试成功'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('OnboardingScreen / QuickCreateScreen / WorldBookEditorScreen 同构渲染零异常',
        (tester) async {
      final cfgProvider = ConfigProvider(AppConfig());
      final libProvider = LibraryProvider();
      addTearDown(() {
        cfgProvider.dispose();
        libProvider.dispose();
      });

      // 1. OnboardingScreen
      await tester.pumpWidget(
        HistSimApp.buildHostApp(
          themeMode: 'mirage',
          home: OnboardingScreen(onConfigure: () {}, onSkip: () {}),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('配置模型接口'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 2. QuickCreateScreen（验证示例胶囊点击无 No Material 崩溃）
      await tester.pumpWidget(
        MultiProvider(
          providers: <ChangeNotifierProvider<ChangeNotifier>>[
            ChangeNotifierProvider<ConfigProvider>.value(value: cfgProvider),
            ChangeNotifierProvider<LibraryProvider>.value(value: libProvider),
          ],
          child: HistSimApp.buildHostApp(
            themeMode: 'vintage',
            home: const QuickCreateScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('一个架空的晚唐江湖'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // 3. WorldBookEditorScreen
      await tester.pumpWidget(
        MultiProvider(
          providers: <ChangeNotifierProvider<ChangeNotifier>>[
            ChangeNotifierProvider<ConfigProvider>.value(value: cfgProvider),
            ChangeNotifierProvider<LibraryProvider>.value(value: libProvider),
          ],
          child: HistSimApp.buildHostApp(
            themeMode: 'parchment',
            home: WorldBookEditorScreen(book: sampleBook()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('编辑世界书'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('SettingsScreen(all) 含档案/辅模型/滑杆与 didUpdateWidget 同步零异常',
        (tester) async {
      await SecureStore.writeKeyForProvider('bailian', 'sk-bailian-ui');
      await SecureStore.writeKeyForProvider('deepseek', 'sk-deepseek-ui');
      const dsProfile = ModelProfile(
        id: 'prof_ds_smoke',
        name: 'DeepSeek 主力',
        apiProvider: 'deepseek',
        modelName: 'deepseek-v4-pro',
      );
      await SecureStore.writeKeyForProfile(dsProfile.id, 'sk-prof-ds-smoke');

      final cfgProvider = ConfigProvider(
        AppConfig(
          apiProvider: 'bailian',
          modelName: 'qwen4-max',
          enableAuxModel: true,
          auxApiProvider: 'deepseek',
          auxModelName: 'deepseek-flash',
          savedProfiles: const <ModelProfile>[dsProfile],
        ),
      );
      addTearDown(cfgProvider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<ConfigProvider>.value(
          value: cfgProvider,
          child: Consumer<ConfigProvider>(
            builder: (context, p, _) => HistSimApp.buildHostApp(
              themeMode: p.config.themeMode,
              home: const SettingsScreen(section: SettingsSection.all),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 滚动到底部，确保所有 Section（含 Slider、色卡、日志区）全部构建无错
      await tester.drag(find.byType(ListView), const Offset(0, -1800));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 1800));
      await tester.pumpAndSettle();

      // 外部触发档案切换 -> 验证 didUpdateWidget 自动同步模型名与 Key
      await cfgProvider.applyProfile(dsProfile);
      await tester.pumpAndSettle();
      expect(find.text('DeepSeek 主力'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ReaderScreen + Aa 排版浮层 + 右侧抽屉 4 Tab + 远端模型选择器 + 附属弹层全绿',
        (tester) async {
      final cfgProvider = ConfigProvider(AppConfig(themeMode: 'vintage'));
      addTearDown(cfgProvider.dispose);
      final slot = sampleSlot();

      await tester.pumpWidget(
        ChangeNotifierProvider<ConfigProvider>.value(
          value: cfgProvider,
          child: Consumer<ConfigProvider>(
            builder: (context, p, _) => HistSimApp.buildHostApp(
              themeMode: p.config.themeMode,
              home: ReaderScreen(
                config: p.config,
                slot: slot,
                onConfigChanged: (c) => p.updateConfig(c, immediate: true),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 验证持久化的单幕 godMode 正确呈现「主宰敕令」
      expect(find.text('主宰敕令'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final readerCtx = tester.element(find.byType(ReaderScreen));

      // 1. 打开 Aa 实时排版浮层并交互
      ReaderTypographySheet.show(
        readerCtx,
        readConfig: () => cfgProvider.config,
        onApply: (next, {bool immediate = true}) =>
            cfgProvider.updateConfig(next, immediate: immediate),
      );
      await tester.pumpAndSettle();
      expect(find.text('实时阅读排版'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      await tester.tap(find.text('大'));
      await tester.pumpAndSettle();
      expect(cfgProvider.config.fontSize, 'lg');
      expect(tester.takeException(), isNull);
      Navigator.of(readerCtx).pop();
      await tester.pumpAndSettle();

      // 2. 打开右侧抽屉并依次切换全部 4 个 Tab（局势 / 目录 / 世界线 / 工具）
      final line = slot.activeLine;
      ReaderDrawer.show(
        readerCtx,
        book: slot.worldBook,
        worldState: line.worldState,
        chronicle: line.chronicle,
        history: line.history,
        lines: slot.lines,
        activeLineId: line.id,
        busy: false,
        onJumpToChapter: (_) {},
        onSelectLine: (_) {},
        onRenameLine: (_) {},
        onDeleteLine: (_) {},
        onPickBranch: () {},
        onOpenCast: () {},
        onOpenChronicle: () {},
        onExportStory: () {},
        onOpenTypography: () {},
        onOpenSettings: () {},
        onRerollLast: () {},
      );
      await tester.pumpAndSettle();
      expect(find.text('秀山前沿指挥所'), findsOneWidget);
      for (final tab in const <String>['目录', '世界线', '工具', '局势']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      Navigator.of(readerCtx).pop();
      await tester.pumpAndSettle();

      // 3. 打开 RemoteModelPickerSheet（含非空模型数据，验证渲染与点选返回）
      String? pickedModel;
      final pickerFuture = RemoteModelPickerSheet.show(
        readerCtx,
        config: cfgProvider.config,
        apiKey: 'sk-test',
        currentModel: 'qwen4-max',
        fetcher: () async => const <RemoteModelInfo>[
          RemoteModelInfo(id: 'deepseek-v4-pro', ownedBy: 'deepseek'),
          RemoteModelInfo(id: 'qwen3.8-flash', ownedBy: 'alibaba'),
          RemoteModelInfo(id: 'qwen4-max', ownedBy: 'alibaba'),
        ],
      ).then((v) => pickedModel = v);
      await tester.pumpAndSettle();
      expect(find.text('deepseek-v4-pro'), findsOneWidget);
      expect(find.text('qwen3.8-flash'), findsOneWidget);
      await tester.tap(find.text('deepseek-v4-pro'));
      await tester.pumpAndSettle();
      await pickerFuture;
      expect(pickedModel, 'deepseek-v4-pro');
      expect(tester.takeException(), isNull);

      // 4. 验证统一后的 forui 附属弹层（词条、思考链、章节菜单、导出菜单）均无错渲染
      AnnotationSheet.showGlossary(readerCtx, line.history.first.glossary);
      await tester.pumpAndSettle();
      expect(find.text('白马渡'), findsOneWidget);
      Navigator.of(readerCtx).pop();
      await tester.pumpAndSettle();

      ThoughtSheet.show(
        readerCtx,
        title: '第 1 幕',
        thought: line.history.first.thought,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('先确立战场紧迫感'), findsOneWidget);
      Navigator.of(readerCtx).pop();
      await tester.pumpAndSettle();

      ReaderSheets.showChapterMenu(
        readerCtx,
        chapter: line.history.first,
        onCopy: () {},
        onEdit: () {},
        onExportLog: () {},
      );
      await tester.pumpAndSettle();
      expect(find.text('复制本幕'), findsOneWidget);
      Navigator.of(readerCtx).pop();
      await tester.pumpAndSettle();

      ReaderExportAndLineSheets.showExportSheet(
        readerCtx,
        book: slot.worldBook,
        line: line,
        history: line.history,
        chronicle: line.chronicle,
        worldState: line.worldState,
      );
      await tester.pumpAndSettle();
      expect(find.text('导出推演故事'), findsOneWidget);
      Navigator.of(readerCtx).pop();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
    });
  });
}
