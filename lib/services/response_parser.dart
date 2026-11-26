import 'dart:math' as math;

import '../models/annotation.dart';
import 'runtime_log.dart';

/// 一幕输出的结构化解析结果。
class ParsedChapter {
  /// 去掉所有结构块之后的纯正文。
  final String body;

  /// 剧中日期（模型用 `<date>` 给出，可缺）。
  final String date;

  final List<String> choices;
  final List<GlossaryEntry> glossary;
  final List<CastEntry> cast;

  /// `<state>` 块的原文，交给 WorldState 服务去解析。
  final String stateRaw;

  /// 模型生成的思维链 / 推演思考内容。
  final String thought;

  /// 模型返回的原始文本（仅用于排障）。
  final String rawOutput;

  const ParsedChapter({
    required this.body,
    this.date = '',
    this.choices = const <String>[],
    this.glossary = const <GlossaryEntry>[],
    this.cast = const <CastEntry>[],
    this.stateRaw = '',
    this.thought = '',
    this.rawOutput = '',
  });

  /// 分支是否够用 —— 至少两条。
  bool get hasUsableChoices => choices.length >= 2;
}

/// 模型输出解析器（双轨精简重构版）。
///
/// 架构原则：
/// - 思考通道与正文通道已在 `LlmClient.streamChunks` 网络层物理隔离；
/// - [parseChannels] 直接接收分离后的 `content` 与 `thought`，零猜测、零泄漏；
/// - [previewBody] 专用于流式正文实时渲染，只剥离结构标签与尾部半截标签，开销极低；
/// - 保留 [parse] / [splitLive] 兼容单文本输入与既有回归用例。
class ResponseParser {
  ResponseParser._();

  static const List<String> knownTags = <String>[
    'date',
    'choices',
    'glossary',
    'cast',
    'state',
    'think',
    'thought',
  ];

  static const String _tagAlt = '(date|choices|glossary|cast|state|think|thought)';
  static const String _structuralTagAlt = '(date|choices|glossary|cast|state)';

  /// 宽容的开标签：`<cast>` `< cast >` `＜cast＞` `《cast》` `<Cast>`
  static final RegExp _openTag = RegExp(
    r'[<＜《]\s*' + _tagAlt + r'\s*[>＞》]',
    caseSensitive: false,
  );

  /// 宽容的闭标签：`</cast>` `</cast >` `＜/cast＞` `《/cast》` `</Cast>`
  static final RegExp _closeTag = RegExp(
    r'[<＜《]\s*/\s*' + _tagAlt + r'\s*[>＞》]',
    caseSensitive: false,
  );

  static final RegExp _structuralOpenTag = RegExp(
    r'[<＜《]\s*' + _structuralTagAlt + r'\s*[>＞》]',
    caseSensitive: false,
  );

  static final RegExp _explicitTransition = RegExp(
    r'(?:(?:\r?\n)+|^\s*)(?:【正文】|（正文）|正文[：:]|正式推演[：:]|现在开始[：:]|剧情推演[：:]|---\s*(?:\r?\n)+)',
    caseSensitive: false,
  );

  /// 双轨结构化解析（主入口）：直接消费分离的 [content] 与 [thought]。
  static ParsedChapter parseChannels({
    required String content,
    String thought = '',
    String? rawOutput,
  }) {
    final normalizedRaw = rawOutput ??
        (thought.trim().isEmpty
            ? content
            : '<think>\n${thought.trim()}\n</think>\n\n$content');

    if (content.trim().isEmpty && thought.trim().isEmpty) {
      return ParsedChapter(body: '', rawOutput: normalizedRaw);
    }

    final parsedContent = parse(content);
    final externalThought = cleanThoughtForShow(thought);
    final mergedThought = <String>[
      if (externalThought.isNotEmpty) externalThought,
      if (parsedContent.thought.isNotEmpty) parsedContent.thought,
    ].join('\n\n');

    return ParsedChapter(
      body: parsedContent.body,
      date: parsedContent.date,
      choices: parsedContent.choices,
      glossary: parsedContent.glossary,
      cast: parsedContent.cast,
      stateRaw: parsedContent.stateRaw,
      thought: mergedThought,
      rawOutput: normalizedRaw,
    );
  }

