import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nijing/core/app_error.dart';
import 'package:nijing/data/prefs_store.dart';
import 'package:nijing/models/app_config.dart';
import 'package:nijing/models/chapter_node.dart';
import 'package:nijing/models/save_slot.dart';
import 'package:nijing/models/world_book.dart';
import 'package:nijing/services/chronicle_service.dart';
import 'package:nijing/services/game_session.dart';
import 'package:nijing/services/generation_controller.dart';
import 'package:nijing/services/llm_client.dart';
import 'package:nijing/services/providers.dart';
import 'package:nijing/services/response_parser.dart';
import 'package:nijing/services/save_service.dart';
import 'package:nijing/services/world_builder_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('原生双轨流分流（InlineThinkSplitter & parseChannels）', () {
    test('跨分片截断 <think> 与 </think> 标签时精准隔离且零泄漏', () {
      final splitter = InlineThinkSplitter();
      final inputs = <String>[
        '<thi',
        'nk>先构思一下<date>1950年</date>\n---\n不要反转</th',
        'ink>\n<date>1950年春</date>\n细雨落在青石板上。',
      ];
      final thoughts = StringBuffer();
      final contents = StringBuffer();

      for (final piece in inputs) {
        for (final c in splitter.feed(piece)) {
          if (c.isThought) {
            thoughts.write(c.text);
          } else {
            contents.write(c.text);
          }
        }
      }
      for (final c in splitter.flush()) {
        if (c.isThought) {
          thoughts.write(c.text);
        } else {
          contents.write(c.text);
        }
      }

      expect(thoughts.toString(), contains('先构思一下'));
      expect(thoughts.toString(), contains('<date>1950年</date>'));
      expect(contents.toString(), isNot(contains('先构思一下')));
      expect(contents.toString(), contains('<date>1950年春</date>'));
      expect(contents.toString(), contains('细雨落在青石板上。'));
    });

    test('ResponseParser.parseChannels · 原生双轨下思考中含 </think> 与结构标签绝不污染正文', () {
      const thought = '思考：一会儿用 </think> 结束，然后输出 <date>错误日期</date> 和 <choices>假选项</choices>。';
      const content = '''
<date>贞观三年秋</date>

长安朱雀大街落叶纷飞，巡城金吾卫按刀而行。

<choices>
1. 径直入宫面圣陈情
2. 先访房玄龄商议对策
</choices>
''';
      final parsed = ResponseParser.parseChannels(
        content: content,
        thought: thought,
      );
      expect(parsed.date, '贞观三年秋');
      expect(parsed.body, '长安朱雀大街落叶纷飞，巡城金吾卫按刀而行。');
      expect(parsed.thought, contains('思考：一会儿用'));
      expect(parsed.choices.length, 2);
      expect(parsed.choices.first, '径直入宫面圣陈情');
    });

    test('ResponseParser.previewBody · 流式正文实时剥离结构标签与尾部半截标签', () {
      const liveContent = '<date>民国二十五年</date>\n\n北平的秋风卷起枯叶。\n\n<choic';
      expect(ResponseParser.previewBody(liveContent), '北平的秋风卷起枯叶。');
    });
  });

  group('网络错误分类、Token 策略与多服务商配置', () {
    test('AppError 精准区分 400/404(badRequest) 与 401/403(auth) 与可重试网络错', () {
      final e400 = AppError.fromStatus(400, '{"error":{"message":"invalid model"}}');
      expect(e400.kind, AppErrorKind.badRequest);
      expect(e400.isConfigError, isTrue);
      expect(e400.retryable, isFalse);
      expect(e400.message, contains('invalid model'));

      final e404 = AppError.fromStatus(404, '{"message":"Not Found"}');
      expect(e404.kind, AppErrorKind.badRequest);
      expect(e404.isConfigError, isTrue);

      final e401 = AppError.fromStatus(401, '{"message":"bad key"}');
      expect(e401.kind, AppErrorKind.auth);
      expect(e401.isConfigError, isTrue);

      final e503 = AppError.fromStatus(503, 'upstream unavailable');
      expect(e503.kind, AppErrorKind.server);
      expect(e503.retryable, isTrue);
    });

    test('calculateMaxTokens 彻底解除 qwen-plus/deepseek 截断锁死，支持思考预算扩容', () {
      // qwen-plus / deepseek-chat 不再锁死在 2000 / 4096
      expect(
        LlmClient.calculateMaxTokens(2000, modelName: 'qwen-plus'),
        greaterThanOrEqualTo(6000),
      );
      expect(
        LlmClient.calculateMaxTokens(2000, modelName: 'deepseek-chat', provider: 'deepseek'),
        greaterThanOrEqualTo(6000),
      );
      // deepseek-reasoner 原生推理模型自动给到 16384+
      expect(
        LlmClient.calculateMaxTokens(1500, modelName: 'deepseek-reasoner', provider: 'deepseek'),
        greaterThanOrEqualTo(16384),
      );
      // 自定义 thinkingBudget=8192 + maxWords=2000 => 至少 14192
      expect(
        LlmClient.calculateMaxTokens(
          2000,
          modelName: 'qwen3-235b-a22b',
          enableThinking: true,
          thinkingBudget: 8192,
        ),
        greaterThanOrEqualTo(14192),
      );
    });

    test('AppConfig.workspaceId 统一收口并被 Providers 自动读取', () {
      final cfg = AppConfig(apiProvider: 'bailian', workspaceId: 'ws-bj-001');
      final restored = AppConfig.fromJson(cfg.toJson());
      expect(restored.workspaceId, 'ws-bj-001');
      expect(
        Providers.chatCompletionsUrl(restored),
        'https://ws-bj-001.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions',
      );
    });
  });

  group('编年史增量压缩与 WorldBuilder 错误透出', () {
    test('ChronicleService 使用非流式 complete 且仅增量发送最近 5 幕（绝不污染思考链）', () async {
      final fakeClient = _FakeCompleteClient(
        responseText: '1950年春，主角稳住局势并完成整合。',
      );
      final history = List<ChapterNode>.generate(
        10,
        (i) => ChapterNode(
          chapterIndex: i + 1,
          title: '第 ${i + 1} 幕',
          content: '第${i + 1}幕独特剧情内容_MARKER_${(i + 1).toString().padLeft(2, '0')}',
          playerAction: '行动_${i + 1}',
          date: '1950年${i + 1}月',
        ),
      );

      final result = await ChronicleService.compress(
        config: AppConfig(enableThinking: true),
        apiKey: 'sk-test',
        book: WorldBook(id: 'b1', name: '测试世界', worldview: '背景', playerRole: '主角'),
        previousChronicle: '旧编年史：前五幕大事记。',
        history: history,
        client: fakeClient,
      );

      expect(result, '1950年春，主角稳住局势并完成整合。');
      expect(fakeClient.completeCalls, 1);
      final userMsg = fakeClient.lastMessages!.last['content']!;
      expect(userMsg, contains('旧编年史：前五幕大事记。'));
      // 增量压缩只带最近 5 幕（第 6~10 幕），不重传第 1~5 幕
      expect(userMsg, isNot(contains('MARKER_01')));
      expect(userMsg, isNot(contains('MARKER_05')));
      expect(userMsg, contains('MARKER_06'));
      expect(userMsg, contains('MARKER_10'));
    });

    test('WorldBuilderService.buildWithResult 透出真实服务端报错而非静默吞错', () async {
      final errClient = _FakeCompleteClient(
        errorToThrow: AppError.fromStatus(
          401,
          '{"error":{"message":"Invalid API key provided"}}',
        ),
      );
      final res = await WorldBuilderService.buildWithResult(
        config: AppConfig(),
        apiKey: 'sk-wrong',
        description: '我想在唐朝长安做一名不良帅',
        client: errClient,
      );

      expect(res.isSuccess, isFalse);
      expect(res.book, isNull);
      expect(res.error, contains('Invalid API key provided'));
    });
  });

  group('分槽独立文件存档（SaveService 原子写 + 坏档隔离 + 旧数据迁移）', () {
    late Directory tempDir;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tempDir = await Directory.systemTemp.createTemp('nijing_save_test_');
      SaveService.testStorageDirectory = tempDir;
      SaveService.resetCacheForTest();
    });

    tearDown(() async {
      SaveService.testStorageDirectory = null;
      SaveService.resetCacheForTest();
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('多槽位独立 JSON 文件读写、单槽更新与删除互不干扰', () async {
      final book = WorldBook(id: 'w1', name: '江南烟雨', worldview: '背景', playerRole: '主角');
      final slot1 = SaveSlot(id: 'slot_a', title: '局 A', worldBook: book);
      final slot2 = SaveSlot(id: 'slot_b', title: '局 B', worldBook: book);

      await SaveService.upsert(slot1);
      await SaveService.upsert(slot2);

      final files = tempDir.listSync().whereType<File>().toList();
      expect(files.length, 2);

      final loaded = await SaveService.loadAll();
      expect(loaded.length, 2);
      expect(loaded.map((s) => s.id), containsAll(<String>['slot_a', 'slot_b']));

      await SaveService.delete('slot_a');
      final afterDelete = await SaveService.loadAll();
      expect(afterDelete.length, 1);
      expect(afterDelete.first.id, 'slot_b');
    });

    test('坏档隔离：某个存档文件损坏时，其他存档仍完好可读', () async {
      final book = WorldBook(id: 'w2', name: '塞北风云', worldview: '背景', playerRole: '主角');
      await SaveService.upsert(SaveSlot(id: 'good_slot', title: '完好存档', worldBook: book));

      // 人为写入一个损坏的槽位文件
      final broken = File('${tempDir.path}${Platform.pathSeparator}slot_broken.json');
      await broken.writeAsString('{corrupted json!!!', flush: true);

      final loaded = await SaveService.loadAll();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'good_slot');
    });

    test('无缝自动迁移旧版 SharedPreferences 存档到独立文件', () async {
      await PrefsStore.remove('nijing_saves_file_migrated_v2');
      final book = WorldBook(id: 'w3', name: '旧档世界', worldview: '背景', playerRole: '主角');
      final legacySlot = SaveSlot(id: 'legacy_01', title: '旧存档', worldBook: book);
      await PrefsStore.setString(
        'nijing_saves_v1',
        jsonEncode(<Map<String, dynamic>>[legacySlot.toJson()]),
      );

      final loaded = await SaveService.loadAll();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'legacy_01');
      final migratedFile = File('${tempDir.path}${Platform.pathSeparator}slot_legacy_01.json');
      expect(migratedFile.existsSync(), isTrue);
    });
  });

  group('GenerationController 双轨隔离与重开防串档', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      GenerationController.resetAll();
    });

    tearDown(() {
      GenerationController.resetAll();
    });

    test('双轨推送时 liveThought 与 liveBodyPreview 彻底隔离并成功落盘', () async {
      final book = WorldBook(id: 'b_dual', name: '双轨世界', worldview: '背景', playerRole: '主角');
      final slot = SaveSlot(id: 'slot_dual', title: '双轨局', worldBook: book);
      final session = GameSession(slot);
      final client = _DualTrackMockClient();
      final ctrl = GenerationController.forSlot('slot_dual', client: client);

      await ctrl.startGeneration(
        session: session,
        config: AppConfig(),
        apiKey: 'sk-dual',
        action: '推开大门',
        book: book,
      );

      expect(ctrl.status, GenerationStatus.completed);
      expect(session.history.length, 1);
      expect(session.history.first.thought, contains('内部构思：制造紧张感'));
      expect(session.history.first.content, isNot(contains('内部构思')));
      expect(session.history.first.content, contains('寒风扑面而来'));
      expect(session.history.first.date, '永乐元年冬');
      expect(session.choices.length, 2);

      // 重开清缓存：disposeSlot 后旧 session 绝不残留
      GenerationController.disposeSlot('slot_dual');
      final freshCtrl = GenerationController.forSlot('slot_dual');
      expect(freshCtrl.session, isNull);
    });
  });
}

class _FakeCompleteClient extends LlmClient {
  final String? responseText;
  final Object? errorToThrow;
  int completeCalls = 0;
  List<Map<String, String>>? lastMessages;

  _FakeCompleteClient({this.responseText, this.errorToThrow});

  @override
  Future<String> complete({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
    int maxTokens = 4096,
    double temperature = 0.5,
  }) async {
    completeCalls++;
    lastMessages = messages;
    if (errorToThrow != null) throw errorToThrow!;
    return responseText ?? '';
  }
}

class _DualTrackMockClient extends LlmClient {
  @override
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    yield const LlmChunk.thought('内部构思：制造紧张感，<date>草稿日期</date>');
    yield const LlmChunk.content('<date>永乐元年冬</date>\n\n寒风扑面而来，院内灯火微明。');
    yield const LlmChunk.content('\n\n<choices>\n1. 迈步走入正厅\n2. 绕道后院查探\n</choices>');
  }
}
