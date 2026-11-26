import 'annotation.dart';
import 'world_state.dart';

/// 一幕推演节点。
class ChapterNode {
  /// 模型原始输出保留上限（按字符计，约 30KB）。
  static const int rawOutputLimit = 30000;

  final int chapterIndex;
  final String title;
  final String content;
  final String? playerAction;
  final String date;
  final List<String> choices;
  final List<GlossaryEntry> glossary;
  final List<CastEntry> cast;
  final DateTime timestamp;

  /// 模型返回的原始文本（未清洗），仅用于排障。
  final String rawOutput;

  /// 这一幕**结束后**的编年史快照。
  final String? chronicleAfter;

  /// 这一幕**结束后**的世界状态快照。
  final WorldState? worldStateAfter;

  /// 模型生成的思维链 / 推演思考过程。
  final String thought;

  /// 本幕深度思考耗时（毫秒，旧存档默认为 0）。
  final int thinkingDurationMs;

  /// 本幕世界状态变更精简微标（如「移至重庆 · 新人物 2」，旧存档默认空）。
  final String stateDiffSummary;

  /// 本幕是否由「主宰模式（最高权限）」推演生成（向下兼容旧存档，默认 false）。
  final bool godMode;

  ChapterNode({
    required this.chapterIndex,
    required this.title,
    required this.content,
    this.playerAction,
    this.date = '',
    List<String>? choices,
    List<GlossaryEntry>? glossary,
    List<CastEntry>? cast,
    this.rawOutput = '',
    this.chronicleAfter,
    this.worldStateAfter,
    this.thought = '',
    this.thinkingDurationMs = 0,
    this.stateDiffSummary = '',
    this.godMode = false,
    DateTime? timestamp,
  })  : choices = choices ?? <String>[],
        glossary = glossary ?? <GlossaryEntry>[],
        cast = cast ?? <CastEntry>[],
        timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => <String, dynamic>{
        'chapterIndex': chapterIndex,
        'title': title,
        'content': content,
        'playerAction': playerAction,
        'date': date,
        'choices': choices,
        'glossary': glossary.map((e) => e.toJson()).toList(),
        'cast': cast.map((e) => e.toJson()).toList(),
        'rawOutput': _capped(rawOutput),
        'chronicleAfter': chronicleAfter,
        'worldStateAfter': worldStateAfter?.toJson(),
        'thought': _capped(thought),
        if (thinkingDurationMs > 0) 'thinkingDurationMs': thinkingDurationMs,
        if (stateDiffSummary.isNotEmpty) 'stateDiffSummary': stateDiffSummary,
        if (godMode) 'godMode': true,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChapterNode.fromJson(Map<String, dynamic> json) => ChapterNode(
        chapterIndex: (json['chapterIndex'] as num?)?.toInt() ?? 1,
        title: (json['title'] ?? '').toString(),
        content: (json['content'] ?? '').toString(),
        playerAction: json['playerAction']?.toString(),
        date: (json['date'] ?? '').toString(),
        choices: (json['choices'] as List<dynamic>?)
                ?.map((e) => e.toString())
                .toList() ??
            <String>[],
        glossary: (json['glossary'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((e) => GlossaryEntry.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            <GlossaryEntry>[],
        cast: (json['cast'] as List<dynamic>?)
                ?.whereType<Map>()
                .map((e) => CastEntry.fromJson(Map<String, dynamic>.from(e)))
                .toList() ??
            <CastEntry>[],
        rawOutput: (json['rawOutput'] ?? '').toString(),
        chronicleAfter: json['chronicleAfter']?.toString(),
        worldStateAfter: json['worldStateAfter'] is Map
            ? WorldState.fromJson(
                Map<String, dynamic>.from(json['worldStateAfter'] as Map),
              )
            : null,
        thought: (json['thought'] ?? '').toString(),
        thinkingDurationMs:
            (json['thinkingDurationMs'] as num?)?.toInt() ?? 0,
        stateDiffSummary: (json['stateDiffSummary'] ?? '').toString(),
        godMode: json['godMode'] == true,
        timestamp: DateTime.tryParse((json['timestamp'] ?? '').toString()),
      );

  ChapterNode copyWith({
    String? content,
    List<String>? choices,
    String? date,
    List<GlossaryEntry>? glossary,
    List<CastEntry>? cast,
    String? chronicleAfter,
    WorldState? worldStateAfter,
    String? thought,
    int? thinkingDurationMs,
    String? stateDiffSummary,
    bool? godMode,
  }) =>
      ChapterNode(
        chapterIndex: chapterIndex,
        title: title,
        content: content ?? this.content,
        playerAction: playerAction,
        date: date ?? this.date,
        choices: choices ?? this.choices,
        glossary: glossary ?? this.glossary,
        cast: cast ?? this.cast,
        rawOutput: rawOutput,
        chronicleAfter: chronicleAfter ?? this.chronicleAfter,
        worldStateAfter: worldStateAfter ?? this.worldStateAfter,
        thought: thought ?? this.thought,
        thinkingDurationMs: thinkingDurationMs ?? this.thinkingDurationMs,
        stateDiffSummary: stateDiffSummary ?? this.stateDiffSummary,
        godMode: godMode ?? this.godMode,
        timestamp: timestamp,
      );

  static String _capped(String s) =>
      s.length <= rawOutputLimit ? s : '${s.substring(0, rawOutputLimit)}\n…（已截断）';
}