  /// 单字符串完整解析（兼容旧数据、残文与单文本输入）。
  static ParsedChapter parse(String raw) {
    if (raw.trim().isEmpty) {
      return const ParsedChapter(body: '', rawOutput: '');
    }

    final blocks = _scanBlocks(raw, isLive: false);

    final choices = <String>[];
    final glossary = <GlossaryEntry>[];
    final cast = <CastEntry>[];
    var date = '';
    var stateRaw = '';
    var thought = '';

    for (final b in blocks) {
      switch (b.tag) {
        case 'date':
          if (date.isEmpty) date = b.inner.trim();
          break;
        case 'choices':
          choices.addAll(_splitItems(b.inner, _cleanChoice));
          break;
        case 'glossary':
          glossary.addAll(
            _splitItems(b.inner, (l) => l)
                .map(GlossaryEntry.parseLine)
                .whereType<GlossaryEntry>(),
          );
          break;
        case 'cast':
          cast.addAll(
            _splitItems(b.inner, (l) => l)
                .map(CastEntry.parseLine)
                .whereType<CastEntry>(),
          );
          break;
        case 'state':
          stateRaw = b.inner.trim();
          break;
        case 'think':
        case 'thought':
          final t = _cleanThought(b.inner);
          if (t.isNotEmpty) {
            thought = thought.isEmpty ? t : '$thought\n\n$t';
          }
          break;
      }
    }

    return ParsedChapter(
      body: _rebuildBody(raw, blocks),
      date: date,
      choices: choices,
      glossary: glossary,
      cast: cast,
      stateRaw: stateRaw,
      thought: thought,
      rawOutput: raw,
    );
  }

  /// 流式正文极速预览：只处理纯正文通道（[liveContent]），剔除结构块与尾部半截标签。
  static String previewBody(String liveContent) {
    if (liveContent.isEmpty) return '';
    final blocks = _scanBlocks(liveContent, isLive: true);
    final rawBody = _removeBlockSpans(liveContent, blocks);
    return _finishBody(rawBody);
  }

  /// 兼容单字符串流式预览：返回 `(thought, body)`。
  /// 未闭合的 `<think>` 在流式期间 100% 留在 `thought`，绝不向正文区泄漏。
  static (String thought, String body) splitLive(String raw) {
    if (raw.isEmpty) return ('', '');
    final blocks = _scanBlocks(raw, isLive: true);
    final thought = StringBuffer();
    final body = StringBuffer();
    var cursor = 0;

    for (final b in blocks) {
      if (b.start > cursor) body.write(raw.substring(cursor, b.start));
      cursor = b.end;
      if (b.tag == 'think' || b.tag == 'thought') {
        final t = b.inner.trim();
        if (t.isNotEmpty) {
          if (thought.isNotEmpty) thought.write('\n\n');
          thought.write(t);
        }
      }
    }
    if (cursor < raw.length) body.write(raw.substring(cursor));

    return (thought.toString().trim(), _finishBody(body.toString()));
  }

  static String _finishBody(String text) {
    final cleaned = text
        .split('\n')
        .where((l) => !isBodyNoise(l))
        .join('\n')
        .trim();
    var s = cleanBodyPrefix(cleaned);
    final partial = RegExp(r'[<＜《][a-zA-Z/\s]{0,12}$').firstMatch(s);
    if (partial != null) s = s.substring(0, partial.start).trimRight();
    return s;
  }

