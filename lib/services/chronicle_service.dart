import '../models/app_config.dart';
import '../models/chapter_node.dart';
import '../models/world_book.dart';
import 'llm_client.dart';
import 'runtime_log.dart';

/// 编年史滚动摘要（增量、禁思考、异步不阻塞、自动路由后台辅模型）。
class ChronicleService {
  ChronicleService._();

  static const int compressEvery = 5;

  /// 是否到了该压缩的节点。
  static bool shouldCompress(int chapterCount) =>
      chapterCount > 0 && chapterCount % compressEvery == 0;

  static const String _instruction = '''
你是历史推演的档案整理员。请把「已有编年史」与「新增推演记录」合并压缩为一份精炼的「前情编年史」。

要求：
1. 按时间顺序列出已发生的关键事实：时间、地点、人物、关键抉择与已成事实的后果。
2. 只保留对后续推演有长期约束力的事实，不要抒情、不要评论、不要预测未来。
3. 保持人称一致（以主角视角记录），严禁出现“玩家”“回合”“系统”等出戏词。
4. 控制在 450 字以内，用短句分行。
5. 直接输出编年史正文，不要任何标题、前后缀说明或 XML 标签。''';

  /// 增量压缩出一段新的编年史摘要。失败时安全返回原摘要，不影响主线。
  static Future<String> compress({
    required AppConfig config,
    required String apiKey,
    required WorldBook book,
    required String previousChronicle,
    required List<ChapterNode> history,
    String? workspaceId,
    LlmClient? client,
  }) async {
    if (history.isEmpty) return previousChronicle;

    final auxConfig = config.resolveAuxConfig();
    // 严格以 auxConfig.workspaceId 为唯一真源（非 bailian 厂商或跨厂商未配置时恒为空串），
    // 严禁将主配置的 workspaceId 跨厂商污染到辅模型 URL。
    final effectiveWs = auxConfig.apiProvider == 'bailian'
        ? auxConfig.workspaceId.trim()
        : '';

    final llm = client ?? LlmClient();
    try {
      final hasPrev = previousChronicle.trim().isNotEmpty;
      final sliceCount = hasPrev ? compressEvery : 10;
      final recent = history.length > sliceCount
          ? history.sublist(history.length - sliceCount)
          : history;

      final transcript = StringBuffer();
      if (hasPrev) {
        transcript.writeln('【已有编年史】');
        transcript.writeln(previousChronicle.trim());
        transcript.writeln();
      }
      transcript.writeln('【新增记录】');
      for (final node in recent) {
        if (node.date.trim().isNotEmpty) {
          transcript.writeln('时间：${node.date.trim()}');
        }
        final act = node.playerAction;
        if (act != null && act.trim().isNotEmpty) {
          transcript.writeln('决定：${act.trim()}');
        }
        final body = node.content.trim();
        if (body.isNotEmpty) {
          transcript.writeln(
            '结果：${body.length > 500 ? '${body.substring(0, 500)}…' : body}',
          );
        }
        transcript.writeln('---');
      }

      final messages = <Map<String, String>>[
        <String, String>{'role': 'system', 'content': _instruction},
        <String, String>{
          'role': 'user',
          'content': '世界书名：${book.name}\n\n${transcript.toString()}',
        },
      ];

      final out = (await llm.complete(
        config: auxConfig,
        apiKey: apiKey,
        messages: messages,
        workspaceId: effectiveWs,
        maxTokens: 1024,
        temperature: 0.3,
      ))
          .trim();

      if (out.isEmpty) return previousChronicle;
      RuntimeLog.i('Chronicle', '编年史增量压缩完成（${out.length} 字）');
      return out;
    } catch (e) {
      RuntimeLog.w('Chronicle', '编年史压缩跳过（不影响主线）：$e');
      return previousChronicle;
    }
  }
}
