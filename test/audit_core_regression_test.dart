import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nijing/core/app_error.dart';
import 'package:nijing/data/prefs_store.dart';
import 'package:nijing/data/secure_store.dart';
import 'package:nijing/models/annotation.dart';
import 'package:nijing/models/app_config.dart';
import 'package:nijing/models/chapter_node.dart';
import 'package:nijing/models/save_slot.dart';
import 'package:nijing/models/world_book.dart';
import 'package:nijing/models/world_state.dart';
import 'package:nijing/services/chronicle_service.dart';
import 'package:nijing/services/fallback_service.dart';
import 'package:nijing/services/game_session.dart';
import 'package:nijing/services/generation_controller.dart';
import 'package:nijing/services/llm_client.dart';
import 'package:nijing/services/prompt_builder.dart';
import 'package:nijing/services/providers.dart';
import 'package:nijing/services/runtime_log.dart';
import 'package:nijing/services/save_service.dart';
import 'package:nijing/services/scene_extractor_service.dart';
import 'package:nijing/state/config_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('P0-3 · 多槽密钥隔离与防跨厂商 Key / workspaceId 泄露', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await SecureStore.clearAllKeys();
      RuntimeLog.clear();
      RuntimeLog.enabled = true;
    });

    tearDown(() async {
      await SecureStore.clearAllKeys();
      RuntimeLog.enabled = false;
      GenerationController.resetAll();
    });

    test('保存百炼档案后手动切换 DeepSeek 填新 Key，resolveActiveMainKey 必须返回 DeepSeek Key',
        () async {
      final cfgProvider = ConfigProvider(
        AppConfig(apiProvider: 'bailian', modelName: 'qwen4-max'),
      );
      addTearDown(cfgProvider.dispose);

      // 1. 写入百炼全局 Key 并保存一个独立档案（带专属档案 Key）
      await SecureStore.writeKeyForProvider('bailian', 'sk-bailian-global');
      final prof = await cfgProvider.saveCurrentAsProfile(
        name: '百炼主力档',
        apiKey: 'sk-bailian-profile-only',
      );
      expect(cfgProvider.activeProfileId, prof.id);
      expect(await cfgProvider.resolveActiveMainKey(), 'sk-bailian-profile-only');

      // 2. applyProfile 绝不覆盖全局服务商槽位
      await cfgProvider.applyProfile(prof);
      expect(
        await SecureStore.readKeyForProvider('bailian'),
        'sk-bailian-global',
      );

      // 3. 手动切至 DeepSeek 并写入 DeepSeek Key -> 自动清空 activeProfileId 并返回 DeepSeek Key
      await SecureStore.writeKeyForProvider('deepseek', 'sk-deepseek-fresh-999');
      cfgProvider.updateConfig(
        cfgProvider.config.copyWith(
          apiProvider: 'deepseek',
          modelName: 'deepseek-v4-pro',
        ),
        immediate: true,
      );
      expect(cfgProvider.activeProfileId, isEmpty);
      expect(await cfgProvider.resolveActiveMainKey(), 'sk-deepseek-fresh-999');
    });

    test('跨厂商辅模型无 Key 时绝不泄露主厂商 API Key（单元与端到端双验证）', () async {
      final crossCfg = AppConfig(
        apiProvider: 'bailian',
        modelName: 'qwen4-max',
        workspaceId: 'ws-bj-secret',
        enableBackgroundExtract: true,
        enableAuxModel: true,
        auxApiProvider: 'deepseek',
        auxModelName: 'deepseek-flash',
      );
      expect(GenerationController.canAuxFallbackToMainKey(crossCfg), isFalse);
      expect(
        GenerationController.resolveEffectiveAuxKey(
          config: crossCfg,
          mainApiKey: 'sk-bailian-main-secret',
          auxApiKey: '',
        ),
        isEmpty,
      );

      // 同厂商但自定义不同端点同样禁止回退主 Key
      final diffEndpointCfg = AppConfig(
        apiProvider: 'custom',
        baseUrl: 'https://a.example.com/v1',
        modelName: 'main-model',
        enableAuxModel: true,
        auxApiProvider: 'custom',
        auxBaseUrl: 'https://b.example.com/v1',
        auxModelName: 'fast-model',
      );
      expect(GenerationController.canAuxFallbackToMainKey(diffEndpointCfg), isFalse);
      expect(
        GenerationController.resolveEffectiveAuxKey(
          config: diffEndpointCfg,
          mainApiKey: 'sk-endpoint-a',
          auxApiKey: '',
        ),
        isEmpty,
      );

      // 端到端推演：辅 Key 为空时，auxClient 绝不被调用，主 Key 绝不发送给第三方
      final mainMock = _SingleShotMainClient();
      final auxSpy = _SpyAuxCompleteClient();
      final ctrl = GenerationController.forSlot(
        'slot_no_leak',
        client: mainMock,
        auxClient: auxSpy,
      );
      final book = WorldBook(id: 'b_leak', name: '防泄露测试', worldview: '背景');
      final session = GameSession(
        SaveSlot(id: 'slot_no_leak', title: '测试', worldBook: book),
      );

      await ctrl.startGeneration(
        session: session,
        config: crossCfg,
        apiKey: 'sk-bailian-main-secret',
        auxApiKey: '',
        action: '推进一幕',
        book: book,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(auxSpy.calls, 0);
      expect(RuntimeLog.dump(), contains('未配置独立 API Key'));
    });

    test('主模型 workspaceId 绝不污染跨厂商辅模型 URL（SceneExtractor & Chronicle）',
        () async {
      final cfg = AppConfig(
        apiProvider: 'bailian',
        workspaceId: 'ws-bj-999',
        modelName: 'qwen4-max',
        enableAuxModel: true,
        auxApiProvider: 'deepseek',
        auxModelName: 'deepseek-flash',
      );
      expect(cfg.resolveAuxConfig().workspaceId, isEmpty);

      final spy = _SpyAuxCompleteClient(
        response: '{"location":"新地点","facts":["新事实"]}',
      );
      final book = WorldBook(id: 'b_ws', name: '测试世界', worldview: '背景');

      await SceneExtractorService.extract(
        config: cfg,
        apiKey: 'sk-deepseek-aux',
        book: book,
        previousState: WorldState(),
        chapterBody: '雨夜急行军。',
        workspaceId: cfg.workspaceId,
        client: spy,
      );
      expect(spy.calls, 1);
      expect(spy.lastConfig!.apiProvider, 'deepseek');
      expect(spy.lastWorkspaceId, isEmpty);
      expect(
        Providers.chatCompletionsUrl(
          spy.lastConfig!,
          workspaceId: spy.lastWorkspaceId,
        ),
        'https://api.deepseek.com/v1/chat/completions',
      );

      await ChronicleService.compress(
        config: cfg,
        apiKey: 'sk-deepseek-aux',
        book: book,
        previousChronicle: '',
        history: <ChapterNode>[
          ChapterNode(chapterIndex: 1, title: '第1幕', content: '剧情内容'),
        ],
        workspaceId: cfg.workspaceId,
        client: spy,
      );
      expect(spy.calls, 2);
      expect(spy.lastConfig!.apiProvider, 'deepseek');
      expect(spy.lastWorkspaceId, isEmpty);
    });
  });

  group('P1 · 并发写盘、后台档案官、Epoch 状态机、长度截断与数据层细节', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tempDir = await Directory.systemTemp.createTemp('nijing_audit_p1_');
      SaveService.testStorageDirectory = tempDir;
      SaveService.resetCacheForTest();
      GenerationController.resetAll();
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

    test('第 5 幕同槽并发 SaveService.upsert 零异常不丢档，且缺主文件时从 .bak 自愈',
        () async {
      final book = WorldBook(id: 'w_conc', name: '并发世界', worldview: '背景');
      final slot = SaveSlot(id: 'slot_conc', title: '并发测试', worldBook: book);

      // 模拟第 5 幕主落盘 + 档案官落盘 + 编年史落盘等 12 路并发写同一个 slotId
      await Future.wait<void>(
        List<Future<void>>.generate(12, (i) {
          final copy = SaveSlot.fromJson(slot.toJson())..title = '版本_$i';
          return SaveService.upsert(copy);
        }),
      );

      final loaded = await SaveService.loadAll();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'slot_conc');
      final leftovers = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp') || f.path.endsWith('.bak'))
          .toList();
      expect(leftovers, isEmpty);

      // 模拟写盘中途断电：正式 .json 缺失但 .bak 完好 -> 自动自愈恢复
      final primary = File('${tempDir.path}${Platform.pathSeparator}slot_slot_conc.json');
      final bak = File('${tempDir.path}${Platform.pathSeparator}slot_slot_conc.json.bak');
      await primary.rename(bak.path);
      expect(primary.existsSync(), isFalse);

      final healed = await SaveService.loadAll();
      expect(healed.length, 1);
      expect(healed.first.id, 'slot_conc');
      expect(primary.existsSync(), isTrue);
    });

    test('玩家快节奏推进下一幕时，上一幕后台档案官结果精准合入且顺延至最新状态', () {
      final book = WorldBook(id: 'w_fast', name: '快节奏测试', worldview: '背景');
      final session = GameSession(
        SaveSlot(id: 'slot_fast', title: '快节奏', worldBook: book),
      );

      // 第 1 幕落盘（此时后台档案官仍在跑）
      final ch1 = session.appendChapter(
        content: '第一幕：在重庆会见秘密联络员。',
        playerAction: '密会联络员',
        date: '1949年11月1日',
        choices: const <String>['前往成都'],
        glossary: const <GlossaryEntry>[],
        cast: const <CastEntry>[],
        rawOutput: '',
        stateRaw: '',
        godMode: true,
      );

      // 玩家不等后台返回，立刻推进第 2 幕
      session.appendChapter(
        content: '第二幕：连夜奔赴成都郊外。',
        playerAction: '连夜赶往成都',
        date: '1949年11月2日',
        choices: const <String>['进城'],
        glossary: const <GlossaryEntry>[],
        cast: const <CastEntry>[],
        rawOutput: '',
        stateRaw: '时间：1949年11月2日\n地点：成都郊外',
      );
      expect(session.history.length, 2);

      // 第 1 幕的后台抽取此时才返回 -> 按 (lineId, chapterIndex=1) 定向合入
      final extracted = SceneExtractionResult(
        stateDelta: WorldState(
          time: '1949年11月1日',
          location: '重庆茶馆',
          facts: const <String>['获得城防密电密码本'],
          relations: const <String, String>{'老周': '高度信任'},
        ),
        cast: const <CastEntry>[
          CastEntry(name: '老周', role: '地下联络员', stance: '盟友'),
        ],
        glossary: const <GlossaryEntry>[
          GlossaryEntry(term: '密电本', explanation: '重庆站专用密码本'),
        ],
        diffSummary: '局势+1 · 新人物 1',
      );

      final applied = session.applyBackgroundExtraction(
        extracted,
        targetLineId: session.line.id,
        targetChapterIndex: ch1.chapterIndex,
      );
      expect(applied, isTrue);

      // 第 1 幕精准获得人物、词条、摘要与自身快照
      expect(session.history[0].cast.single.name, '老周');
      expect(session.history[0].glossary.single.term, '密电本');
      expect(session.history[0].stateDiffSummary, '局势+1 · 新人物 1');
      expect(session.history[0].godMode, isTrue);

      // 第 2 幕快照与当前 worldState 既保留第 2 幕更新的地点「成都郊外」，也顺延继承第 1 幕发现的事实与人物关系
      expect(session.worldState.location, '成都郊外');
      expect(session.worldState.facts, contains('获得城防密电密码本'));
      expect(session.worldState.relations['老周'], '高度信任');
      expect(session.history[1].worldStateAfter!.facts, contains('获得城防密电密码本'));
    });

    test('cancel() 后立刻 discardInterrupted() 受 _runEpoch 保护，旧流退出绝不误刷 failed',
        () async {
      final mock = _ControllableStreamClient();
      final ctrl = GenerationController.forSlot('slot_epoch', client: mock);
      final book = WorldBook(id: 'w_ep', name: '代际保护', worldview: '背景');
      final session = GameSession(
        SaveSlot(id: 'slot_epoch', title: '测试', worldBook: book),
      );

      final runFuture = ctrl.startGeneration(
        session: session,
        config: AppConfig(enableBackgroundExtract: false),
        apiKey: 'sk-test',
        action: '试探前进',
        book: book,
      );

      // 吐出部分正文后：cancel() -> 立刻 discardInterrupted()
      mock.emit(const LlmChunk.content('夜色沉沉，火把渐近。'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      ctrl.cancel();
      expect(ctrl.status, GenerationStatus.interrupted);

      ctrl.discardInterrupted();
      expect(ctrl.status, GenerationStatus.idle);

      // 旧流此时再以网络错误收尾，绝不能把已清空的 idle 状态刷成 failed
      mock.fail(const AppError(AppErrorKind.network, '旧连接断开'));
      await runFuture;
      expect(ctrl.status, GenerationStatus.idle);
      expect(ctrl.notice, isEmpty);
    });

    test('finish_reason == length 且无 <choices> 进入可续写 interrupted；续写思考自动空行分隔并累加计时',
        () async {
      final mock = _LengthTruncatedThenContinueClient();
      final ctrl = GenerationController.forSlot('slot_len', client: mock);
      final book = WorldBook(id: 'w_len', name: '截断续写', worldview: '背景');
      final session = GameSession(
        SaveSlot(id: 'slot_len', title: '测试', worldBook: book),
      );

      await ctrl.startGeneration(
        session: session,
        config: AppConfig(enableBackgroundExtract: false),
        apiKey: 'sk-test',
        action: '出城巡查',
        book: book,
      );

      expect(ctrl.status, GenerationStatus.interrupted);
      expect(ctrl.notice, contains('长度上限'));
      expect(ctrl.liveBodyPreview, contains('城门外的长街静得出奇'));
      expect(session.history, isEmpty);
      final firstMs = ctrl.thinkingDurationMs;
      expect(firstMs, greaterThan(0));

      await ctrl.continueGeneration();

      expect(ctrl.status, GenerationStatus.completed);
      expect(session.history.length, 1);
      final ch = session.history.first;
      expect(ch.content, contains('城门外的长街静得出奇'));
      expect(ch.content, contains('忽然暗巷里转出一名提灯老者'));
      expect(ch.thought, contains('第一段思考\n\n第二段续写思考'));
      expect(ch.thinkingDurationMs, greaterThan(firstMs));
      expect(session.choices, containsAll(<String>['上前盘问', '暗中尾随']));
    });

    test('PrefsStore._pending 实时读、SecureStore 清空槽位索引、ChapterNode.godMode 与 Providers.fetchRemoteModels(http)',
        () async {
      // 1. PrefsStore.getString 在 700ms 防抖窗口内立即读到 _pending 最新值
      PrefsStore.setStringDebounced('k_pending_test', 'fresh_val');
      expect(await PrefsStore.getString('k_pending_test'), 'fresh_val');
      await PrefsStore.flush();

      // 2. SecureStore 写入空串后清理槽位索引，不影响旧默认 Key 回退判定
      await SecureStore.clearAllKeys();
      await SecureStore.writeApiKey('sk-legacy-fallback');
      await SecureStore.writeKeyForProvider('bailian', 'sk-temp');
      await SecureStore.writeKeyForProvider('bailian', '');
      expect(await SecureStore.readKeyForProvider('bailian'), 'sk-legacy-fallback');

      // 3. ChapterNode.godMode 持久化及旧存档兼容
      final chGod = ChapterNode(
        chapterIndex: 1,
        title: '第 1 幕',
        content: '敕令生效',
        godMode: true,
      );
      expect(ChapterNode.fromJson(chGod.toJson()).godMode, isTrue);
      final chLegacy = ChapterNode.fromJson(<String, dynamic>{
        'chapterIndex': 1,
        'title': '旧幕',
        'content': '旧正文',
      });
      expect(chLegacy.godMode, isFalse);

      // 4. Providers.fetchRemoteModels 基于 package:http 正常解析
      final mockHttp = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer sk-http-test');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'data': <Map<String, String>>[
              <String, String>{'id': 'qwen4-max', 'owned_by': 'alibaba'},
              <String, String>{'id': 'qwen3.8-flash', 'owned_by': 'alibaba'},
            ],
          }),
          200,
        );
      });
      final models = await Providers.fetchRemoteModels(
        config: AppConfig(apiProvider: 'bailian'),
        apiKey: 'sk-http-test',
        httpClient: mockHttp,
      );
      expect(models.map((e) => e.id).toList(), <String>['qwen3.8-flash', 'qwen4-max']);

      // 5. FallbackService 空正文重试才注入 retryNudge（与网络重试形成对比）
      final emptyThenOk = _EmptyOnceThenOkClient();
      final events = await FallbackService(emptyThenOk).generate(
        config: AppConfig(),
        apiKey: 'sk-test',
        book: WorldBook(id: 'b_emp', name: '空正文重试', worldview: '背景'),
        history: const <ChapterNode>[],
        playerAction: '推门',
      ).toList();
      expect(events.any((e) => e.kind == GenEventKind.done), isTrue);
      expect(emptyThenOk.receivedSystemPrompts.length, 2);
      expect(
        emptyThenOk.receivedSystemPrompts[0],
        isNot(contains(PromptBuilder.retryNudge(1).trim())),
      );
      expect(
        emptyThenOk.receivedSystemPrompts[1],
        contains('【补充说明】'),
      );
    });
  });
}