  static List<_Block> _scanBlocks(String raw, {required bool isLive}) {
    final blocks = <_Block>[];
    var cursor = 0;

    while (cursor < raw.length) {
      final open = _openTag.firstMatch(raw.substring(cursor));
      if (open == null) break;

      final start = cursor + open.start;
      final tag = (open.group(1) ?? '').toLowerCase();
      final contentStart = cursor + open.end;

      var end = raw.length;
      var contentEnd = raw.length;
      final close = _findClose(raw, contentStart, tag);

      if (close != null) {
        end = close.end;
        contentEnd = close.start;
      } else if (tag == 'think' || tag == 'thought') {
        if (isLive) {
          // 流式阶段未闭合 think 严格留在思考区，不泄漏到正文
          end = raw.length;
          contentEnd = raw.length;
        } else {
          // 完整解析时若模型漏写 </think>：优先截断到下一个结构标签或显式转折标识
          final nextStructural =
              _structuralOpenTag.firstMatch(raw.substring(contentStart));
          final limit = nextStructural != null
              ? nextStructural.start
              : raw.length - contentStart;
          final candidate = raw.substring(contentStart, contentStart + limit);
          final trans = _explicitTransition.firstMatch(candidate);
          final cutoff = trans != null ? trans.start : candidate.length;
          end = contentStart + cutoff;
          contentEnd = end;
        }
      } else if (tag == 'date') {
        // <date> 规范只有一行，若模型漏写 </date>，截断到换行或下一结构标签，绝不吞掉正文
        final nextNewline = raw.indexOf('\n', contentStart);
        final nextTag =
            _structuralOpenTag.firstMatch(raw.substring(contentStart));
        var cutoff = raw.length;
        if (nextNewline != -1) cutoff = math.min(cutoff, nextNewline);
        if (nextTag != null) {
          cutoff = math.min(cutoff, contentStart + nextTag.start);
        }
        end = cutoff;
        contentEnd = end;
      } else {
        // choices / glossary / cast / state 若漏闭标签，截断到下一个结构标签处
        final nextTag =
            _structuralOpenTag.firstMatch(raw.substring(contentStart));
        if (nextTag != null) {
          end = contentStart + nextTag.start;
          contentEnd = end;
        }
      }

      blocks.add(_Block(
        tag: tag,
        start: start,
        end: end,
        inner: raw.substring(contentStart, contentEnd),
      ));
      cursor = end;
    }

    RuntimeLog.i(
      'Parser',
      '扫到 ${blocks.length} 个结构块：${blocks.map((b) => b.tag).join(',')}',
      detail: true,
    );
    return blocks;
  }

  static Match? _findClose(String raw, int from, String tag) {
    for (final m in _closeTag.allMatches(raw, from)) {
      if ((m.group(1) ?? '').toLowerCase() == tag) return m;
    }
    return null;
  }

  static String _rebuildBody(String raw, List<_Block> blocks) {
    final text = _removeBlockSpans(raw, blocks);
    final cleaned = text
        .split('\n')
        .where((l) => !isBodyNoise(l))
        .join('\n')
        .trim();
    return cleanBodyPrefix(cleaned);
  }

  static final RegExp _bodyPrefix = RegExp(
    r'^\s*(?:#{1,6}\s*)?'
    r'(?:\*\*)?'
    r'(?:[【\[（(]\s*正文(?:\s*内容|\s*如下|\s*开始|\s*部分)?\s*[】\]）)]'
    r'|正文\s*(?:如下|内容)\s*[:：]?'
    r'|正文\s*开始\s*[:：]'
    r'|正文(?=\s*[:：]|\s*\n|\s*\*\*))'
    r'(?:\*\*)?'
    r'\s*[:：]?'
    r'(?:\*\*)?'
    r'\s*',
  );

  /// 智能清洗正文开头的模板标识残留前缀，确保小说正文纯净。
  static String cleanBodyPrefix(String body) {
    var result = body.trim();
    while (_bodyPrefix.hasMatch(result)) {
      result = result.replaceFirst(_bodyPrefix, '').trim();
    }
    return result;
  }

  static String _removeBlockSpans(String raw, List<_Block> blocks) {
    if (blocks.isEmpty) return raw.trim();
    final sb = StringBuffer();
    var cursor = 0;
    for (final b in blocks) {
      if (b.start > cursor) sb.write(raw.substring(cursor, b.start));
      cursor = b.end;
    }
    if (cursor < raw.length) sb.write(raw.substring(cursor));
    return sb.toString().trim();
  }

  static final List<RegExp> _itemNoise = <RegExp>[
    RegExp(r'^第[一二三四五六七八九十]条\s*可供主角决断的具体行动.*$'),
    RegExp(r'^第[一二三四五六七八九十]条\s*[（(]\s*可选\s*[）)].*$'),
    RegExp(r'^第[一二三四五六七八九十]条\s*行动\s*$'),
    RegExp(r'^第[一二三四五六七八九十]条\s*$'),
    RegExp(r'^[（(]\s*可选\s*[）)]$'),
    RegExp(r'^生僻词条\s*\|.*解释.*$'),
    RegExp(r'^人物姓名\s*\|.*身份.*$'),
    RegExp(r'^词条\s*\|\s*一句话解释\s*$'),
    RegExp(r'^姓名\s*\|\s*身份\s*\|\s*立场\s*$'),
    RegExp(r'^[〈〈].*[〉〉]$'),
    RegExp(r'^[【\[（(]\s*(?:天道敕令|主宰天道敕令).*$'),
  ];

