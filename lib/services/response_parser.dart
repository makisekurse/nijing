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

  /// 模型生成的思维链 / 推演思考内容（`<think>` 或 `<thought>` 块）。
  final String thought;

  /// 模型返回的**原始文本**（未做任何清洗），仅用于排障。
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

  /// 分支够不够用 —— 不够就判定为「截断」，走兜底。
  bool get hasUsableChoices => choices.length >= 2;
}

/// 模型输出解析器。
///
/// ## 为什么重写（2026-09-25）
///
/// 旧版只有一个严格正则 `<(tag)>...</\1>`，任何一点偏差（标签内空格、
/// 全角括号、中文书名号、缺闭合标签）都会让结构块**漏进正文** ——
/// 用户实机就看到过裸的 `<cast>` 块出现在小说正文里。
///
/// 新版改成四步流水线：
///
/// ```
/// 标签定位（宽容匹配各种变体）
///   ↓
/// 结构块切分（找不到闭合标签就吃到文末）
///   ↓
/// 结构化提取（date / choices / glossary / cast / state / think）
///   ↓
/// 正文重建（按位置剔除结构块跨度，其余原样保留）
/// ```
///
/// ⚠️ **不做过度清洗**：正文里出现的 `名字|身份|立场` 这类文本，
/// 只要不在结构块内就一律保留。绝不按内容猜着删 —— 小说正文本身
/// 完全可能出现竖线，盲删会吃掉正文。
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

  static const String _structuralTagAlt = '(date|choices|glossary|cast|state)';

  /// 结构标签（排除 think/thought，用于探测思考终点）
  static final RegExp _structuralOpenTag = RegExp(
    r'[<＜《]\s*' + _structuralTagAlt + r'\s*[>＞》]',
    caseSensitive: false,
  );

  /// 显式正文标识（仅限正文标识，绝不含 markdown 分隔线 ---）
  static final RegExp _explicitBodyPrefix = RegExp(
    r'(?:(?:\r?\n)+|^\s*)(?:【正文】|（正文）|正文[：:]|正式推演[：:]|现在开始[：:]|剧情推演[：:])',
    caseSensitive: false,
  );

  /// 显式转折标识（用于 parse 模式下的启发式截断，包含 --- 等转折符）
  static final RegExp _explicitTransition = RegExp(
    r'(?:(?:\r?\n)+|^\s*)(?:【正文】|（正文）|正文[：:]|正式推演[：:]|现在开始[：:]|剧情推演[：:]|---\s*(?:\r?\n)+)',
    caseSensitive: false,
  );

  /// 完整解析。
  static ParsedChapter parse(String raw) {
    if (raw.trim().isEmpty) {
      return const ParsedChapter(body: '', rawOutput: '');
    }

    // ⚠️ 模型常常忘记写 `</think>`。若不处理，未闭合块会一路吃到文末，
    // 正文整个被当成思考、正文变空 → 判定「模型返回了空内容」→ 反复重试。
    final blocks = _scanBlocks(raw, terminateOpenThink: true);

    final choices = <String>[];
    final glossary = <GlossaryEntry>[];
    final cast = <CastEntry>[];
    var date = '';
    var stateRaw = '';
    var thought = '';

    for (final b in blocks) {
      switch (b.tag) {
        case 'date':
          date = b.inner.trim();
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

  /// 流式预览用：把「思考」与「正文」分开取。
  ///
  /// 深度思考模式下,用户要在思考阶段就看到模型在想什么,所以思考块
  /// **不丢弃**,而是单独返回。
  ///
  /// 返回 `(thought, body)`。未闭合的 `<think>` 视为「仍在思考」,
  /// 其内容全部归入 thought；半截标签（`<th`、`</think`）按其方向处理。
  static (String thought, String body) splitLive(String raw) {
    if (raw.isEmpty) return ('', '');
    final blocks = _scanBlocks(raw, terminateOpenThink: true, isLive: true);
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

    return (
      thought.toString().trim(),
      _finishBody(body.toString()),
    );
  }

  /// [splitLive] 用的正文收尾：
  /// 逐行去模板占位、清前缀，并藏掉尾部正在流入的半截标签。
  static String _finishBody(String text) {
    final cleaned = text
        .split('\n')
        .where((l) => !isBodyNoise(l))
        .join('\n')
        .trim();
    var s = cleanBodyPrefix(cleaned);
    final partial = RegExp(r'[<＜《][a-zA-Z/]{0,12}$').firstMatch(s);
    if (partial != null) s = s.substring(0, partial.start).trimRight();
    return s;
  }

  /// 扫描出所有结构块的位置与内容。
  ///
  /// [terminateOpenThink] 为 true 时，未闭合的 think 块会被截断到下一个结构
  /// 标签之前 —— 见 [parse]。
  /// [isLive] 为 true 时专用于流式分流：未闭合 think 绝不在中途基于段落断崖切给正文；
  /// 只有在遇到后续结构标签或显式【正文】前缀时才切出，否则 100% 归入 thought，body 为空。
  static List<_Block> _scanBlocks(
    String raw, {
    bool terminateOpenThink = false,
    bool isLive = false,
  }) {
    final blocks = <_Block>[];
    var cursor = 0;

    while (cursor < raw.length) {
      final open = _openTag.firstMatch(raw.substring(cursor));
      if (open == null) break;

      final start = cursor + open.start;
      final tag = (open.group(1) ?? '').toLowerCase();
      final contentStart = cursor + open.end;

      // 找同名闭标签；找不到就吃到文末（未闭合块）
      var end = raw.length;
      var contentEnd = raw.length;
      final close = _findClose(raw, contentStart, tag);
      if (close != null) {
        end = close.end;
        contentEnd = close.start;
      } else if (terminateOpenThink && (tag == 'think' || tag == 'thought')) {
        // ⚠️ 模型常常忘记写 `</think>`。不管的话它一路吃到文末，
        // 正文整个被当成思考 → 正文为空 → 判定「空内容」→ 反复重试。
        //
        // 探测未闭合 think 的截断终点：
        // 1. 查找紧跟其后的第一个结构标签（<date>, <choices>, <glossary>, <cast>, <state>）作为搜索上限；
        // 2. 在上限范围内：
        //    - 流式模式 (isLive)：绝不在中途基于段落断崖切给小说正文！只有当未闭合 <think> 之后
        //      出现了明确的下一个结构标签（<date>、<choices>、<glossary>、<cast>、<state>）
        //      或显式【正文】前缀时，才允许切出；否则所有流式内容 100% 归入 thought，body 返回空字符串。
        //    - 完整解析模式 (parse)：通过显式转折前缀、自然叙事正文特征与段落断崖探测截断点，
        //      严禁将没有 <body 标签的文学正文误吞为思考。
        final nextStructural =
            _structuralOpenTag.firstMatch(raw.substring(contentStart));
        final searchLimit = nextStructural != null
            ? nextStructural.start
            : raw.length - contentStart;
        final candidate =
            raw.substring(contentStart, contentStart + searchLimit);

        if (isLive) {
          final transMatch = _explicitBodyPrefix.firstMatch(candidate);
          if (transMatch != null) {
            end = contentStart + transMatch.start;
            contentEnd = end;
          } else if (nextStructural != null) {
            end = contentStart + nextStructural.start;
            contentEnd = end;
          } else {
            end = raw.length;
            contentEnd = raw.length;
          }
        } else {
          final cutoff = _detectOpenThinkCutoff(candidate);
          end = contentStart + cutoff;
          contentEnd = end;
        }
      } else if (tag == 'date') {
        // date 标签按提示词规范只有一行，若模型漏写 </date>，截断至换行或下一个结构标签，防止吞没正文
        final nextNewline = raw.indexOf('\n', contentStart);
        final nextTag = _structuralOpenTag.firstMatch(raw.substring(contentStart));
        var cutoff = raw.length;
        if (nextNewline != -1) cutoff = math.min(cutoff, nextNewline);
        if (nextTag != null) {
          cutoff = math.min(cutoff, contentStart + nextTag.start);
        }
        end = cutoff;
        contentEnd = end;
      }

      blocks.add(_Block(
        tag: tag,
        start: start,
        end: end,
        inner: raw.substring(contentStart, contentEnd),
      ));
      cursor = end;
    }
    RuntimeLog.i('Parser', '扫到 ${blocks.length} 个结构块：'
        '${blocks.map((b) => b.tag).join(',')}', detail: true);
    return blocks;
  }

  static Match? _findClose(String raw, int from, String tag) {
    for (final m in _closeTag.allMatches(raw, from)) {
      if ((m.group(1) ?? '').toLowerCase() == tag) return m;
    }
    return null;
  }

  static final List<String> _metaKeywords = <String>[
    '分析', '推演', '本幕', '主角', '玩家', '设定', '剧情', '反转', '伏笔',
    '选项', '决断', '字数', '结构', '状态', '契约', '写作', '决策', '策略',
    '处境', '动机', '视角', '输出', '思考', '首先', '其次', '考虑', '铺垫',
    '线索', '步骤', '设计', '大纲', '衔接', '构思', '前文',
    '权衡', '局势', '落笔', '思路', '梳理', '盘点', '总结', '先来', '我们来',
    'prompt', 'think', 'reasoning', 'user', 'plot',
  ];

  /// 探测未闭合 think 的截断点。
  /// 返回相对于 [candidate] 起始处的安全截断偏移量。
  static int _detectOpenThinkCutoff(String candidate) {
    if (candidate.isEmpty) return 0;

    // 1. 显式转折标识探测（如「正文：」、「【正文】」、「---」等）
    final transMatch = _explicitTransition.firstMatch(candidate);
    if (transMatch != null && transMatch.start >= 0) {
      return transMatch.start;
    }

    final firstTextMatch = RegExp(r'\S').firstMatch(candidate);
    if (firstTextMatch == null) return 0;

    // 检查第一段是否已经是正文（即模型完全没有思考，直接在 <think> 里输出正文）
    final doublePattern = RegExp(r'(?:\r?\n)\s*(?:\r?\n)+');
    final singlePattern = RegExp(r'(?:\r?\n)+');

    final afterFirst = candidate.substring(firstTextMatch.start);
    final firstDouble = doublePattern.firstMatch(afterFirst);
    final firstSingle = singlePattern.firstMatch(afterFirst);
    final firstEndOffset = firstDouble?.start ??
        (firstSingle?.start ?? afterFirst.length);
    final firstPara = candidate
        .substring(firstTextMatch.start, firstTextMatch.start + firstEndOffset)
        .trim();
    if (_looksLikeNarrativeBody(firstPara, isFirstPara: true)) {
      return 0;
    }

    // 2. 自然叙事正文特征与段落断崖探测
    // 优先检测双空行段落断崖（Markdown 标准段落分界）
    for (final sep in doublePattern.allMatches(candidate)) {
      if (sep.start < firstTextMatch.start) continue;
      final nextCandidate = candidate.substring(sep.end);
      final nextDouble = doublePattern.firstMatch(nextCandidate);
      final nextParaEnd =
          nextDouble != null ? sep.end + nextDouble.start : candidate.length;
      final nextParaText = candidate.substring(sep.end, nextParaEnd).trim();

      if (nextParaText.isNotEmpty &&
          _looksLikeNarrativeBody(nextParaText, isFirstPara: false)) {
        return sep.start;
      }
    }

    // 若无双空行断崖，再按单换行探测（要求具备对话引号或具备完整标点的自然句式）
    for (final sep in singlePattern.allMatches(candidate)) {
      if (sep.start < firstTextMatch.start) continue;
      final nextCandidate = candidate.substring(sep.end);
      final nextSingle = singlePattern.firstMatch(nextCandidate);
      final nextParaEnd =
          nextSingle != null ? sep.end + nextSingle.start : candidate.length;
      final nextParaText = candidate.substring(sep.end, nextParaEnd).trim();

      if (nextParaText.isNotEmpty &&
          _looksLikeNarrativeBody(nextParaText, isFirstPara: false) &&
          (nextParaText.contains('“') ||
              nextParaText.contains('「') ||
              nextParaText.length >= 10)) {
        return sep.start;
      }
    }

    return candidate.length;
  }

  /// 判定某一段是否具备文学小说自然叙事特征（而非元思维分析）。
  static bool _looksLikeNarrativeBody(String text,
      {required bool isFirstPara}) {
    final t = text.trim();
    if (t.isEmpty) return false;

    // 1. 排除列表式输出（如 1. 2. - *）
    final isList = RegExp(r'^\s*[-*•\d+\.]').hasMatch(t);
    if (isList) return false;

    // 2. 严禁以元思维引导词开头（如「思考：」「推演：」「分析：」「思路：」「注意：」）
    final isMetaPrefix = RegExp(
      r'^(?:思考|推演|分析|思路|梳理|构思|注意|设计|总结|盘点|决策|规划|写作)[：:]',
    ).hasMatch(t);
    if (isMetaPrefix) return false;

    // 3. 排除明确的思维分析与指令性语言（避免思考中脑暴或引用指令时被误判为正文）
    final isMetaDirective = t.contains('不要反转') ||
        t.contains('不要有标签') ||
        t.contains('正文中不要') ||
        t.contains('需要把') ||
        t.contains('可以开头') ||
        t.contains('决定：“') ||
        t.contains('规则要求') ||
        t.contains('既成事实') ||
        t.contains('天道敕令') ||
        t.contains('主宰模式') ||
        t.contains('剧情推进');
    if (isMetaDirective) return false;

    // 4. 标准角色小说对话判定：以引号开头的小说对话，如「“当务之急是弄清他的动机。”林砚低声道...」
    final isDialogueStart = t.startsWith('“') || t.startsWith('「');
    if (isDialogueStart) {
      if (t.contains('”') || t.contains('」')) {
        return true;
      }
    }

    // 5. 自然叙事正文判定：严禁存在思维分析关键词
    var metaCount = 0;
    for (final kw in _metaKeywords) {
      if (t.contains(kw)) metaCount++;
    }
    if (metaCount > 0) return false;

    final hasTerminal = t.contains('。') ||
        t.contains('！') ||
        t.contains('？') ||
        t.contains('……') ||
        t.contains('——');

    return hasTerminal && t.length >= 4;
  }

  /// 按位置剔除所有结构块跨度，其余原样保留。
  ///
  /// 做三件事：
  /// 1. **按位置**去掉结构块；
  /// 2. **逐行**去掉模板占位文字；
  /// 3. **智能清洗正文开头的模板标识前缀**（「正文：」「【正文】」「正文如下：」「（正文）」等）。
  /// 绝不按内容猜着删 —— 小说正文本身完全可能出现竖线、书名号，盲删会吃掉正文。
  static String _rebuildBody(String raw, List<_Block> blocks) {
    final text = _removeBlockSpans(raw, blocks);
    final cleaned = text
        .split('\n')
        .where((l) => !isBodyNoise(l))
        .join('\n')
        .trim();
    return cleanBodyPrefix(cleaned);
  }

  /// 正文开头残留的模板标识前缀（如「正文：」「【正文】」「正文如下：」「（正文）」「**正文**：」「### 正文」等）。
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

  // ---------- 模板占位文字兜底过滤 ----------
  //
  // 2026-09-25 实机事故：内核提示词给了可直接照抄的内容行，模型就把它们
  // 原样抄进了输出 —— 选项里混进「第一条可供主角决断的具体行动
  // （一句话，30~60 字）」，正文里混进「（正文：约 500 字的白描叙事）」。
  //
  // 内核已改成空骨架（见 PromptKernel.build）。这里是**第二道防线**：
  // 即使模型照抄了模板行，也进不了界面。

  /// 列表项（choices / glossary / cast）里的模板占位行。
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
    // 天道敕令 / 主宰模式模板标识回响
    RegExp(r'^[【\[（(]\s*(?:天道敕令|主宰天道敕令).*$'),
  ];

  /// 正文里的模板占位行。
  ///
  /// 刻意比 [_itemNoise] **窄** —— 正文是文学文本，宁可漏杀也不能误杀。
  /// 例如 `〈…〉` 这种书名号在中文小说里是合法写法，所以不在这里过滤。
  static final List<RegExp> _bodyNoise = <RegExp>[
    // （正文：约 500 字的白描叙事）及其变体
    RegExp(r'^[（(]\s*正文\s*[:：].*[）)]$'),
    RegExp(r'^正文\s*[:：]\s*约?\s*\d*\s*字.*$'),
    // 剧中日期，例如 1949年11月30日
    RegExp(r'^剧中日期\s*[，,：:].*$'),
    RegExp(r'^第[一二三四五六七八九十]条\s*可供主角决断的具体行动.*$'),
    RegExp(r'^第[一二三四五六七八九十]条\s*[（(]\s*可选\s*[）)].*$'),
    // 天道敕令 / 主宰模式模板标识回响
    RegExp(r'^[【\[（(]\s*(?:天道敕令|主宰天道敕令).*$'),
    RegExp(r'^(?:天道敕令|主宰天道敕令)\s*[:：].*$'),
  ];

  /// 这一行是不是列表项里的模板占位文字。
  static bool isTemplateNoise(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('<!--') || t.endsWith('-->')) return true;
    for (final r in _itemNoise) {
      if (r.hasMatch(t)) return true;
    }
    return false;
  }

  /// 这一行是不是正文里的模板占位文字。
  static bool isBodyNoise(String line) {
    final t = line.trim();
    if (t.isEmpty) return false;
    if (t.startsWith('<!--') || t.endsWith('-->')) return true;
    for (final r in _bodyNoise) {
      if (r.hasMatch(t)) return true;
    }
    return false;
  }

  /// 判断一段输出是不是「拒答」。
  ///
  /// 只看开头一小段，避免正文里提到"抱歉"被误判。
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
    var hits = 0;
    for (final m in markers) {
      if (probe.contains(m)) hits++;
    }
    return hits >= 1 && head.length < 400;
  }

  static List<String> _splitItems(
    String block,
    String Function(String) clean,
  ) =>
      block
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          // 兜底：模型可能把内核模板行原样抄进列表
          .where((l) => !isTemplateNoise(l))
          .map(clean)
          .where((l) => l.isNotEmpty)
          .where((l) => !isTemplateNoise(l))
          .toList();

  /// 去掉「1. 」「- 」「选项一：」这类前缀。
  static String _cleanChoice(String line) => line
      .replaceAll(
        RegExp(r'^(\d+[\.、\s]|[-*•]\s*|选项[一二三四五六123456][：:\.、]?\s*)'),
        '',
      )
      .trim();

  // ---------- 思考文本规范化 ----------
  //
  // 原生 reasoning 是自由格式：Markdown 标题、加粗、代码围栏、行内反引号、
  // 列表标记、零宽字符全都会出现。提示词里已经要求「纯中文自然语言」，
  // 这里是**第二道防线** —— 提示词不保证 100% 生效。
  //
  // 刻意**不做机翻**：把英文自动翻译成中文只会引入错误，不如原文保留。

  static final RegExp _mdFence = RegExp(r'^[ \t]*```.*$', multiLine: true);
  static final RegExp _mdHeading = RegExp(r'^[ \t]{0,3}#{1,6}[ \t]*', multiLine: true);
  static final RegExp _mdQuote = RegExp(r'^[ \t]{0,3}>[ \t]?', multiLine: true);
  static final RegExp _mdBullet = RegExp(r'^[ \t]{0,3}[-*+•][ \t]+', multiLine: true);

  /// 规范化思考文本，供 LLM 流式转换与 [parse] 共用。
  ///
  /// 幂等：同一段文本跑两次结果一致（逐块流式调用也安全）。
  static String cleanThoughtForShow(String raw) => _cleanThought(raw);

  /// 规范化思考文本。幂等：同一段文本跑两次结果一致。
  static String _cleanThought(String raw) {
    if (raw.trim().isEmpty) return '';

    var s = raw
        .replaceAll('\u200b', '')
        .replaceAll('\u200c', '')
        .replaceAll('\ufeff', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    // 代码围栏整行删掉（内容保留 —— 那是模型的分析文字）
    s = s.replaceAll(_mdFence, '');
    // 行内反引号
    s = s.replaceAll('`', '');
    // 行首标记 → 中文项目符号
    s = s.replaceAll(_mdBullet, '· ');
    s = s.replaceAll(_mdQuote, '');
    s = s.replaceAll(_mdHeading, '');
    // 加粗 / 斜体标记
    s = s.replaceAll('**', '').replaceAll('__', '');
    // 表格分隔行整行删掉（`--- | ---` 这类），别误伤「a | b 分隔符」这种正文字符串
    s = s.replaceAll(
      RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$', multiLine: true),
      '',
    );

    // 保留段落之间的单个空行（连续多空行折叠为一个空行）
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