class _SingleShotMainClient extends LlmClient {
  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    yield const LlmChunk.content(
      '<date>1949年11月</date>\n\n大军按计划推进。\n\n<choices>\n继续前进\n就地休整\n</choices>',
    );
  }
}

class _SpyAuxCompleteClient extends LlmClient {
  final String response;
  int calls = 0;
  AppConfig? lastConfig;
  String? lastWorkspaceId;
  String? lastApiKey;

  _SpyAuxCompleteClient({this.response = '{}'});

  @override
  Future<String> complete({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
    int maxTokens = 4096,
    double temperature = 0.5,
  }) async {
    calls++;
    lastConfig = config;
    lastWorkspaceId = workspaceId;
    lastApiKey = apiKey;
    return response;
  }
}

class _ControllableStreamClient extends LlmClient {
  final StreamController<LlmChunk> _ctrl = StreamController<LlmChunk>();

  void emit(LlmChunk c) => _ctrl.add(c);

  void fail(Object err) {
    if (!_ctrl.isClosed) {
      _ctrl.addError(err);
      _ctrl.close();
    }
  }

  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) =>
      _ctrl.stream;
}

class _LengthTruncatedThenContinueClient extends LlmClient {
  int _calls = 0;
  String? _finish;

  @override
  String? get lastFinishReason => _finish;

  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    _calls++;
    if (_calls == 1) {
      yield const LlmChunk.thought('第一段思考');
      await Future<void>.delayed(const Duration(milliseconds: 25));
      yield const LlmChunk.content('<date>民国二十六年</date>\n\n城门外的长街静得出奇，');
      _finish = 'length';
      return;
    }
    yield const LlmChunk.thought('第二段续写思考');
    await Future<void>.delayed(const Duration(milliseconds: 25));
    yield const LlmChunk.content(
      '忽然暗巷里转出一名提灯老者。\n\n<choices>\n上前盘问\n暗中尾随\n</choices>',
    );
    _finish = 'stop';
  }
}

class _EmptyOnceThenOkClient extends LlmClient {
  final List<String> receivedSystemPrompts = <String>[];

  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    receivedSystemPrompts.add(messages.first['content'] ?? '');
    if (receivedSystemPrompts.length == 1) {
      return;
    }
    yield const LlmChunk.content('门吱呀一声推开。\n\n<choices>\n走进屋内\n转身离开\n</choices>');
  }
}
