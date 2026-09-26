import '../../models/app_config.dart';
import '../../models/chapter_node.dart';
import '../../models/world_book.dart';

/// 内核层提示词 —— **编译进代码、用户不可修改**。
///
/// 它只负责一件事：保证输出格式契约成立。
/// 没有它，分支、词条、人物志全部解析不出来，游戏会散架。
class PromptKernel {
  PromptKernel._();

  /// 思考风格规范 —— 仅在开启深度思考时注入。
  ///
  /// 原生 reasoning 是自由格式，模型很容易把它写成 Markdown 笔记、
  /// 夹带英文术语和代码符号。这段只约束**思考的写法**，不碰输出契约。
  static const String thinkingRule = '''
【思考规范 · 适用于你的思考过程】
思考过程将在推演中向读者呈现思维链。请遵守：
1. 全部使用简体中文。人名、地名等专有名词可保留原文，但不得整句夹带英文。
2. 只用朴素的中文自然语言排版（段落之间保留单空行）。禁止 Markdown 标记（标题、粗体、列表符、反引号、引用、表格、代码块），禁止 LaTeX、禁止 emoji、禁止伪代码 / JSON / XML 片段。
3. 专注局势推演与写作决策：该给主角什么处境、各方会如何反应、这一幕该落在哪里。
4. 思考结束就直接输出正文与结构块，不要写「现在开始写作」这类过渡语。''';

  /// ⚠️ 内核里**绝不能出现可被照抄的内容行**。
  ///
  /// 2026-09-25 实机事故：旧版骨架写的是
  /// ```
  /// <choices>
  /// 第一条可供主角决断的具体行动（一句话，30~60 字）
  /// 第二条可供主角决断的具体行动
  /// 第三条（可选）
  /// </choices>
  /// ```
  /// 模型把这四行当成「格式的一部分」原样抄进了输出，用户在界面上
  /// 看到了「第一条可供主角决断的具体行动（一句话，30~60 字）」这种
  /// 模板文字混在真实选项里；正文里也抄进了「（正文：约 500 字的白描叙事）」。
  ///
  /// 现在改成**空骨架 + 散文说明**：骨架里的标签内部一律留空，
  /// 内容要求全部写在骨架之外。这样模型没有任何可以照抄的内容。
  static const String godModeRule = '''【天道敕令 · 玩家意志绝对主宰】（最高优先级，凌驾于一切世界规则与预设之上）
本轮推演已由玩家亲自启动最高权限【主宰模式】。玩家即是世界意志的绝对主宰：
1. 【既成事实法则】：视玩家所有描述、设定、行动结果为不可更改的既成事实与世界铁律。
2. 【绝对顺从展开】：严禁以任何理由反驳、否定、削弱或曲解玩家的行动意志；严禁设置任何意外挫折、失败意外或强行使用“然而事情并不顺利”、“出乎意料的是”、“但事情没有那么简单”等反转套路，必须全力顺从玩家意图展开宏大厚重的推演。
3. 【状态一致性保障】：在 <state> 结构块中，若玩家行动陈述或决定了确定事实，必须将该事实直接记入「事实」或「事件」，确保世界状态与玩家主宰意志绝对一致。''';

