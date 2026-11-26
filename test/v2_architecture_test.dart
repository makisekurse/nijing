import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forui/forui.dart';
import 'package:nijing/core/app_error.dart';
import 'package:nijing/data/secure_store.dart';
import 'package:nijing/models/app_config.dart';
import 'package:nijing/models/chapter_node.dart';
import 'package:nijing/models/model_profile.dart';
import 'package:nijing/models/save_slot.dart';
import 'package:nijing/models/world_book.dart';
import 'package:nijing/models/world_line.dart';
import 'package:nijing/models/world_state.dart';
import 'package:nijing/services/fallback_service.dart';
import 'package:nijing/services/game_session.dart';
import 'package:nijing/services/generation_controller.dart';
import 'package:nijing/services/llm_client.dart';
import 'package:nijing/services/providers.dart';
import 'package:nijing/services/reasoning_dialect.dart';
import 'package:nijing/services/runtime_log.dart';
import 'package:nijing/services/save_service.dart';
import 'package:nijing/services/scene_extractor_service.dart';
import 'package:nijing/ui/themes/app_theme.dart';
import 'package:nijing/ui/themes/surface_ladder.dart';
import 'package:nijing/ui/widgets/reader_composer.dart';
import 'package:nijing/ui/widgets/reader_paragraph.dart';
import 'package:nijing/ui/widgets/thinking_capsule.dart';
import 'package:nijing/ui/widgets/world_book_cover.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('v2.0 · 2026 模型预设、方言适配与远端 /models 解析', () {
    test('AppConfig 默认模型升级为 qwen4-max 且保留完整向后兼容', () {
      final cfg = AppConfig();
      expect(cfg.modelName, 'qwen4-max');
      expect(cfg.enableBackgroundExtract, isTrue);
      expect(cfg.enableAuxModel, isFalse);

      // 老存档 JSON 缺少 v2 字段时安全补齐默认值
      final legacy = AppConfig.fromJson(<String, dynamic>{
        'apiProvider': 'bailian',
        'modelName': 'qwen-plus',
        'maxWords': 1200,
      });
      expect(legacy.modelName, 'qwen-plus');
      expect(legacy.enableBackgroundExtract, isTrue);
      expect(legacy.savedProfiles, isEmpty);
    });

    test('AppConfig.resolveAuxConfig 与 applyProfile 跨服务商主辅切换', () {
      final base = AppConfig(
        apiProvider: 'bailian',
        modelName: 'qwen4-max',
        enableAuxModel: true,
        auxApiProvider: 'deepseek',
        auxModelName: 'deepseek-flash',
      );
      final aux = base.resolveAuxConfig();
      expect(aux.apiProvider, 'deepseek');
      expect(aux.modelName, 'deepseek-flash');
      expect(aux.enableThinking, isFalse);

      const profile = ModelProfile(
        id: 'prof_ds_v4',
        name: 'DeepSeek V4 推演档',
        apiProvider: 'deepseek',
        modelName: 'deepseek-v4-pro',
        reasoningDialect: 'deepseek_v4',
        reasoningEffort: 'max',
      );
      final switched = base.applyProfile(profile);
      expect(switched.apiProvider, 'deepseek');
      expect(switched.modelName, 'deepseek-v4-pro');
      expect(switched.reasoningDialect, 'deepseek_v4');
      expect(switched.reasoningEffort, 'max');
    });

    test('ReasoningDialectResolver 精确区分百炼 / DeepSeek V4 / OpenAI / 自定义', () {
      final bailian = AppConfig(
        apiProvider: 'bailian',
        modelName: 'qwen4-max',
        enableThinking: true,
        thinkingBudget: 4096,
      );
      final bParams = <String, dynamic>{};
      ReasoningDialectResolver.applyStreamingThinking(
        bParams,
        config: bailian,
        modelName: bailian.modelName,
        stripThinkingParams: false,
      );
      expect(bParams['enable_thinking'], isTrue);
      expect(bParams['thinking_budget'], 4096);

      final dsV4 = AppConfig(
        apiProvider: 'deepseek',
        modelName: 'deepseek-v4-pro',
        enableThinking: true,
        reasoningEffort: 'high',
      );
      final dsParams = <String, dynamic>{};
      ReasoningDialectResolver.applyStreamingThinking(
        dsParams,
        config: dsV4,
        modelName: dsV4.modelName,
        stripThinkingParams: false,
      );
      expect(dsParams['thinking'], <String, dynamic>{'type': 'enabled'});
      expect(dsParams['reasoning_effort'], 'high');
      expect(
        ReasoningDialectResolver.allowsTemperature(
          modelName: 'o3-mini',
          thinkingEnabled: true,
        ),
        isFalse,
      );

      final dsOff = <String, dynamic>{};
      ReasoningDialectResolver.applyDisableThinking(
        dsOff,
        config: dsV4,
        modelName: dsV4.modelName,
        stripThinkingParams: false,
      );
      expect(dsOff['thinking'], <String, dynamic>{'type': 'disabled'});

      final customOai = AppConfig(
        apiProvider: 'custom',
        modelName: 'gpt-6.2-thinking',
        reasoningDialect: 'openai_effort',
        enableThinking: true,
        reasoningEffort: 'high',
      );
      final oaiParams = <String, dynamic>{};
      ReasoningDialectResolver.applyStreamingThinking(
        oaiParams,
        config: customOai,
        modelName: customOai.modelName,
        stripThinkingParams: false,
      );
      expect(oaiParams['reasoning_effort'], 'high');

      // 自定义聚合中转 auto 模式：绝不盲目塞厂商专有字段
      final customPlain = AppConfig(
        apiProvider: 'custom',
        modelName: 'claude-sonnet-5.5',
        reasoningDialect: 'auto',
      );
      final plainParams = <String, dynamic>{};
      ReasoningDialectResolver.applyStreamingThinking(
        plainParams,
        config: customPlain,
        modelName: customPlain.modelName,
        stripThinkingParams: false,
      );
      expect(plainParams, isEmpty);
    });

    test('Providers.parseRemoteModelsPayload 兼容 OpenAI / DashScope / 数组格式', () {
      final oai = Providers.parseRemoteModelsPayload(<String, dynamic>{
        'data': <dynamic>[
          <String, dynamic>{'id': 'qwen4-max', 'owned_by': 'alibaba'},
          <String, dynamic>{'id': 'deepseek-v4-pro', 'owned_by': 'deepseek'},
          <String, dynamic>{'id': 'qwen4-max', 'owned_by': 'dup'},
        ],
      });
      expect(oai.map((e) => e.id).toList(), <String>['deepseek-v4-pro', 'qwen4-max']);

      final dash = Providers.parseRemoteModelsPayload(<String, dynamic>{
        'output': <String, dynamic>{
          'models': <dynamic>[
            <String, dynamic>{'model': 'qwen-flash', 'provider': 'dashscope'},
          ],
        },
      });
      expect(dash.single.id, 'qwen-flash');

      expect(Providers.isRetiredDeepSeekModel('deepseek-chat'), isTrue);
      expect(Providers.isRetiredDeepSeekModel('deepseek-reasoner'), isTrue);
      expect(Providers.isRetiredDeepSeekModel('deepseek-v4-pro'), isFalse);

      // 校验 2026 百炼与 DeepSeek 官方快捷与辅模型推荐预设
      expect(Providers.byId('bailian').defaultModel, 'qwen4-max');
      expect(Providers.byId('bailian').recommendedAuxModel, 'qwen3.8-flash');
      expect(
        Providers.bailianModels,
        containsAll(<String>['qwen4-max', 'qwen3.8-max', 'qwen3.8-flash']),
      );
      expect(Providers.byId('deepseek').recommendedAuxModel, 'deepseek-flash');
    });
  });

  group('v2.0 · 多服务商分槽加密存储与多密钥日志脱敏', () {
    setUp(() async {
      await SecureStore.clearAllKeys();
      RuntimeLog.clearSecrets();
      RuntimeLog.clear();
      RuntimeLog.enabled = true;
    });

    tearDown(() async {
      await SecureStore.clearAllKeys();
      RuntimeLog.clearSecrets();
      RuntimeLog.enabled = false;
    });

    test('百炼 / DeepSeek / 自定义 / 辅模型 / 档案槽位 Key 完全隔离不串号', () async {
      await SecureStore.writeKeyForProvider('bailian', 'sk-bailian-secret-111');
      await SecureStore.writeKeyForProvider('deepseek', 'sk-deepseek-secret-222');
      await SecureStore.writeKeyForProvider('custom', 'sk-custom-secret-333');
      await SecureStore.writeAuxKey('sk-aux-secret-444');
      await SecureStore.writeKeyForProfile('prof_1', 'sk-prof-secret-555');

      expect(await SecureStore.readKeyForProvider('bailian'), 'sk-bailian-secret-111');
      expect(await SecureStore.readKeyForProvider('deepseek'), 'sk-deepseek-secret-222');
      expect(await SecureStore.readKeyForProvider('custom'), 'sk-custom-secret-333');
      expect(await SecureStore.readAuxDedicatedKey(), 'sk-aux-secret-444');
      expect(
        await SecureStore.readKeyForProfile('prof_1', fallbackProviderId: 'bailian'),
        'sk-prof-secret-555',
      );

      // 辅模型开启时优先取专用 aux 槽位，关闭时回退主模型 Key
      final cfgDual = AppConfig(
        apiProvider: 'bailian',
        enableAuxModel: true,
        auxApiProvider: 'deepseek',
        auxModelName: 'deepseek-flash',
      );
      expect(await SecureStore.readAuxKeyForConfig(cfgDual), 'sk-aux-secret-444');

      // 清空专用 aux Key 后自动回退 auxApiProvider 对应服务商槽位
      await SecureStore.writeAuxKey('');
      expect(await SecureStore.readAuxKeyForConfig(cfgDual), 'sk-deepseek-secret-222');

      // 日志多密钥同步脱敏
      RuntimeLog.registerSecret('sk-bailian-secret-111');
      RuntimeLog.registerSecret('sk-deepseek-secret-222');
      RuntimeLog.i('Auth', 'main=sk-bailian-secret-111 aux=sk-deepseek-secret-222');
      final dumped = RuntimeLog.dump();
      expect(dumped, isNot(contains('sk-bailian-secret-111')));
      expect(dumped, isNot(contains('sk-deepseek-secret-222')));
    });

    test('旧版默认单一 Key 自动向后兼容读取', () async {
      await SecureStore.writeApiKey('sk-legacy-only-key');
      final cfg = AppConfig(apiProvider: 'bailian');
      expect(await SecureStore.readMainKeyForConfig(cfg), 'sk-legacy-only-key');
    });
  });

  group('v2.0 · 零清屏流式、原地续写（Continue）与台词零误杀', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tempDir = await Directory.systemTemp.createTemp('nijing_v2_gen_');
      SaveService.testStorageDirectory = tempDir;
      SaveService.resetCacheForTest();
    });

    tearDown(() async {
      GenerationController.resetAll();
      SaveService.testStorageDirectory = null;
      SaveService.resetCacheForTest();
      try {
        if (tempDir.existsSync()) {
          await tempDir.delete(recursive: true);
        }
      } catch (_) {}
    });

    test('角色台词含「抱歉/对不起/我不能/我无法」绝不误杀掐流或清屏重来', () async {
      final mock = _MockDialogueWithSorryClient();
      final fb = FallbackService(mock);
      final events = await fb.generate(
        config: AppConfig(),
        apiKey: 'sk-test',
        book: WorldBook(id: 'wb_sorry', name: '孤城', worldview: '民国'),
        history: const <ChapterNode>[],
        playerAction: '询问副官实情',
      ).toList();

      expect(mock.calls, 1);
      expect(events.any((e) => e.kind == GenEventKind.restart), isFalse);
      final done = events.singleWhere((e) => e.kind == GenEventKind.done);
      expect(done.chapter!.body, contains('抱歉，长官，这件事我不能答应'));
      expect(done.chapter!.body, contains('对不起，我也无法违背军令'));
    });

    test('断流原地续写（continueGeneration）无缝接续已有正文并落幕', () async {
      final mock = _MockInterruptThenContinueClient();
      final controller = GenerationController.forSlot(
        'slot_v2_continue',
        client: mock,
      );
      controller.reset();

      final book = WorldBook(id: 'wb_c', name: '决胜西南1949', worldview: '历史');
      final slot = SaveSlot(id: 'slot_v2_continue', title: '测试', worldBook: book);
      final session = GameSession(slot);

      // 1. 首次推演吐出半段正文后断流 -> 进入 interrupted 且不丢字
      await controller.startGeneration(
        session: session,
        config: AppConfig(enableBackgroundExtract: false),
        apiKey: 'sk-test',
        action: '下达夜渡命令',
        book: book,
      );

      expect(controller.status, GenerationStatus.interrupted);
      expect(controller.liveBodyPreview, contains('江面上大雾弥漫，第一批木船刚离岸'));
      expect(session.history, isEmpty);

      // 2. 点击「继续生成」原地无缝续写并完整落盘
      await controller.continueGeneration();

      expect(controller.status, GenerationStatus.completed);
      expect(session.history.length, 1);
      expect(session.history.first.content, contains('江面上大雾弥漫，第一批木船刚离岸'));
      expect(session.history.first.content, contains('对岸突然亮起三发绿色信号弹'));
      expect(session.choices, containsAll(<String>['命令后续梯队强渡', '派侦察班抢占滩头']));
    });

    test('断流后支持直接将当前已生成正文落幕保存（commitInterruptedAsChapter）', () async {
      final mock = _MockInterruptThenContinueClient();
      final controller = GenerationController.forSlot(
        'slot_v2_commit',
        client: mock,
      );
      controller.reset();

      final book = WorldBook(id: 'wb_commit', name: '风雪夜归人', worldview: '江湖');
      final slot = SaveSlot(id: 'slot_v2_commit', title: '测试', worldBook: book);
      final session = GameSession(slot);

      await controller.startGeneration(
        session: session,
        config: AppConfig(enableBackgroundExtract: false),
        apiKey: 'sk-test',
        action: '推开客栈木门',
        book: book,
      );
      expect(controller.status, GenerationStatus.interrupted);

      await controller.commitInterruptedAsChapter();
      expect(controller.status, GenerationStatus.completed);
      expect(session.history.length, 1);
      expect(session.history.first.content, contains('江面上大雾弥漫'));
    });
  });

  group('v2.0 · 后台双模型档案官解析与世界状态合入', () {
    test('SceneExtractorService.parseExtractionJson 容错解析 fenced JSON 并生成变更摘要', () {
      const raw = '''
```json
{
  "date": "1949年11月18日 拂晓",
  "time": "1949年11月18日 拂晓",
  "location": "白马渡口前沿指挥所",
  "facts": ["渡江先遣营已抢占南岸高地", "敌军电台陷入静默"],
  "relations": {"陈旅长": "全力配合夜渡计划"},
  "events": ["主力渡江正在推进"],
  "newCast": [{"name": "陈旅长", "role": "前卫旅旅长", "stance": "坚决执行"}],
  "newGlossary": [{"term": "白马渡", "explanation": "乌江中游重要战略渡口"}]
}
```''';
      final prev = WorldState(
        time: '1949年11月17日 深夜',
        location: '北岸临时指挥部',
        facts: const <String>['侦察船已集结完毕'],
      );
      final res = SceneExtractorService.parseExtractionJson(
        raw,
        previousState: prev,
      );

      expect(res, isNotNull);
      expect(res!.date, '1949年11月18日 拂晓');
      expect(res.stateDelta.location, '白马渡口前沿指挥所');
      expect(res.cast.single.name, '陈旅长');
      expect(res.glossary.single.term, '白马渡');
      expect(res.diffSummary, isNotEmpty);

      // 校验 GameSession.applyBackgroundExtraction 保持世界线快照一致
      final book = WorldBook(id: 'wb_ext', name: '决胜西南', worldview: '历史');
      final slot = SaveSlot(
        id: 'slot_ext',
        title: '测试',
        worldBook: book,
        lines: <WorldLine>[
          WorldLine(
            id: 'main',
            name: '主线',
            history: <ChapterNode>[
              ChapterNode(
                chapterIndex: 1,
                title: '第一幕',
                content: '江雾弥漫。',
                worldStateAfter: prev,
              ),
            ],
            worldState: prev,
          ),
        ],
      );
      final session = GameSession(slot);
      session.applyBackgroundExtraction(res);

      expect(session.worldState.location, '白马渡口前沿指挥所');
      expect(session.history.last.worldStateAfter!.location, '白马渡口前沿指挥所');
      expect(session.history.last.stateDiffSummary, res.diffSummary);
      expect(session.history.last.cast.single.name, '陈旅长');
      expect(session.history.last.glossary.single.term, '白马渡');
    });
  });

  group('v2.0 · 文学富文本排版、HCT 容器色阶与 forui 组件渲染', () {
    test('ReaderParagraph.parseInlineSpans 精准解析加粗与斜体且不露裸星号', () {
      const base = TextStyle(fontSize: 17, color: Colors.black);
      final spans = ReaderParagraph.parseInlineSpans(
        '他摊开电报，**全军立刻南下**四个字旁划着*一道红杠*。',
        base,
      );

      final combined = spans
          .whereType<TextSpan>()
          .map((s) => s.text ?? '')
          .join();
      expect(combined, '他摊开电报，全军立刻南下四个字旁划着一道红杠。');
      expect(combined, isNot(contains('*')));
      expect(
        spans.whereType<TextSpan>().any(
              (s) => s.text == '全军立刻南下' && s.style?.fontWeight == FontWeight.w700,
            ),
        isTrue,
      );
      expect(
        spans.whereType<TextSpan>().any(
              (s) => s.text == '一道红杠' && s.style?.fontStyle == FontStyle.italic,
            ),
        isTrue,
      );
    });

    test('SurfaceLadder HCT 五级容器与四套主题 FThemeData 均正确构建', () {
      for (final preset in AppTheme.presets) {
        final fTheme = AppTheme.getForuiTheme(preset.id);
        final mTheme = AppTheme.getTheme(preset.id);
        final ladder = mTheme.extension<SurfaceLadder>();
        final reading = mTheme.extension<ReadingPalette>();
        expect(fTheme.colors.background, isNotNull);
        expect(ladder, isNotNull);
        expect(reading, isNotNull);
        expect(ladder!.card, isNot(equals(ladder.page)));
      }
    });

    testWidgets('ThinkingCapsule / ReaderComposer / WorldBookCover / 引用块在 FTheme 下无错渲染',
        (tester) async {
      final inputCtrl = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(() {
        inputCtrl.dispose();
        focusNode.dispose();
      });

      var continued = false;
      final book = WorldBook(
        id: 'wb_ui',
        name: '决胜西南1949',
        era: '1949年秋',
        worldview: '大迂回大包围战役背景',
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.vintage,
          localizationsDelegates: FLocalizations.localizationsDelegates,
          supportedLocales: FLocalizations.supportedLocales,
          builder: (context, child) => FTheme(
            data: AppTheme.getForuiTheme('vintage'),
            child: child ?? const SizedBox.shrink(),
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  WorldBookCover(book: book, chapterCount: 5),
                  const ThinkingCapsule(
                    thought: '先评估敌军防线漏洞与后勤补给线。',
                    isLiveThinking: false,
                    durationMs: 4200,
                  ),
                  const ReaderParagraph(
                    text: '> 急电：先遣纵队已越过乌江，速派二梯队跟进。',
                    fontSize: 17,
                    lineHeight: 1.8,
                    indentLevel: 2,
                    color: Color(0xFF141413),
                    serif: true,
                  ),
                  ReaderComposer(
                    busy: false,
                    interrupted: true,
                    hasLiveBody: true,
                    isEmptyHistory: false,
                    notice: '网络连接中断（已完整保留上方正文）',
                    choices: const <String>[],
                    choicesExpanded: false,
                    onToggleChoices: () {},
                    onPickChoice: (_) {},
                    onStartOpening: () {},
                    controller: inputCtrl,
                    focusNode: focusNode,
                    godMode: false,
                    onToggleGodMode: (_) {},
                    onSend: (_) {},
                    onCancel: () {},
                    onContinue: () => continued = true,
                    onCommitInterrupted: () {},
                    onRetry: () {},
                    onDiscardInterrupted: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('决胜西南1949'), findsOneWidget);
      expect(find.textContaining('已深度思考'), findsOneWidget);
      expect(find.textContaining('急电：先遣纵队已越过乌江'), findsOneWidget);
      expect(find.text('继续生成'), findsOneWidget);
      expect(find.text('直接落幕'), findsOneWidget);

      await tester.tap(find.text('继续生成'));
      await tester.pumpAndSettle();
      expect(continued, isTrue);
    });
  });
}

class _MockDialogueWithSorryClient extends LlmClient {
  int calls = 0;

  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    calls++;
    yield const LlmChunk.content(
      '<date>1937年深秋</date>\n\n'
      '副官低着头轻声说道：“抱歉，长官，这件事我不能答应。对不起，我也无法违背军令。”\n\n'
      '<choices>\n继续追问底细\n改派他人执行\n</choices>',
    );
  }
}

class _MockInterruptThenContinueClient extends LlmClient {
  int calls = 0;

  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    calls++;
    if (calls == 1) {
      yield const LlmChunk.content(
        '<date>1949年11月19日 深夜</date>\n\n江面上大雾弥漫，第一批木船刚离岸，',
      );
      throw const AppError(AppErrorKind.network, '连接意外断开');
    }
    yield const LlmChunk.content(
      '对岸突然亮起三发绿色信号弹，暗哨已经拔除。\n\n'
      '<choices>\n命令后续梯队强渡\n派侦察班抢占滩头\n</choices>',
    );
  }
}
