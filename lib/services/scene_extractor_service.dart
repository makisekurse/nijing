import 'dart:convert';

import '../models/annotation.dart';
import '../models/app_config.dart';
import '../models/world_book.dart';
import '../models/world_state.dart';
import 'llm_client.dart';
import 'runtime_log.dart';
import 'world_state_service.dart';

/// 后台档案官单幕增量提取结果。
class SceneExtractionResult {
  final String date;
  final WorldState stateDelta;
  final List<GlossaryEntry> glossary;
  final List<CastEntry> cast;
  final String diffSummary;

  const SceneExtractionResult({
    this.date = '',
    required this.stateDelta,
    this.glossary = const <GlossaryEntry>[],
    this.cast = const <CastEntry>[],
    this.diffSummary = '',
  });

  bool get isEmpty =>
      date.isEmpty &&
      stateDelta.isEmpty &&
      glossary.isEmpty &&
      cast.isEmpty;
}

/// 后台异步档案官（主辅双模型解耦管线核心）。
///
/// 职责：在主模型写完故事正文并立即呈现给读者之后，于后台静默完成状态、人物、词条更新：
/// 1. **成本极低**：仅送入「当前精简 WorldState（<400字）+ 本幕正文（~1200字）」，不重发世界书与历史全文；
/// 2. **零阻塞、零风险**：优先走用户配置的便宜快速辅助模型（如 `qwen3.8-flash` / `deepseek-flash`）；
///    若未配置辅助模型则自动复用主模型并强制关闭 Thinking；任何失败均静默跳过，绝不破坏正文；
/// 3. **产出可视化变更摘要**：生成精炼 `diffSummary`（如 `地点更新 · 事实+1 · 新人物 2`）供幕底徽标展示。
class SceneExtractorService {
  SceneExtractorService._();

  static const String _instruction = '''
你是情境推演的后台档案整理官。请根据「当前世界状态」与「本幕最新剧情」，只输出一个合法 JSON 对象（不要 markdown 代码块，不要解释），用于增量更新世界档案：

{
  "date": "若本幕明确提到新的剧中日期与时段则填写，否则留空字符串",
  "time": "此刻的剧中时间（无变化可沿用或留空）",
  "location": "主角此刻所在地点（无变化可沿用或留空）",
  "facts": ["当前依然成立的核心事实列表（完整列表，按重要性排序，最多 12 条，每条不超过 80 字）"],
  "relations": {"人物姓名": "此刻与主角的关系或态度（只写本幕新增或发生变化的人物）"},
  "events": ["此刻仍在进行中的未决事件列表（完整列表，最多 8 条）"],
  "newCast": [{"name": "本幕首次出场的新人物名", "role": "身份职务", "stance": "当前立场"}],
  "newGlossary": [{"term": "本幕出现的生僻/专有词条", "explanation": "一句话解释"}]
}

要求：
1. 严格客观，只记录本幕明确发生的事实，严禁编造或剧透未来。
2. 没有新增人物或词条时，对应数组返回 []。
3. 严禁出现“玩家”“回合”“系统”等出戏词汇。''';