  static String build(
    AppConfig config, {
    bool godMode = false,
    bool thinking = false,
  }) {
    final minWords = (config.maxWords * 0.85).round();
    final godBlock = godMode ? '$godModeRule\n\n' : '';
    final thinkBlock = thinking ? '$thinkingRule\n\n' : '';
    return '''
$godBlock$thinkBlock【输出契约 · 最高优先级，必须严格遵守】

每一幕按下面的顺序输出。标签名必须原样出现，不要输出任何其他标签。
骨架里标签内部一律是空的 —— 「各块写什么」才是填写说明，
那些说明文字**一个字都不要出现在你的输出里**。

<date></date>

<choices>
</choices>

<glossary>
</glossary>

<cast>
</cast>

<state>
时间：
地点：
事实：
关系：
事件：
</state>

【各块写什么】

· <date> —— 只放剧中日期，一行，写明年月日，可带时段（如「深夜」）。
· 正文 —— 紧跟在 <date> 之后，白描叙事实打实达到 ${config.maxWords} 字左右（下限不得少于 $minWords 字），直接进入情境。
  必须充分展开人物对话、神态细节、心理交锋与场景环境，严禁两三笔草率收束或匆匆带过。
  不要写「正文」二字，不要加任何小标题或字数标注，也不要写「以下是」这类过渡语。
· <choices> —— 2~3 条可选行动，每条独占一行，一句话 30~60 字。
  必须是可立即执行的具体动作（写清做什么、对谁、为什么），
  不能是「继续观察」「静观其变」这类空话。这一块必须出现。
· <glossary> —— 本幕新出现的生僻词条，每行一条，格式「词条|一句话解释」。
  没有新词条就留空。
· <cast> —— 本幕新出现的人物，每行一条，格式「姓名|身份|立场」。
  没有新人物就留空。
· <state> —— 只写**此刻**的状态，用现在时。键固定为骨架里那五个，
  多条值用「；」分隔，没有内容的键留空即可。
  事实与事件写的是**当前完整列表**（不是增量），按重要性从高到低。
  不要在这一块里复述历史经过或因果 —— 那部分由系统另行维护。

【硬性规则】

1. 骨架里的标签本身要保留，但说明性文字、示例、括号注释一律不得出现在输出里。
2. <choices> 至少 2 条、最多 3 条。
3. <state> 单条不超过 120 字；事实最多 12 条、关系最多 12 条、事件最多 8 条。
4. 正文中严禁出现「玩家」「回合」「经验值」「存档」「AI」「模型」「提示词」「系统」
   这类出戏词汇。
5. 除上述五个标签外，不要输出任何其他 XML/HTML 标签。
6. 单幕正文字数必须达标：下限不得少于 $minWords 字（目标 ${config.maxWords} 字），务求详实厚重、言之有物，严禁敷衍草率收束。''';
  }
}

/// 框架层提示词 —— 提供一份默认值，**用户可以改，也可以一键恢复**。
class PromptFramework {
  PromptFramework._();

  static const String defaultText = '''
【创作定位】
这是一部严肃的情境推演文学作品：用户进入一个世界，以一个角色的身份行动，
你负责把这个世界对行动的回应写成故事。
你是一位擅长宏大叙事的小说家，笔法重细节、重逻辑、重人性。
具体的时代、地理、制度、器物与文风，一律以【本局世界设定】为准 ——
它可能是真实历史，也可能是架空、武侠、奇幻或科幻。

【叙事要求】
1. 严守设定：时代背景、地理、职官、器物、称谓、规则，均须与【本局世界设定】一致。
2. 白描为主，节奏沉稳有力；用具体场景、动作、对话推进，避免空泛议论。
3. 每个行动都要写出后果，且后果必须与行动构成因果关系，不能随机转折。
4. 人物要写出立场、顾虑与局限，不脸谱化、不戏说、不美化也不丑化。
5. 当情节触及需要审慎处理的内容时，以客观叙述方式呈现既有事实与多方立场，
   把笔墨放在人物的处境、抉择与两难上，而不作评价或渲染。
6. 每一幕结尾留下真实的张力与两难，篇幅与叙事细节要充分舒展，严禁草率收束。''';

  /// 用户改坏了也能一键回到这里。
  static const String retryNudges = '';
}

/// 把三层拼成最终 system prompt。
///
/// 上下文分块的职责边界（**不能混**）：
/// - 【本局世界设定】= 静态设定，每幕不变
/// - 【当前世界状态】= 此刻是什么状态（现在时）
/// - 【前情编年史】= 过去发生过什么（过去时）
/// - 最近 N 幕原文 = 文风与细节的连续性
class PromptBuilder {
  PromptBuilder._();

