import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nijing/core/app_error.dart';
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
import 'package:nijing/services/fallback_service.dart';
import 'package:nijing/services/generation_controller.dart';
import 'package:nijing/services/llm_client.dart';
import 'package:nijing/services/providers.dart';
import 'package:nijing/services/runtime_log.dart';
import 'package:nijing/state/config_provider.dart';
import 'package:nijing/state/library_provider.dart';
import 'package:nijing/ui/screens/about_screen.dart';
import 'package:nijing/ui/screens/cast_screen.dart';
import 'package:nijing/ui/screens/chronicle_screen.dart';
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

  group('v2.0.4 中文系统语言（zh_Hans_CN）双轨本地化与续写日志回归', () {
    testWidgets('zh_Hans_CN 下全页面 + ReaderScreen（SelectionArea/TextField/主宰/断流续写）零灰屏零溢出',
        (tester) async {
      tester.platformDispatcher.localesTestValue = const <Locale>[
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'CN',
        ),
      ];
      addTearDown(tester.platformDispatcher.clearLocalesTestValue);

      final cfgProvider = ConfigProvider(
        AppConfig(themeMode: 'vintage', godMode: true, modelName: 'qwen3.8-flash'),
      );
      final libProvider = LibraryProvider();
      addTearDown(() {
        cfgProvider.dispose();
        libProvider.dispose();
      });

      final slot = sampleSlot();
      final ctrl = GenerationController.forSlot(slot.id);
      addTearDown(() => GenerationController.disposeSlot(slot.id));

      // 1. 主页 + 附属页面在 zh_Hans_CN 下均无缺失 MaterialLocalizations/CupertinoLocalizations 告警或异常
      final screens = <Widget>[
        HistSimApp(
          initialConfig: AppConfig(themeMode: 'vintage'),
          showOnboarding: false,
        ),
        HistSimApp.buildHostApp(
          themeMode: 'vintage',
          home: OnboardingScreen(onConfigure: () {}, onSkip: () {}),
        ),
        MultiProvider(
          providers: <ChangeNotifierProvider<ChangeNotifier>>[
            ChangeNotifierProvider<ConfigProvider>.value(value: cfgProvider),
            ChangeNotifierProvider<LibraryProvider>.value(value: libProvider),
          ],
          child: HistSimApp.buildHostApp(
            themeMode: 'vintage',
            home: const SettingsScreen(section: SettingsSection.all),
          ),
        ),
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
        MultiProvider(
          providers: <ChangeNotifierProvider<ChangeNotifier>>[
            ChangeNotifierProvider<ConfigProvider>.value(value: cfgProvider),
            ChangeNotifierProvider<LibraryProvider>.value(value: libProvider),
          ],
          child: HistSimApp.buildHostApp(
            themeMode: 'vintage',
            home: WorldBookEditorScreen(book: slot.worldBook),
          ),
        ),
        HistSimApp.buildHostApp(
          themeMode: 'vintage',
          home: CastScreen(history: slot.activeLine.history),
        ),
        HistSimApp.buildHostApp(
          themeMode: 'vintage',
          home: ChronicleScreen(history: slot.activeLine.history),
        ),
        HistSimApp.buildHostApp(
          themeMode: 'vintage',
          home: const AboutScreen(),
        ),
      ];

      for (final screen in screens) {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(screen);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      // 2. ReaderScreen 在 zh_Hans_CN + 主宰模式 + 正常/生成中/断流/续写态下 TextField 与 SelectionArea 零异常
      await tester.pumpWidget(const SizedBox.shrink());
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
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.textContaining('细雨打在油布地图上'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 验证 TextField 在中文 Locale 下可正常聚焦与输入
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '立刻增派渡江梯队');
      await tester.pumpAndSettle();
      expect(find.text('立刻增派渡江梯队'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 模拟断流 -> 继续生成（busy = true，TextField enabled: false）全链路无灰屏无溢出
      ctrl.status = GenerationStatus.interrupted;
      ctrl.godMode = true;
      ctrl.pendingAction = '立刻增派渡江梯队';
      ctrl.live = '江风骤紧，对岸灯火忽明忽暗。';
      ctrl.notice = '模型流返回错误（已完整保留上方正文）';
      ctrl.notifyListeners();
      await tester.pump();
      expect(find.text('继续生成'), findsOneWidget);
      expect(tester.takeException(), isNull);

      ctrl.status = GenerationStatus.generating;
      ctrl.notice = '';
      ctrl.notifyListeners();
      await tester.pump();
      expect(find.text('推演生成中…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    test('FallbackService.continueGenerate 错误与完成路径均写入 RuntimeLog', () async {
      final prevEnabled = RuntimeLog.enabled;
      RuntimeLog.enabled = true;
      RuntimeLog.clear();
      addTearDown(() {
        RuntimeLog.clear();
        RuntimeLog.enabled = prevEnabled;
      });

      final book = sampleBook();
      final failClient = _FakeContinueLlmClient(
        error: const AppError(
          AppErrorKind.server,
          '模型流返回错误：Output data may contain inappropriate content.',
          detail: '{"error":{"code":"data_inspection_failed"}}',
        ),
      );
      final failEvents = await FallbackService(failClient)
          .continueGenerate(
            config: AppConfig(),
            apiKey: 'sk-test',
            book: book,
            history: const <ChapterNode>[],
            playerAction: '测试行动',
            existingContent: '已有前文内容。',
            existingThought: '',
          )
          .toList();
      expect(
        failEvents.any((e) => e.kind == GenEventKind.interrupted),
        isTrue,
      );
      expect(
        RuntimeLog.entries().any(
          (e) =>
              e.tag == 'Fallback' &&
              e.message.contains('续写抛出') &&
              e.message.contains('data_inspection_failed'),
        ),
        isTrue,
      );

      RuntimeLog.clear();
      final okClient = _FakeContinueLlmClient(
        chunks: const <LlmChunk>[
          LlmChunk.content('续写补完的后半段剧情。\n<choices>\n1. 推进\n2. 坚守\n</choices>'),
        ],
      );
      final okEvents = await FallbackService(okClient)
          .continueGenerate(
            config: AppConfig(),
            apiKey: 'sk-test',
            book: book,
            history: const <ChapterNode>[],
            playerAction: '测试行动',
            existingContent: '已有前文内容。',
            existingThought: '',
          )
          .toList();
      expect(okEvents.any((e) => e.kind == GenEventKind.done), isTrue);
      expect(
        RuntimeLog.entries().any(
          (e) => e.tag == 'Fallback' && e.message.contains('续写完成'),
        ),
        isTrue,
      );
    });
  });
}

class _FakeContinueLlmClient extends LlmClient {
  final AppError? error;
  final List<LlmChunk> chunks;

  _FakeContinueLlmClient({
    this.error,
    this.chunks = const <LlmChunk>[],
  });

  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    for (final c in chunks) {
      yield c;
    }
    if (error != null) {
      throw error!;
    }
  }
}