  static Future<SceneExtractionResult?> extract({
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required WorldState previousState,
    required String chapterBody,
    String playerAction = '',
    bool godMode = false,
    String? workspaceId,
    LlmClient? client,
  }) async {
    if (chapterBody.trim().isEmpty) return null;

    final auxConfig = config.resolveAuxConfig();
    final effectiveWs = auxConfig.workspaceId.trim().isNotEmpty
        ? auxConfig.workspaceId.trim()
        : workspaceId;

    final llm = client ?? LlmClient();
    try {
      final prevRendered = WorldStateService.renderForPrompt(previousState);
      final userBuf = StringBuffer()
        ..writeln('世界：${book.name}');
      if (book.stateDimensions.trim().isNotEmpty) {
        userBuf.writeln('重点维度：${book.stateDimensions.trim()}');
      }
      if (prevRendered.isNotEmpty) {
        userBuf
          ..writeln()
          ..writeln('【上一幕世界状态】')
          ..writeln(prevRendered);
      }
      if (playerAction.trim().isNotEmpty) {
        userBuf
          ..writeln()
          ..writeln(
            godMode
                ? '【本幕主宰意志（必须视为既成事实）】${playerAction.trim()}'
                : '【本幕主角行动】${playerAction.trim()}',
          );
      }
      final trimmedBody = chapterBody.trim();
      userBuf
        ..writeln()
        ..writeln('【本幕最新剧情】')
        ..writeln(
          trimmedBody.length > 3200
              ? '${trimmedBody.substring(0, 3200)}…'
              : trimmedBody,
        );

      final raw = await llm.complete(
        config: auxConfig,
        apiKey: apiKey,
        messages: <Map<String, String>>[
          <String, String>{'role': 'system', 'content': _instruction},
          <String, String>{'role': 'user', 'content': userBuf.toString()},
        ],
        workspaceId: effectiveWs,
        maxTokens: 1024,
        temperature: 0.2,
      );

      final parsed = parseExtractionJson(raw, previousState: previousState);
      if (parsed == null || parsed.isEmpty) return null;
      RuntimeLog.i(
        'SceneExtractor',
        '后台状态提取完成（model=${auxConfig.modelName} · ${parsed.diffSummary}）',
      );
      return parsed;
    } catch (e) {
      RuntimeLog.w('SceneExtractor', '后台状态提取跳过（不影响正文）：$e');
      return null;
    }
  }

  /// 纯函数 JSON 解析（便于单元测试，高度宽容各种模型输出变体）。
  static SceneExtractionResult? parseExtractionJson(
    String raw, {
    WorldState? previousState,
  }) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();

    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    text = text.substring(start, end + 1);

    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);

    final state = WorldState(
      time: (map['time'] ?? '').toString().trim(),
      location: (map['location'] ?? '').toString().trim(),
      facts: _strList(map['facts']),
      relations: _strMap(map['relations']),
      events: _strList(map['events']),
    );

    final cast = <CastEntry>[];
    if (map['newCast'] is List) {
      for (final item in map['newCast'] as List<dynamic>) {
        if (item is Map) {
          final name = (item['name'] ?? '').toString().trim();
          if (name.isEmpty) continue;
          cast.add(CastEntry(
            name: name,
            role: (item['role'] ?? '').toString().trim(),
            stance: (item['stance'] ?? '').toString().trim(),
          ));
        }
      }
    }

    final glossary = <GlossaryEntry>[];
    if (map['newGlossary'] is List) {
      for (final item in map['newGlossary'] as List<dynamic>) {
        if (item is Map) {
          final term = (item['term'] ?? '').toString().trim();
          final exp = (item['explanation'] ?? '').toString().trim();
          if (term.isEmpty || exp.isEmpty) continue;
          glossary.add(GlossaryEntry(term: term, explanation: exp));
        }
      }
    }

    final diffParts = <String>[];
    final prev = previousState ?? WorldState();
    if (state.location.isNotEmpty && state.location != prev.location) {
      diffParts.add('移至${state.location}');
    }
    if (state.relations.isNotEmpty) {
      diffParts.add('关系+${state.relations.length}');
    }
    if (cast.isNotEmpty) {
      diffParts.add('新人物 ${cast.length}');
    }
    final newFacts =
        state.facts.where((f) => !prev.facts.contains(f)).length;
    if (newFacts > 0) {
      diffParts.add('局势+$newFacts');
    } else if (state.events.isNotEmpty &&
        state.events.any((e) => !prev.events.contains(e))) {
      diffParts.add('事件更新');
    }

    return SceneExtractionResult(
      date: (map['date'] ?? '').toString().trim(),
      stateDelta: state,
      glossary: glossary,
      cast: cast,
      diffSummary: diffParts.isEmpty ? '档案已同步' : diffParts.take(2).join(' · '),
    );
  }

  static List<String> _strList(Object? v) {
    if (v is! List) return <String>[];
    return v
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  static Map<String, String> _strMap(Object? v) {
    if (v is! Map) return <String, String>{};
    final out = <String, String>{};
    v.forEach((k, val) {
      final ks = k.toString().trim();
      final vs = val?.toString().trim() ?? '';
      if (ks.isNotEmpty && vs.isNotEmpty) out[ks] = vs;
    });
    return out;
  }
}