  static final List<RegExp> _bodyNoise = <RegExp>[
    RegExp(r'^[（(]\s*正文\s*[:：].*[）)]$'),
    RegExp(r'^正文\s*[:：]\s*约?\s*\d*\s*字.*$'),
    RegExp(r'^剧中日期\s*[，,：:].*$'),
    RegExp(r'^第[一二三四五六七八九十]条\s*可供主角决断的具体行动.*$'),
    RegExp(r'^第[一二三四五六七八九十]条\s*[（(]\s*可选\s*[）)].*$'),
    RegExp(r'^[【\[（(]\s*(?:天道敕令|主宰天道敕令).*$'),
    RegExp(r'^(?:天道敕令|主宰天道敕令)\s*[:：].*$'),
  ];

  static bool isTemplateNoise(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('<!--') || t.endsWith('-->')) return true;
    return _itemNoise.any((r) => r.hasMatch(t));
  }

  static bool isBodyNoise(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('<!--') || t.endsWith('-->')) return true;
    return _bodyNoise.any((r) => r.hasMatch(t));
  }

  /// 判断一段**正文通道**输出是否为拒答。
  static bool looksLikeRefusal(String raw) {
    final head = raw.trim();
    if (head.isEmpty) return true;
    final probe = head.length > 120 ? head.substring(0, 120) : head;
    const markers = <String>[
      '抱歉',
      '对不起',
      '无法协助',
      '无法提供',
      '不能提供',
      '不便讨论',
      '我无法',
      '我不能',
      '作为一个AI',
      '作为一个 AI',
      '作为人工智能',
      '涉及敏感',
      '违反相关规定',
      '不予生成',
      '换个话题',
    ];
    for (final m in markers) {
      if (probe.contains(m)) return head.length < 400;
    }
    return false;
  }

  static List<String> _splitItems(
    String block,
    String Function(String) clean,
  ) =>
      block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .where((l) => !isTemplateNoise(l))
          .map(clean)
          .where((l) => l.isNotEmpty)
          .where((l) => !isTemplateNoise(l))
          .toList();

  static String _cleanChoice(String line) => line
      .replaceAll(
        RegExp(r'^(\d+[\.、\)）\s]|[-*•·]\s*|选项[一二三四五六123456][：:\.、]?\s*)'),
        '',
      )
      .trim();

  static final RegExp _mdFence = RegExp(r'^[ \t]*```.*$', multiLine: true);
  static final RegExp _mdHeading =
      RegExp(r'^[ \t]{0,3}#{1,6}[ \t]*', multiLine: true);
  static final RegExp _mdQuote = RegExp(r'^[ \t]{0,3}>[ \t]?', multiLine: true);
  static final RegExp _mdBullet =
      RegExp(r'^[ \t]{0,3}[-*+•][ \t]+', multiLine: true);

  /// 规范化思考文本（幂等，保留段落间的单个空行）。
  static String cleanThoughtForShow(String raw) => _cleanThought(raw);

  static String _cleanThought(String raw) {
    if (raw.trim().isEmpty) return '';

    var s = raw
        .replaceAll('\u200b', '')
        .replaceAll('\u200c', '')
        .replaceAll('\ufeff', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    s = s.replaceAll(_mdFence, '');
    s = s.replaceAll('`', '');
    s = s.replaceAll(_mdBullet, '· ');
    s = s.replaceAll(_mdQuote, '');
    s = s.replaceAll(_mdHeading, '');
    s = s.replaceAll('**', '').replaceAll('__', '');
    s = s.replaceAll(
      RegExp(
        r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$',
        multiLine: true,
      ),
      '',
    );

    final rawLines = s.split('\n').map((l) => l.trimRight()).toList();
    final collapsed = <String>[];
    var lastWasEmpty = false;
    for (final line in rawLines) {
      if (line.trim().isEmpty) {
        if (!lastWasEmpty && collapsed.isNotEmpty) {
          collapsed.add('');
          lastWasEmpty = true;
        }
      } else {
        collapsed.add(line);
        lastWasEmpty = false;
      }
    }
    while (collapsed.isNotEmpty && collapsed.last.isEmpty) {
      collapsed.removeLast();
    }
    return collapsed.join('\n').trim();
  }
}

class _Block {
  final String tag;
  final int start;
  final int end;
  final String inner;

  const _Block({
    required this.tag,
    required this.start,
    required this.end,
    required this.inner,
  });
}
