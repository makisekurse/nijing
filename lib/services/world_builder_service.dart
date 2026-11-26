import 'dart:convert';

import '../core/app_error.dart';
import '../models/app_config.dart';
import '../models/world_book.dart';
import 'llm_client.dart';
import 'runtime_log.dart';

/// AI 快速创建世界书结果，明确区分成功与真实错误原因。
class WorldBuildResult {
  final WorldBook? book;
  final String? error;

  const WorldBuildResult.ok(this.book) : error = null;
  const WorldBuildResult.fail(this.error) : book = null;

  bool get isSuccess => book != null;
}

/// 用一句自然语言描述生成一本世界书。
///
/// 关键约定：
/// - **非流式**调用（自动关闭思考并剥离残余 `<think>`）；
/// - 透出真实服务端报错与解析错误，绝不静默吞异常；
/// - 生成结果不直接落库，先给用户预览编辑后再保存。
class WorldBuilderService {
  WorldBuilderService._();

  static const String _system = '''
你是一个世界设定助手。用户会用一句话描述他想进入的世界，
你要把它扩写成一份结构化的世界书。

严格要求：
1. 只输出一个 JSON 对象，不要任何解释、不要 markdown 代码块围栏。
2. 字段固定为：
   name           世界书名（不超过 16 字）
   era            时代与时间跨度
   worldview      世界观与背景设定（150~300 字，写清局势、主要矛盾、制度与地理环境）
   playerRole     用户扮演的人物（身份、职务、年龄、性格、立场）
   playerGoal     玩家目标（这一局想做什么）
   narrativeStyle 叙事文风（具体到笔法，例如「白描为主，多用公文语气」）
   extraRules     世界规则与禁忌
   keyCharacters  关键人物（每行一条：姓名 | 身份 | 立场；3~5 条）
   keyFactions    关键势力（每行一条：名称 | 诉求 | 与主角的关系；2~4 条）
   keyLocations   关键地点（每行一条：地名 | 意义；2~4 条）
   openingScene   开篇场景（200~350 字，直接进入情境，不要写"故事发生在"这类开场白）
   openingChoices 开篇分支（字符串数组，2~3 条，每条是可立即执行的具体行动）
   stateDimensions 状态维度模板（一句话，说明这份设定里该重点盯住哪些状态）
3. 如果用户描述里没提到的，你按最合理的想象补全，不要反问、不要留空。
4. 用中文输出。''';

  /// 生成世界书并返回详细结果（含真实错误原因）。
  static Future<WorldBuildResult> buildWithResult({
    required AppConfig config,
    required String apiKey,
    required String description,
    String? workspaceId,
    LlmClient? client,
  }) async {
    if (description.trim().isEmpty) {
      return const WorldBuildResult.fail('请先写一句你想进入的世界。');
    }

    try {
      final raw = await (client ?? LlmClient()).complete(
        config: config,
        apiKey: apiKey,
        messages: <Map<String, String>>[
          <String, String>{'role': 'system', 'content': _system},
          <String, String>{
            'role': 'user',
            'content': '我想进入的世界：${description.trim()}',
          },
        ],
        workspaceId: workspaceId,
        maxTokens: 3000,
        temperature: 0.7,
      );

      final map = _extractJson(raw);
      if (map == null) {
        RuntimeLog.w('WorldBuilder', '未能从模型返回中解析出 JSON：$raw');
        return const WorldBuildResult.fail(
          '模型返回的内容不是有效的世界书 JSON 格式，请重试或换一个模型。',
        );
      }

      final book = WorldBook.fromJson(map);
      if (book.name.trim().isEmpty) {
        book.name = description.trim().length > 16
            ? description.trim().substring(0, 16)
            : description.trim();
      }
      return WorldBuildResult.ok(book);
    } on AppError catch (e) {
      RuntimeLog.e('WorldBuilder', '生成世界书失败：${e.message}');
      return WorldBuildResult.fail(e.message);
    } catch (e) {
      RuntimeLog.e('WorldBuilder', '生成世界书异常：$e');
      return WorldBuildResult.fail('生成世界书失败：$e');
    }
  }

  /// 兼容旧签名：失败返回 null。
  static Future<WorldBook?> build({
    required AppConfig config,
    required String apiKey,
    required String description,
    String? workspaceId,
  }) async {
    final res = await buildWithResult(
      config: config,
      apiKey: apiKey,
      description: description,
      workspaceId: workspaceId,
    );
    return res.book;
  }

  static Map<String, dynamic>? _extractJson(String raw) {
    var text = raw.trim();

    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();

    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    text = text.substring(start, end + 1);

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }
    return null;
  }
}