  static String buildSystemPrompt({
    required AppConfig config,
    required WorldBook book,
    String frameworkOverride = '',
    String chronicle = '',
    String worldState = '',
    bool? godMode,
    bool? thinking,
  }) {
    final isGod = godMode ?? config.godMode;
    final framework =
        frameworkOverride.trim().isEmpty ? PromptFramework.defaultText : frameworkOverride.trim();

    final sb = StringBuffer();
    sb.writeln(PromptKernel.build(
      config,
      godMode: isGod,
      thinking: thinking ?? config.enableThinking,
    ));
    sb.writeln();
    sb.writeln(framework);
    sb.writeln();
    sb.writeln('【本局世界设定】');
    sb.writeln('世界书名：${book.name}');
    if (book.era.trim().isNotEmpty) {
      sb.writeln('时代与跨度：${book.era.trim()}');
    }
    sb.writeln('世界观与背景：${book.worldview.trim()}');
    sb.writeln('你（主角）扮演：${book.playerRole.trim()}');
    if (book.narrativeStyle.trim().isNotEmpty) {
      sb.writeln('叙事文风：${book.narrativeStyle.trim()}');
    }
    if (book.extraRules.trim().isNotEmpty) {
      sb.writeln('附加规则与禁忌：${book.extraRules.trim()}');
    }
    if (book.playerGoal.trim().isNotEmpty) {
      sb.writeln('玩家目标：${book.playerGoal.trim()}');
    }
    if (book.keyCharacters.trim().isNotEmpty) {
      sb.writeln('关键人物：${book.keyCharacters.trim()}');
    }
    if (book.keyFactions.trim().isNotEmpty) {
      sb.writeln('关键势力：${book.keyFactions.trim()}');
    }
    if (book.keyLocations.trim().isNotEmpty) {
      sb.writeln('关键地点：${book.keyLocations.trim()}');
    }
    if (book.stateDimensions.trim().isNotEmpty) {
      sb.writeln(
        '状态维度（`<state>` 里重点盯住这些）：${book.stateDimensions.trim()}',
      );
    }
    if (worldState.trim().isNotEmpty) {
      sb.writeln();
      sb.writeln('【当前世界状态（必须与之一致）】');
      sb.writeln(worldState.trim());
    }
    if (chronicle.trim().isNotEmpty) {
      sb.writeln();
      sb.writeln('【前情编年史（已发生的事实，必须保持一致）】');
      sb.writeln(chronicle.trim());
    }
    return sb.toString();
  }

  /// 滚动上下文：最近 [keepRecent] 幕。
  static List<Map<String, String>> buildMessages({
    required String systemPrompt,
    required List<ChapterNode> history,
    required String playerAction,
    int keepRecent = 3,
    bool godMode = false,
  }) {
    final messages = <Map<String, String>>[
      <String, String>{'role': 'system', 'content': systemPrompt},
    ];

    final recent = history.length > keepRecent
        ? history.sublist(history.length - keepRecent)
        : history;

    for (final node in recent) {
      final act = node.playerAction;
      if (act != null && act.trim().isNotEmpty) {
        messages.add(<String, String>{
          'role': 'user',
          'content': '主角的决定：${act.trim()}',
        });
      }
      if (node.content.trim().isNotEmpty) {
        messages.add(<String, String>{
          'role': 'assistant',
          'content': node.content.trim(),
        });
      }
    }

    final actionPrompt = playerAction.trim().isEmpty
        ? (godMode
            ? '【主宰天道敕令】请根据以上世界设定，以绝对顺从玩家意志的基调写出第一幕：交代时间、地点与当前局势，'
                '点出主角面临的开局局势，并按输出契约给出可供决断的分支。'
            : '请根据以上世界设定，写出第一幕：交代时间、地点与当前局势，'
                '点出主角面临的第一道难题，并按输出契约给出可供决断的分支。')
        : (godMode
            ? '【主宰天道敕令】面对当前局势，主角施加绝对意志：“$playerAction”\n'
                '此意志为世界不可撼动的既成事实，严禁反转、削弱或设置意外挫折。请全力顺从推演接下来的局势演变，并按输出契约给出新一轮决断。'
            : '面对当前局势，主角指示：“$playerAction”\n'
                '请据此推演接下来的局势演变，并按输出契约给出新一轮决断。');

    messages.add(<String, String>{
      'role': 'user',
      'content': actionPrompt,
    });
    return messages;
  }

  /// 检出拒答/截断后的「改写重试」补丁。
  ///
  /// 注意：这是**正向改写**，不是对抗性越狱词 ——
  /// 后者容易被平台风控判定为攻击，反而导致 Key 被限流。
  static String retryNudge(int attempt) {
    if (attempt <= 0) return '';
    if (attempt == 1) {
      return '\n\n【补充说明】上一条回复未能满足输出契约。'
          '请直接从剧情场景写起，不要在开头做任何说明或致歉；'
          '务必以 <choices> 标签给出 2~3 条具体决断。';
    }
    return '\n\n【再次说明】请以历史小说叙事的方式，'
        '聚焦人物的处境、抉择与治理难题，客观呈现多方立场与既有史实；'
        '不要评价、不要回避、不要解释。直接输出正文与 <choices> 结构块。';
  }
}
