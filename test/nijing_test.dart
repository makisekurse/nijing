import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nijing/ui/screens/reader_screen.dart';
import 'package:nijing/models/annotation.dart';
import 'package:nijing/models/app_config.dart';
import 'package:nijing/models/chapter_node.dart';
import 'package:nijing/models/save_slot.dart';
import 'package:nijing/models/world_book.dart';
import 'package:nijing/models/world_line.dart';
import 'package:nijing/models/world_state.dart';
import 'package:nijing/services/file_export_service.dart';
import 'package:nijing/services/game_session.dart';
import 'package:nijing/services/llm_client.dart';
import 'package:nijing/services/prompt_builder.dart';
import 'package:nijing/services/response_parser.dart';
import 'package:nijing/services/save_service.dart';
import 'package:nijing/services/story_export_service.dart';
import 'package:nijing/services/text_layout.dart';
import 'package:nijing/core/app_error.dart';
import 'package:nijing/services/fallback_service.dart';
import 'package:nijing/services/generation_controller.dart';
import 'package:nijing/services/providers.dart';
import 'package:nijing/services/runtime_log.dart';
import 'package:nijing/services/wakelock_service.dart';
import 'package:nijing/services/world_state_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WorldBook 导入', () {
    test('JSON 正常解析', () {
      final book = WorldBook.fromImportText('''
{"name":"测试世界","era":"1900","worldview":"背景","playerRole":"主角"}
''');
      expect(book.name, '测试世界');
      expect(book.era, '1900');
      expect(book.isPlayable, isTrue);
    });

    test('兼容别名键', () {
      final book = WorldBook.fromImportText('''
{"title":"别名世界","setting":"某背景","role":"某人物"}
''');
      expect(book.name, '别名世界');
      expect(book.worldview, '某背景');
      expect(book.playerRole, '某人物');
    });

    test('纯文本回落到世界观字段', () {
      final book = WorldBook.fromImportText('大唐开元年间，长安城。');
      expect(book.worldview, contains('大唐'));
      expect(book.isPlayable, isFalse);
      expect(book.missingFields, contains('扮演人物'));
    });

    test('导出再导入保持等价', () {
      final original = WorldBook(
        id: 'abc',
        name: '往返测试',
        worldview: '背景',
        playerRole: '主角',
        openingChoices: <String>['一', '二'],
      );
      final restored = WorldBook.fromImportText(original.exportToJson());
      expect(restored.name, original.name);
      expect(restored.openingChoices, original.openingChoices);
    });
  });

  group('ResponseParser · 标准与变体标签', () {
    const body = '他知道，从这一刻起，每一步都走在刀尖之上。';
    const choices =
        '<choices>\n1. 立即组建专项工作组\n2. 暂缓行动，暗中调查\n</choices>';
    const cast =
        '<cast>\n邓小平|中共中央副主席|主持日常工作\n王洪文|中共中央副主席|暗中阻挠\n</cast>';
    const glossary = '<glossary>\n绥靖公署|战时军政合一的区域性机构\n</glossary>';

    test('标准形态：正文干净，三块都抽走', () {
      final p = ResponseParser.parse('$body\n\n$choices\n\n$glossary\n\n$cast');
      expect(p.body, body);
      expect(p.choices.length, 2);
      expect(p.glossary.length, 1);
      expect(p.cast.length, 2);
      expect(p.hasUsableChoices, isTrue);
    });

    test('开标签带空格 < cast >', () {
      final p = ResponseParser.parse('$body\n\n< cast >\n邓小平|甲\n</cast>');
      expect(p.body, body);
      expect(p.cast.length, 1);
    });

    test('闭标签带空格 </cast >', () {
      final p = ResponseParser.parse('$body\n\n<cast>\n邓小平|甲\n</cast >');
      expect(p.body, body);
      expect(p.cast.length, 1);
    });

    test('全角尖括号 ＜cast＞', () {
      final p = ResponseParser.parse('$body\n\n＜cast＞\n邓小平|甲\n＜/cast＞');
      expect(p.body, body);
      expect(p.cast.length, 1);
    });

    test('中文书名号《cast》', () {
      final p = ResponseParser.parse('$body\n\n《cast》\n邓小平|甲\n《/cast》');
      expect(p.body, body);
      expect(p.cast.length, 1);
    });

    test('标签大小写混用 <Cast>…</CAST>', () {
      final p = ResponseParser.parse('$body\n\n<Cast>\n邓小平|甲\n</CAST>');
      expect(p.body, body);
      expect(p.cast.length, 1);
    });

    test('未闭合块：从开标签吃到文末', () {
      final p = ResponseParser.parse('$body\n\n<cast>\n邓小平|甲\n李先念|乙');
      expect(p.body, body);
      expect(p.cast.length, 2);
    });

    test('第二个块未闭合，不影响前面的提取', () {
      final p = ResponseParser.parse('$body\n\n$choices\n\n<cast>\n邓小平|甲');
      expect(p.body, body);
      expect(p.choices.length, 2);
      expect(p.cast.length, 1);
    });

    test('空结构块', () {
      final p = ResponseParser.parse('$body\n\n<cast>\n</cast>\n\n$choices');
      expect(p.body, body);
      expect(p.cast, isEmpty);
      expect(p.choices.length, 2);
    });

    test('块在正文之前', () {
      final p = ResponseParser.parse('$cast\n\n$body\n\n$choices');
      expect(p.body, body);
      expect(p.cast.length, 2);
      expect(p.choices.length, 2);
    });

    test('多个同名块合并', () {
      final p = ResponseParser.parse(
        '$body\n\n<cast>\n邓小平|甲\n</cast>\n\n<cast>\n李先念|乙\n</cast>',
      );
      expect(p.body, body);
      expect(p.cast.length, 2);
    });

    test('截断输出：有正文无 choices', () {
      final p = ResponseParser.parse('$body\n\n<choices>\n1. 只有一条');
      expect(p.body, body);
      expect(p.hasUsableChoices, isFalse);
    });

    test('date 与 state 也能抽走', () {
      final p = ResponseParser.parse(
        '<date>1949年11月30日</date>\n$body\n\n<state>\ntime: 夜\n</state>',
      );
      expect(p.date, '1949年11月30日');
      expect(p.stateRaw, contains('time'));
      expect(p.body, body);
    });

    test('rawOutput 保存原始文本', () {
      final raw = '$body\n\n$cast';
      final p = ResponseParser.parse(raw);
      expect(p.rawOutput, raw);
    });
  });

  group('ResponseParser · 不做过度清洗（关键回归）', () {
    test('正文里的竖线行必须原样保留', () {
      const raw = '他翻开名册，上面写着：\n\n张三|县令|谨慎\n李四|主簿|亲善\n\n'
          '这行字让他久久没有说话。';
      final p = ResponseParser.parse(raw);
      expect(p.body, contains('张三|县令|谨慎'));
      expect(p.body, contains('李四|主簿|亲善'));
      expect(p.cast, isEmpty);
    });

    test('正文里出现尖括号但不构成标签时保留', () {
      const raw = '他写道：「此事<不可说>，慎之。」';
      final p = ResponseParser.parse(raw);
      expect(p.body, contains('<不可说>'));
    });

    test('结构块被剔除后，前后正文都还在', () {
      final p = ResponseParser.parse(
        '前半段正文。\n\n<cast>\n甲|乙\n</cast>\n\n后半段正文。',
      );
      expect(p.body, contains('前半段正文。'));
      expect(p.body, contains('后半段正文。'));
      expect(p.body.contains('cast'), isFalse);
    });
  });

  group('ResponseParser · 流式预览', () {
    test('未闭合标签在预览里也要藏掉', () {
      final (_, body) =
          ResponseParser.splitLive('正文开始…\n\n<choices>\n第一条');
      expect(body.contains('<choices>'), isFalse);
      expect(body.contains('正文开始'), isTrue);
    });

    test('正在流入的半截标签不闪出', () {
      final (_, body) = ResponseParser.splitLive('正文开始…\n\n<ca');
      expect(body.contains('<ca'), isFalse);
      expect(body.contains('正文开始'), isTrue);
    });

    test('拒答识别', () {
      expect(ResponseParser.looksLikeRefusal('抱歉，我无法协助这个请求。'), isTrue);
      expect(ResponseParser.looksLikeRefusal(''), isTrue);
      expect(
        ResponseParser.looksLikeRefusal('1949年10月，常德前线司令部里灯火通明。'),
        isFalse,
      );
    });
  });

  group('Annotation', () {
    test('词条行解析', () {
      final e = GlossaryEntry.parseLine('绥靖公署|战时设立的军政合一的区域性机构');
      expect(e, isNotNull);
      expect(e!.term, '绥靖公署');
    });

    test('非法行返回 null', () {
      expect(GlossaryEntry.parseLine('没有分隔符'), isNull);
    });

    test('人物合并不覆盖成空', () {
      const a = CastEntry(name: '刘伯承', role: '司令员', stance: '支持');
      const b = CastEntry(name: '刘伯承', role: '', stance: '观望');
      final merged = a.merge(b);
      expect(merged.role, '司令员');
      expect(merged.stance, '观望');
    });
  });

  group('WorldStateService · 解析', () {
    test('标准格式', () {
      final s = WorldStateService.parse('''
时间：1949年11月23日 深夜
地点：重庆市委机关
事实：城东发生武装冲突；张某已经知道玩家在查资金
关系：张某|谨慎；李某|信任
事件：银行挤兑仍在持续；地方武装问题尚未解决
''');
      expect(s.time, '1949年11月23日 深夜');
      expect(s.location, '重庆市委机关');
      expect(s.facts.length, 2);
      expect(s.relations['张某'], '谨慎');
      expect(s.relations['李某'], '信任');
      expect(s.events.length, 2);
    });

    test('容错：半角冒号 / 半角分号 / 英文键名 / 多余空行', () {
      final s = WorldStateService.parse('''

time: 1949年11月
location: 重庆

facts: 甲; 乙

''');
      expect(s.time, '1949年11月');
      expect(s.location, '重庆');
      expect(s.facts, <String>['甲', '乙']);
    });

    test('容错：键名带星号与序号前缀', () {
      final s = WorldStateService.parse('**时间**：夜\n1. 地点：山城');
      expect(s.time, '夜');
      expect(s.location, '山城');
    });

    test('畸形输入不抛异常，返回空 state', () {
      expect(WorldStateService.parse('').isEmpty, isTrue);
      expect(WorldStateService.parse('乱七八糟没有冒号').isEmpty, isTrue);
      expect(WorldStateService.parse('未知键：值').isEmpty, isTrue);
    });
  });

  group('WorldStateService · 合并', () {
    test('时间地点覆盖，事实整体替换', () {
      final prev = WorldState(
        time: '旧时间',
        location: '旧地点',
        facts: <String>['旧事实'],
      );
      final next = WorldStateService.merge(
        prev,
        WorldState(time: '新时间', facts: <String>['新事实']),
      );
      expect(next.time, '新时间');
      expect(next.location, '旧地点'); // 新值为空则不覆盖
      expect(next.facts, <String>['新事实']);
    });

    test('关系是增量：模型没提到的旧关系保留', () {
      final prev = WorldState(relations: <String, String>{'张某': '谨慎'});
      final next = WorldStateService.merge(
        prev,
        WorldState(relations: <String, String>{'李某': '信任'}),
      );
      expect(next.relations['张某'], '谨慎');
      expect(next.relations['李某'], '信任');
    });

    test('关系同键时新值覆盖', () {
      final prev = WorldState(relations: <String, String>{'张某': '谨慎'});
      final next = WorldStateService.merge(
        prev,
        WorldState(relations: <String, String>{'张某': '敌视'}),
      );
      expect(next.relations['张某'], '敌视');
    });

    test('不修改传入的旧状态（避免快照被就地改坏）', () {
      final prev = WorldState(facts: <String>['甲']);
      WorldStateService.merge(prev, WorldState(facts: <String>['乙']));
      expect(prev.facts, <String>['甲']);
    });
  });

  group('WorldStateService · 上限与截断', () {
    test('事实超过 12 条时截断', () {
      final s = WorldState(
        facts: List<String>.generate(20, (i) => '事实$i'),
      );
      final capped = WorldStateService.merge(s, WorldState());
      expect(capped.facts.length, WorldState.maxFacts);
    });

    test('事件超过 8 条时截断', () {
      final s = WorldState(
        events: List<String>.generate(15, (i) => '事件$i'),
      );
      final capped = WorldStateService.merge(s, WorldState());
      expect(capped.events.length, WorldState.maxEvents);
    });

    test('单条超长被截断并加省略号', () {
      final long = '甲' * 300;
      final s = WorldStateService.merge(
        WorldState(),
        WorldState(facts: <String>[long]),
      );
      expect(s.facts.first.length, lessThanOrEqualTo(WorldState.maxItemChars + 1));
      expect(s.facts.first.endsWith('…'), isTrue);
    });

    test('重复条目去重', () {
      final s = WorldStateService.merge(
        WorldState(),
        WorldState(facts: <String>['甲', '甲', '乙']),
      );
      expect(s.facts, <String>['甲', '乙']);
    });

    test('总预算兜底：超长时从尾部丢弃', () {
      final s = WorldState(
        facts: List<String>.generate(12, (i) => '甲' * 120),
        events: List<String>.generate(8, (i) => '乙' * 120),
      );
      final capped = WorldStateService.merge(s, WorldState());
      final total = capped.facts.fold<int>(0, (a, e) => a + e.length) +
          capped.events.fold<int>(0, (a, e) => a + e.length);
      expect(total, lessThanOrEqualTo(WorldState.maxTotalChars));
    });
  });

  group('WorldStateService · 渲染', () {
    test('渲染进 prompt', () {
      final s = WorldState(
        time: '夜',
        location: '山城',
        facts: <String>['甲'],
        relations: <String, String>{'张': '谨慎'},
        events: <String>['乙'],
      );
      final text = WorldStateService.renderForPrompt(s);
      expect(text, contains('时间：夜'));
      expect(text, contains('地点：山城'));
      expect(text, contains('已知事实：甲'));
      expect(text, contains('人物关系：张|谨慎'));
      expect(text, contains('进行中事件：乙'));
    });

    test('空状态渲染为空串', () {
      expect(WorldStateService.renderForPrompt(WorldState()), '');
    });

    test('inlineSummary 给游玩页顶部用', () {
      final s = WorldState(time: '1949年11月23日', location: '重庆');
      expect(s.inlineSummary, '重庆 · 1949年11月23日');
    });
  });

  group('WorldState · 序列化', () {
    test('往返等价', () {
      final s = WorldState(
        time: '夜',
        location: '山城',
        facts: <String>['甲'],
        relations: <String, String>{'张': '谨慎'},
        events: <String>['乙'],
      );
      final restored = WorldState.fromJson(s.toJson());
      expect(restored.time, s.time);
      expect(restored.facts, s.facts);
      expect(restored.relations, s.relations);
      expect(restored.events, s.events);
    });

    test('copy 是深拷贝', () {
      final s = WorldState(facts: <String>['甲']);
      final c = s.copy();
      c.facts.add('乙');
      expect(s.facts.length, 1);
    });
  });

  group('GameSession · 世界线分支与切换', () {
    SaveSlot newSlot() => SaveSlot(
          id: 's1',
          title: '测试局',
          worldBook: WorldBook(
            id: 'b1',
            name: '测试世界',
            worldview: '背景',
            playerRole: '主角',
          ),
        );

    void addChapter(GameSession s, String tag, String stateRaw) {
      s.appendChapter(
        content: '正文-$tag',
        playerAction: '行动-$tag',
        date: '第$tag天',
        choices: <String>['选项A-$tag', '选项B-$tag'],
        glossary: const <GlossaryEntry>[],
        cast: const <CastEntry>[],
        rawOutput: 'raw-$tag',
        stateRaw: stateRaw,
      );
    }

    /// 造一个三幕的局。
    GameSession threeChapters() {
      final s = GameSession(newSlot());
      addChapter(s, '一', '时间：第一天\n地点：甲地');
      addChapter(s, '二', '时间：第二天\n地点：乙地');
      addChapter(s, '三', '时间：第三天\n地点：丙地');
      return s;
    }

    test('appendChapter 写入状态快照', () {
      final s = GameSession(newSlot());
      addChapter(s, '一', '时间：第一天\n地点：甲地');
      expect(s.chapterCount, 1);
      expect(s.worldState.time, '第一天');
      expect(s.history.last.worldStateAfter?.time, '第一天');
      expect(s.history.last.worldStateAfter?.location, '甲地');
    });

    test('新局默认只有一条主线', () {
      final s = GameSession(newSlot());
      expect(s.lines.length, 1);
      expect(s.line.isBranch, isFalse);
      expect(s.line.name, '主线');
    });

    // ---------- 分岔（核心） ----------

    test('分岔：新线保留到分岔点，状态等于那一幕的快照', () {
      final s = threeChapters();
      final branch = s.branchFrom(0); // 从第 1 幕分岔

      expect(branch.chapterCount, 1);
      expect(branch.branchedAtChapter, 1);
      expect(branch.isBranch, isTrue);
      // 状态必须回到第 1 幕结束时，不能还停在第 3 幕
      expect(branch.worldState.time, '第一天');
      expect(branch.worldState.location, '甲地');
      // 分岔后自动切到新线
      expect(s.line.id, branch.id);
      expect(s.chapterCount, 1);
    });

    test('分岔：原线完全不动（关键回归）', () {
      final s = threeChapters();
      final mainId = s.line.id;
      s.branchFrom(0);

      final main = s.lines.firstWhere((l) => l.id == mainId);
      expect(main.chapterCount, 3);
      expect(main.worldState.time, '第三天');
      expect(main.history.last.content, '正文-三');
    });

    test('分岔：从中间幕分', () {
      final s = threeChapters();
      final branch = s.branchFrom(1); // 从第 2 幕分岔
      expect(branch.chapterCount, 2);
      expect(branch.branchedAtChapter, 2);
      expect(branch.worldState.time, '第二天');
    });

    test('两条线互不干扰：一边继续推演，另一边不受影响', () {
      final s = threeChapters();
      final mainId = s.line.id;
      s.branchFrom(0); // 切到新线（只有 1 幕）

      addChapter(s, '甲', '时间：第九天\n地点：丁地');

      expect(s.chapterCount, 2);
      expect(s.worldState.time, '第九天');

      final main = s.lines.firstWhere((l) => l.id == mainId);
      expect(main.chapterCount, 3);
      expect(main.worldState.time, '第三天');
    });

    test('两条线的选择记录互相独立', () {
      final s = threeChapters();
      final mainId = s.line.id;
      s.branchFrom(0);
      addChapter(s, '甲', '时间：第九天');

      // 新线的可选行动来自新线自己的最后一幕
      expect(s.choices.first, '选项A-甲');

      s.switchLine(mainId);
      expect(s.choices.first, '选项A-三');
    });

    // ---------- 切换 ----------

    test('切换世界线：正文/状态/编年史/选项全部跟着换', () {
      final s = threeChapters();
      final mainId = s.line.id;
      s.attachChronicle('主线编年史');
      s.branchFrom(0);

      // 当前在新线
      expect(s.chapterCount, 1);
      s.attachChronicle('分支编年史');
      expect(s.chronicle, '分支编年史');

      // 切回主线
      s.switchLine(mainId);
      expect(s.chapterCount, 3);
      expect(s.chronicle, '主线编年史');
      expect(s.worldState.time, '第三天');
      expect(s.choices.first, '选项A-三');
    });

    test('切换后 worldState 是那条线自己的，不是共享引用', () {
      final s = threeChapters();
      final mainId = s.line.id;
      s.branchFrom(0);
      addChapter(s, '甲', '时间：第九天\n关系：李某|投诚');

      s.switchLine(mainId);
      // 主线不该看到分支里新增的关系
      expect(s.worldState.relations.containsKey('李某'), isFalse);
      expect(s.worldState.time, '第三天');
    });

    // ---------- 在分岔点重生成 ----------

    test('在分岔点重生成：状态退回 baseState 而不是清空（关键回归）', () {
      final s = threeChapters();
      s.branchFrom(1); // 新线保留 2 幕，baseState = 第 1 幕结束时
      expect(s.worldState.time, '第二天');

      s.popLastForReroll(); // 重生成第 2 幕
      // 必须退到「第 1 幕结束时」，不能变成空 ——
      // 否则这条线会丢掉分岔时继承来的全部局势
      expect(s.chapterCount, 1);
      expect(s.worldState.time, '第一天');
      expect(s.worldState.location, '甲地');
    });

    // ---------- 删除 / 重命名 ----------

    test('删除世界线', () {
      final s = threeChapters();
      final mainId = s.line.id;
      final branch = s.branchFrom(0);
      expect(s.lines.length, 2);

      expect(s.deleteLine(branch.id), isTrue);
      expect(s.lines.length, 1);
      // 删掉当前线后自动切到剩下那条
      expect(s.line.id, mainId);
      expect(s.chapterCount, 3);
    });

    test('最后一条世界线删不掉', () {
      final s = threeChapters();
      expect(s.deleteLine(s.line.id), isFalse);
      expect(s.lines.length, 1);
    });

    test('重命名世界线', () {
      final s = threeChapters();
      final branch = s.branchFrom(0);
      s.renameLine(branch.id, '走西南路线');
      expect(s.line.name, '走西南路线');
      // 空白名不生效
      s.renameLine(branch.id, '   ');
      expect(s.line.name, '走西南路线');
    });

    test('分岔名不重复', () {
      final s = threeChapters();
      s.branchFrom(0);
      final n1 = s.line.name;
      s.branchFrom(0);
      expect(s.line.name, isNot(n1));
    });

    // ---------- 快照自愈 ----------

    test('旧存档缺快照：从第一幕分岔也能拿到正确的空状态', () {
      // 模拟「世界书自带开篇」：第一幕是 UI 层直接造的，没有快照
      final slot = newSlot();
      slot.activeLine.history = <ChapterNode>[
        ChapterNode(
          chapterIndex: 1,
          title: '第一幕',
          content: '开场',
          choices: <String>['a', 'b'],
        ),
      ];
      final s = GameSession(slot); // 构造时自愈
      expect(s.history.first.worldStateAfter, isNotNull);

      final branch = s.branchFrom(0);
      expect(branch.worldState.isEmpty, isTrue);
      expect(branch.chronicle, '');
    });

    test('自愈后每一幕都有快照', () {
      final slot = newSlot();
      slot.activeLine.history = <ChapterNode>[
        ChapterNode(
          chapterIndex: 1,
          title: '一',
          content: '正文',
          choices: <String>['a', 'b'],
        ),
        ChapterNode(
          chapterIndex: 2,
          title: '二',
          content: '正文',
          choices: <String>['c', 'd'],
        ),
      ];
      GameSession(slot);
      for (final n in slot.activeLine.history) {
        expect(n.worldStateAfter, isNotNull);
        expect(n.chronicleAfter, isNotNull);
      }
    });

    // ---------- reroll / 编年史 / 开局 ----------

    test('reroll 不继承上一次留下的状态', () {
      final s = GameSession(newSlot());
      addChapter(s, '一', '时间：第一天');
      addChapter(s, '二', '时间：第二天\n关系：张某|已死');
      expect(s.worldState.relations['张某'], '已死');

      s.popLastForReroll();
      expect(s.worldState.time, '第一天');
      expect(s.worldState.relations.containsKey('张某'), isFalse);
      expect(s.chapterCount, 1);
    });

    test('reroll 到开局时状态与编年史清空', () {
      final s = GameSession(newSlot());
      addChapter(s, '一', '时间：第一天');
      s.attachChronicle('编年史');
      s.popLastForReroll();
      expect(s.chapterCount, 0);
      expect(s.worldState.isEmpty, isTrue);
      expect(s.chronicle, '');
      expect(s.choices, isEmpty);
    });

    test('attachChronicle 只记到最后一幕快照上', () {
      final s = GameSession(newSlot());
      addChapter(s, '一', '时间：第一天');
      addChapter(s, '二', '时间：第二天');
      s.attachChronicle('新编年史');
      expect(s.history.last.chronicleAfter, '新编年史');
      expect(s.history.first.chronicleAfter, '');
    });

    test('seedOpening 直接落第一幕且带快照', () {
      final s = GameSession(newSlot());
      s.seedOpening(
        content: '开场',
        date: '第一天',
        choices: <String>['x', 'y'],
      );
      expect(s.chapterCount, 1);
      expect(s.choices, <String>['x', 'y']);
      expect(s.history.first.worldStateAfter, isNotNull);
      expect(s.history.first.chronicleAfter, '');
    });

    test('toSlot 把状态写回存档', () {
      final s = GameSession(newSlot());
      addChapter(s, '一', '时间：第一天');
      final slot = s.toSlot();
      expect(slot.history.length, 1);
      expect(slot.worldState.time, '第一天');
    });
  });

  group('存档槽 · 世界线序列化与旧档迁移', () {
    SaveSlot base() => SaveSlot(
          id: 's1',
          title: '测试局',
          worldBook: WorldBook(id: 'b1', name: '测试世界'),
        );

    test('新档默认带一条主线', () {
      final slot = base();
      expect(slot.lines.length, 1);
      expect(slot.activeLineId, slot.lines.first.id);
    });

    test('多条世界线往返 JSON 不丢', () {
      final slot = base();
      final s = GameSession(slot);
      s.appendChapter(
        content: '正文',
        playerAction: '行动',
        date: '第一天',
        choices: <String>['a', 'b'],
        glossary: const <GlossaryEntry>[],
        cast: const <CastEntry>[],
        rawOutput: '',
        stateRaw: '时间：第一天',
      );
      s.branchFrom(0);

      final restored = SaveSlot.fromJson(slot.toJson());
      expect(restored.lines.length, 2);
      expect(restored.activeLineId, slot.activeLineId);
      expect(restored.activeLine.isBranch, isTrue);
      expect(restored.activeLine.parentLineId, slot.lines.first.id);
    });

    test('activeLineId 指向不存在的线时自动兜到第一条', () {
      final slot = SaveSlot(
        id: 's1',
        title: 't',
        worldBook: WorldBook(id: 'b', name: 'w'),
        activeLineId: '不存在',
      );
      expect(slot.activeLineId, slot.lines.first.id);
    });

    test('旧存档（v1）迁移：顶层三件套包成主线', () {
      // v1 存档长这样：history / chronicle / worldState 全在顶层，没有 lines
      final legacy = <String, dynamic>{
        'id': 'old1',
        'title': '旧档',
        'worldBook': WorldBook(id: 'b1', name: '旧世界').toJson(),
        'history': <Map<String, dynamic>>[
          ChapterNode(
            chapterIndex: 1,
            title: '第一幕',
            content: '旧正文',
            choices: <String>['x'],
          ).toJson(),
        ],
        'chronicle': '旧编年史',
        'worldState': WorldState(time: '旧时间').toJson(),
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
        'updatedAt': DateTime(2026, 1, 2).toIso8601String(),
      };

      final slot = SaveSlot.fromJson(legacy);
      expect(slot.lines.length, 1);
      expect(slot.activeLine.name, '主线');
      expect(slot.chapterCount, 1);
      expect(slot.history.first.content, '旧正文');
      expect(slot.chronicle, '旧编年史');
      expect(slot.worldState.time, '旧时间');
    });

    test('摘要行会带上世界线数量', () {
      final slot = base();
      GameSession(slot).appendChapter(
        content: '正文',
        playerAction: '行动',
        date: '',
        choices: <String>['a', 'b'],
        glossary: const <GlossaryEntry>[],
        cast: const <CastEntry>[],
        rawOutput: '',
        stateRaw: '',
      );
      expect(slot.summaryLine.contains('世界线'), isFalse);
      GameSession(slot).branchFrom(0);
      expect(slot.summaryLine.contains('2 条世界线'), isTrue);
    });
  });

  group('存档槽 · 回滚备份识别', () {
    // 2026-09-25 实机问题：回滚自动生成的备份混在正常列表里，
    // 用户只玩到第二幕却看到三个「推演」。

    test('备份 id 带前缀，能被识别', () {
      final id = SaveSlot.backupIdFor('abc123');
      expect(id, 'backup_abc123');
      final slot = SaveSlot(
        id: id,
        title: '【回滚备份】某局',
        worldBook: WorldBook(id: 'b', name: '世界'),
      );
      expect(slot.isBackup, isTrue);
    });

    test('普通存档不算备份', () {
      final slot = SaveSlot(
        id: 'abc123',
        title: '某局',
        worldBook: WorldBook(id: 'b', name: '世界'),
      );
      expect(slot.isBackup, isFalse);
    });

    test('备份标记能穿过 JSON 往返', () {
      final slot = SaveSlot(
        id: SaveSlot.backupIdFor('xyz'),
        title: '备份',
        worldBook: WorldBook(id: 'b', name: '世界'),
      );
      final restored = SaveSlot.fromJson(slot.toJson());
      expect(restored.isBackup, isTrue);
    });
  });

  group('TextLayout · 正文分段与缩进', () {
    // 2026-09-25：「首行缩进」开关加了没效果，根因就在分段 ——
    // 旧代码只按 `\n\n` 切段，模型经常用单个 `\n`，整篇被当成一个段落，
    // 只在最开头缩进一次，看起来就像没生效。

    test('单个换行也能切段', () {
      expect(TextLayout.paragraphs('第一段\n第二段\n第三段'),
          <String>['第一段', '第二段', '第三段']);
    });

    test('空行切段', () {
      expect(TextLayout.paragraphs('第一段\n\n第二段'),
          <String>['第一段', '第二段']);
    });

    test('CRLF 也能切', () {
      expect(TextLayout.paragraphs('第一段\r\n第二段'),
          <String>['第一段', '第二段']);
    });

    test('连续空行不会产生空段落', () {
      expect(TextLayout.paragraphs('甲\n\n\n\n乙\n   \n丙'),
          <String>['甲', '乙', '丙']);
    });

    test('缩进用全角空格', () {
      expect(TextLayout.indent(2), '　　');
      expect(TextLayout.indent(2).length, 2);
      expect(TextLayout.indent(0), '');
    });

    test('缩进越界会被夹住', () {
      expect(TextLayout.indent(-3), '');
      expect(TextLayout.indent(99).length, 4);
    });

    test('段间距三档', () {
      expect(TextLayout.spacing('tight'), lessThan(TextLayout.spacing('normal')));
      expect(TextLayout.spacing('loose'), greaterThan(TextLayout.spacing('normal')));
      expect(TextLayout.spacing('未知值'), TextLayout.spacing('normal'));
    });
  });

  group('ResponseParser · 模板占位文字过滤', () {
    // 2026-09-25 实机事故：内核提示词给了可直接照抄的内容行，模型把它们
    // 原样抄进了输出。用户截图里选项混着「第一条可供主角决断的具体行动
    // （一句话，30~60 字）」，正文混着「（正文：约 500 字的白描叙事）」。
    // 内核已改空骨架，这里是第二道防线的回归。

    test('选项里的模板行被剔除', () {
      const raw = '''
<date>1976年9月28日</date>
夜色如墨，一辆不起眼的黑色轿车悄然驶离西山。

<choices>
第一条可供主角决断的具体行动（一句话，30~60 字）
向叶帅提议立即起草政治定性文件，为行动提供法理依据。
第二条可供主角决断的具体行动
要求汪东兴派遣可信人员秘密前往上海，监控通讯线路。
第三条（可选）
决定暂不通知华国锋具体抓捕时间，仅要求其签署调令。
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.choices.length, 3);
      for (final c in p.choices) {
        expect(c.contains('可供主角决断的具体行动'), isFalse);
        expect(c.contains('可选'), isFalse);
      }
      expect(p.choices.first.startsWith('向叶帅提议'), isTrue);
      expect(p.choices.last.startsWith('决定暂不通知'), isTrue);
    });

    test('正文里的模板行被剔除', () {
      const raw = '''
<date>1976年9月28日</date>
（正文：约 500 字的白描叙事）
夜色如墨，一辆不起眼的黑色轿车悄然驶离西山。

<choices>
甲
乙
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.body.contains('白描叙事'), isFalse);
      expect(p.body.startsWith('夜色如墨'), isTrue);
    });

    test('正文里的合法书名号不会被误删', () {
      const raw = '''
<date>某日</date>
他翻开《史记》，又想起〈滕王阁序〉里的句子。

<choices>
甲
乙
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.body.contains('滕王阁序'), isTrue);
    });

    test('判定函数', () {
      expect(
        ResponseParser.isTemplateNoise('第一条可供主角决断的具体行动'),
        isTrue,
      );
      expect(ResponseParser.isTemplateNoise('第三条（可选）'), isTrue);
      expect(ResponseParser.isTemplateNoise('向叶帅提议起草文件'), isFalse);
      expect(
        ResponseParser.isBodyNoise('（正文：约 500 字的白描叙事）'),
        isTrue,
      );
      expect(ResponseParser.isBodyNoise('夜色如墨'), isFalse);
    });

    test('状态块里的模板占位值被剔除', () {
      final s = WorldStateService.parse('''
时间：此刻的剧中时间
地点：主角此刻所在
事实：条目；条目（最多 12 条，按重要性从高到低）
关系：姓名|此刻态度
事件：进行中的事件
''');
      expect(s.time, '');
      expect(s.location, '');
      expect(s.facts, isEmpty);
      expect(s.relations, isEmpty);
      expect(s.events, isEmpty);
    });
  });

  group('ResponseParser · think 与 thought 思维链隔离与提取', () {
    test('标准 <think> 标签抽取思考并保持正文纯净', () {
      const raw = '''
<think>
当前局势危急，需要权衡利弊。
决定让主角前往茶馆接头。
</think>

<date>1949年11月1日</date>

秋风肃杀，林怀民裹紧了大衣，快步走向转角的茶馆。

<choices>
1. 推门而入
2. 在门外稍作观察
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.thought, contains('当前局势危急'));
      expect(p.thought, contains('决定让主角前往茶馆接头'));
      expect(p.body, contains('秋风肃杀'));
      expect(p.body, isNot(contains('<think>')));
      expect(p.body, isNot(contains('当前局势危急')));
      expect(p.date, '1949年11月1日');
      expect(p.choices.length, 2);
    });

    test('变体 <thought> 标签也能正常识别', () {
      const raw = '''
<thought>
深入分析各方势力。
</thought>
夜色渐深，灯火阑珊。
<choices>
1. 歇息
2. 巡视
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.thought, '深入分析各方势力。');
      expect(p.body, '夜色渐深，灯火阑珊。');
      expect(p.body, isNot(contains('深入分析')));
    });

    test('未闭合的 <think> 在流式预览中隐藏', () {
      const raw = '''
天色微明。
<think>
正在推演下一步逻辑，尚未结束…
''';
      final (thought, body) = ResponseParser.splitLive(raw);
      expect(body, '天色微明。');
      expect(body, isNot(contains('正在推演')));
      expect(thought, contains('正在推演'));
    });

    test('流式中正在流入的半截 think 标签不闪烁', () {
      expect(ResponseParser.splitLive('晨光初照。<th').$2, '晨光初照。');
      expect(ResponseParser.splitLive('晨光初照。<think').$2, '晨光初照。');
      expect(ResponseParser.splitLive('晨光初照。</think').$2, '晨光初照。');
    });
  });

  group('ChapterNode · thought 思维链字段与序列化', () {
    test('JSON 序列化往返保留 thought', () {
      final node = ChapterNode(
        chapterIndex: 1,
        title: '第一幕',
        content: '正文内容',
        thought: '思考过程记录',
      );
      final json = node.toJson();
      expect(json['thought'], '思考过程记录');

      final restored = ChapterNode.fromJson(json);
      expect(restored.thought, '思考过程记录');
      expect(restored.content, '正文内容');
    });

    test('copyWith 正确复制与修改 thought', () {
      final node = ChapterNode(
        chapterIndex: 1,
        title: '第一幕',
        content: '正文',
        thought: '旧思考',
      );
      final copied = node.copyWith(thought: '新思考');
      expect(copied.thought, '新思考');
      expect(copied.content, '正文');
    });
  });

  group('GameSession · 错字就地微调', () {
    test('editChapterContent 仅修改正文，快照与三位一体不变量完好', () {
      final slot = SaveSlot(
        id: 'slot_typo',
        title: '错字测试',
        worldBook: WorldBook(id: 'wb1', name: '测试'),
      );
      final session = GameSession(slot);
      session.appendChapter(
        content: '原先有错别字的正文',
        playerAction: '行动A',
        date: '1949年',
        choices: <String>['选项1', '选项2'],
        glossary: <GlossaryEntry>[],
        cast: <CastEntry>[],
        rawOutput: 'raw',
        stateRaw: '时间：1949年\n地点：北平',
        thought: '思考记录',
      );

      final stateBefore = session.worldState.copy();
      final chronicleBefore = session.chronicle;
      final nodeBefore = session.history.first;

      session.editChapterContent(0, '修正错别字之后的完美正文');

      final nodeAfter = session.history.first;
      expect(nodeAfter.content, '修正错别字之后的完美正文');
      expect(nodeAfter.playerAction, nodeBefore.playerAction);
      expect(nodeAfter.date, nodeBefore.date);
      expect(nodeAfter.thought, '思考记录');
      expect(nodeAfter.worldStateAfter?.location, '北平');
      expect(nodeAfter.chronicleAfter, chronicleBefore);
      expect(session.worldState.location, stateBefore.location);
    });
  });

  group('StoryExportService · 推演故事排版导出', () {
    final book = WorldBook(
      id: 'b1',
      name: '谍战风云',
      era: '1949年秋',
      playerRole: '潜伏特工',
    );
    final line = WorldLine(id: 'l1', name: '主线');
    final history = <ChapterNode>[
      ChapterNode(
        chapterIndex: 1,
        title: '第一幕',
        date: '1949年10月1日',
        content: '清晨的薄雾笼罩着街道。\n他推开窗户，看着远方的旗帜。',
      ),
      ChapterNode(
        chapterIndex: 2,
        title: '第二幕',
        date: '1949年10月2日',
        playerAction: '秘密联络联络员',
        content: '茶馆里人声鼎沸，切口顺利对上。',
      ),
    ];
    final worldState = WorldState(
      time: '1949年10月2日',
      location: '北平前门',
      facts: <String>['已取得信任'],
    );

    test('toMarkdown 导出结构完整包含题头、幕次、抉择与状态', () {
      final md = StoryExportService.toMarkdown(
        book: book,
        line: line,
        history: history,
        chronicle: '1949年10月：北平解放。',
        worldState: worldState,
      );

      expect(md, contains('# 谍战风云'));
      expect(md, contains('> 时代背景：1949年秋'));
      expect(md, contains('> 扮演角色：潜伏特工'));
      expect(md, contains('## 第一幕 · 1949年10月1日'));
      expect(md, contains('> **【你的抉择】** 秘密联络联络员'));
      expect(md, contains('茶馆里人声鼎沸'));
      expect(md, contains('## 编年史大事记'));
      expect(md, contains('北平解放'));
      expect(md, contains('## 当前世界观察局势'));
      expect(md, contains('北平前门'));
    });

    test('toPlainText 纯文本小说排版带全角缩进与分段', () {
      final txt = StoryExportService.toPlainText(
        book: book,
        line: line,
        history: history,
        chronicle: '1949年10月：北平解放。',
        worldState: worldState,
      );

      expect(txt, contains('《谍战风云》'));
      expect(txt, contains('第一幕 · 1949年10月1日'));
      expect(txt, contains('　　清晨的薄雾笼罩着街道。'));
      expect(txt, contains('【你的抉择】秘密联络联络员'));
      expect(txt, contains('【编年史大事记】'));
      expect(txt, contains('【当前世界观察局势】'));
    });
  });

  group('AppConfig & WakelockService · 阅读常亮', () {
    test('keepScreenOn 默认开启并支持 JSON 序列化', () {
      final cfg = AppConfig();
      expect(cfg.keepScreenOn, isTrue);

      final json = cfg.toJson();
      expect(json['keepScreenOn'], isTrue);

      final restored = AppConfig.fromJson(json);
      expect(restored.keepScreenOn, isTrue);

      final updated = cfg.copyWith(keepScreenOn: false);
      expect(updated.keepScreenOn, isFalse);
    });

    test('WakelockService 调用安全不崩溃', () async {
      await WakelockService.enable();
      await WakelockService.disable();
    });
  });

  group('健壮性与边界回归测试', () {
    test('ResponseParser · 多个与大写 think 块及未闭合解析', () {
      final p = ResponseParser.parse('<THINK>第一段思考</THINK>正文在此<thought>第二段思考</thought>');
      expect(p.thought, '第一段思考\n\n第二段思考');
      expect(p.body, '正文在此');

      final p2 = ResponseParser.parse('<think>未闭合的思考内容');
      expect(p2.thought, '未闭合的思考内容');
      expect(p2.body, isEmpty);
    });

    test('StoryExportService · 空推演记录安全导出', () {
      final md = StoryExportService.toMarkdown(
        book: WorldBook(id: 'wb0', name: '空白书'),
        line: WorldLine(id: 'l0', name: '主线'),
        history: <ChapterNode>[],
      );
      expect(md, contains('# 空白书'));
      expect(md, contains('共 0 幕'));

      final txt = StoryExportService.toPlainText(
        book: WorldBook(id: 'wb0', name: '空白书'),
        line: WorldLine(id: 'l0', name: '主线'),
        history: <ChapterNode>[],
      );
      expect(txt, contains('《空白书》'));
      expect(txt, contains('共 0 幕'));
    });

    test('GameSession · editChapterContent 越界与多世界线独立性', () {
      final slot = SaveSlot(
        id: 'slot_bounds',
        title: '测试',
        worldBook: WorldBook(id: 'wb1', name: '测试'),
      );
      final session = GameSession(slot);
      session.appendChapter(
        content: '第一幕正文',
        playerAction: '行动1',
        date: '',
        choices: <String>['A', 'B'],
        glossary: <GlossaryEntry>[],
        cast: <CastEntry>[],
        rawOutput: '',
        stateRaw: '',
      );
      session.appendChapter(
        content: '第二幕正文',
        playerAction: '行动2',
        date: '',
        choices: <String>['A', 'B'],
        glossary: <GlossaryEntry>[],
        cast: <CastEntry>[],
        rawOutput: '',
        stateRaw: '',
      );

      // 越界安全
      session.editChapterContent(-1, '非法');
      session.editChapterContent(99, '非法');
      expect(session.history[0].content, '第一幕正文');
      expect(session.history[1].content, '第二幕正文');

      // 分岔后就地编辑互不影响
      final branch = session.branchFrom(0);
      session.switchLine(branch.id);
      session.editChapterContent(0, '新分支修改后的正文');
      expect(session.history[0].content, '新分支修改后的正文');

      // 切换回主线，主线正文未被破坏
      session.switchLine(slot.lines.first.id);
      expect(session.history[0].content, '第一幕正文');
    });
  });

  group('FileExportService · 物理文件导出与系统分享', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('nijing_export_test_');
      FileExportService.testExportDirectory = tempDir;
    });

    tearDown(() {
      FileExportService.testExportDirectory = null;
      try {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    test('文件名安全过滤与时间戳格式化', () {
      expect(FileExportService.sanitizeFileName('大唐:开元/盛世*测试?'), '大唐_开元_盛世_测试_');
      expect(FileExportService.sanitizeFileName(''), '未命名');
      expect(FileExportService.sanitizeFileName('   '), '未命名');
      expect(FileExportService.sanitizeFileName('测试文件...  '), '测试文件');
      expect(FileExportService.sanitizeFileName('a' * 100).length, 50);

      final ts = FileExportService.formatTimestamp(DateTime(2026, 9, 26, 22, 0, 5));
      expect(ts, '20260926_220005');
    });

    test('WorldBook 与 SaveSlot 支持 JSON 数组格式安全导入', () {
      // 1. WorldBook 数组导入
      const bookArr = '[{"name":"世界1","worldview":"设定1"},{"name":"世界2","worldview":"设定2"}]';
      final b = WorldBook.fromImportText(bookArr);
      expect(b.name, '世界1');
      expect(b.worldview, '设定1');

      // 2. SaveSlot 数组导入
      final slot1 = SaveSlot(id: 's1', title: '档1', worldBook: WorldBook(id: 'w1', name: '书1'));
      final slot2 = SaveSlot(id: 's2', title: '档2', worldBook: WorldBook(id: 'w2', name: '书2'));
      final slotsJson = jsonEncode([slot1.toJson(), slot2.toJson()]);
      final s = SaveService.importSlot(slotsJson);
      expect(s.id, 's1');
      expect(s.title, '档1');

      // 3. 批量导出的 JSON 必须是合法 JSON 数组
      final booksJson = jsonEncode([b.toJson()]);
      final decodedList = jsonDecode(booksJson);
      expect(decodedList, isA<List>());
      expect((decodedList as List).length, 1);
    });

    test('物理文件落盘与内容精确读回（Markdown / TXT / JSON）', () async {
      // 1. Markdown 导出
      const mdContent = '# 大明王朝\n\n> 时代：嘉靖\n\n## 第一幕\n\n正文段落。';
      final mdRes = await FileExportService.exportFile(
        fileName: '大明_测试.md',
        content: mdContent,
        mimeType: 'text/markdown',
      );
      expect(mdRes.success, isTrue);
      expect(mdRes.path, isNotNull);
      final mdFile = File(mdRes.path!);
      expect(mdFile.existsSync(), isTrue);
      expect(await mdFile.readAsString(), mdContent);

      // 2. JSON 世界书导出
      const jsonContent = '{"name":"架空江湖","worldview":"刀光剑影"}';
      final jsonRes = await FileExportService.exportFile(
        fileName: '世界书_测试.json',
        content: jsonContent,
        mimeType: 'application/json',
      );
      expect(jsonRes.success, isTrue);
      expect(jsonRes.path, isNotNull);
      final jsonFile = File(jsonRes.path!);
      expect(jsonFile.existsSync(), isTrue);
      expect(await jsonFile.readAsString(), jsonContent);

      // 3. 纯文本小说导出
      const txtContent = '《拟境故事》\n\n　　秋风渐起，落叶萧萧。';
      final txtRes = await FileExportService.exportFile(
        fileName: '故事_测试.txt',
        content: txtContent,
        mimeType: 'text/plain',
      );
      expect(txtRes.success, isTrue);
      final txtFile = File(txtRes.path!);
      expect(txtFile.existsSync(), isTrue);
      expect(await txtFile.readAsString(), txtContent);
    });

    test('系统分享与异常调用安全不崩溃', () async {
      final shared = await FileExportService.shareText(
        title: '测试分享',
        text: '这是一段测试分享内容',
      );
      // 非 Android 原生环境下安全返回 false，绝不抛未捕获异常
      expect(shared, isFalse);
    });
  });

  group('主宰模式与实机缺陷修复专项测试 (v1.3.0 / v1.3.1)', () {
    test('ResponseParser · 正文标识泄露清洗（正文：/【正文】/Markdown加粗/标题/变体等）', () {
      // 各种常见前缀变体
      expect(ResponseParser.cleanBodyPrefix('正文：雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('正文: 雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('【正文】\n雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('【正文】：雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('正文如下：\n雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('（正文）雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('(正文): 雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('【正文内容】雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('正文内容：雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('【正文开始】\n雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('正文\n雾气笼罩着江面。'), '雾气笼罩着江面。');

      // Markdown 加粗与标题变体清洗（防大模型输出 Markdown 格式残留）
      expect(ResponseParser.cleanBodyPrefix('**正文**：雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('**正文：**雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('**【正文】**\n雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('**正文如下：**\n雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('### 正文\n雾气笼罩着江面。'), '雾气笼罩着江面。');
      expect(ResponseParser.cleanBodyPrefix('### 【正文】\n雾气笼罩着江面。'), '雾气笼罩着江面。');

      // 嵌套或重复前缀
      expect(ResponseParser.cleanBodyPrefix('【正文】\n**正文如下：**\n雾气笼罩着江面。'), '雾气笼罩着江面。');

      // 关键防误杀：正文人物名为“正文”或正常语句不被误删
      expect(ResponseParser.cleanBodyPrefix('正文推门走入屋内，神色凝重。'), '正文推门走入屋内，神色凝重。');
      expect(ResponseParser.cleanBodyPrefix('正文在此处展开讨论。'), '正文在此处展开讨论。');

      // 完整流水线测试（包含 Markdown 前缀）
      const rawWithPrefix = '''
<date>1949年11月30日</date>
**【正文】**
夜色深沉，白公馆外的松柏在夜风中摇曳。
<choices>
1. 立即组织撤离
2. 坚守待命
</choices>
''';
      final parsed = ResponseParser.parse(rawWithPrefix);
      expect(parsed.body, '夜色深沉，白公馆外的松柏在夜风中摇曳。');
      expect(parsed.choices.length, 2);
    });

    test('ResponseParser · 天道敕令与主宰回响模板噪音清洗', () {
      expect(ResponseParser.isBodyNoise('【天道敕令 · 玩家意志绝对主宰】'), isTrue);
      expect(ResponseParser.isBodyNoise('【主宰天道敕令】'), isTrue);
      expect(ResponseParser.isBodyNoise('天道敕令：全力推演。'), isTrue);
      expect(ResponseParser.isTemplateNoise('【天道敕令 · 玩家意志绝对主宰】'), isTrue);
      expect(ResponseParser.isTemplateNoise('【主宰天道敕令】'), isTrue);

      // 防误杀合法文学描写
      expect(ResponseParser.isBodyNoise('天道酬勤，众人日夜不辍。'), isFalse);
    });

    test('AppConfig · godMode 字段与序列化/复制', () {
      final config = AppConfig();
      expect(config.godMode, isFalse);

      final modified = config.copyWith(godMode: true);
      expect(modified.godMode, isTrue);

      final json = modified.toJson();
      expect(json['godMode'], isTrue);

      final restored = AppConfig.fromJson(json);
      expect(restored.godMode, isTrue);

      final encoded = modified.encode();
      final decoded = AppConfig.fromJson(jsonDecode(encoded) as Map<String, dynamic>);
      expect(decoded.godMode, isTrue);
    });

    test('PromptKernel & PromptBuilder · 主宰模式天道敕令注入与提示词装配', () {
      final config = AppConfig(maxWords: 500, godMode: false);
      final book = WorldBook(id: 'test', name: '测试世界', worldview: '测试背景', playerRole: '主角');

      // 普通模式不包含天道敕令
      final normalKernel = PromptKernel.build(config, godMode: false);
      expect(normalKernel.contains('【天道敕令 · 玩家意志绝对主宰】'), isFalse);

      // 主宰模式包含天道敕令及核心法则
      final godKernel = PromptKernel.build(config, godMode: true);
      expect(godKernel.contains('【天道敕令 · 玩家意志绝对主宰】'), isTrue);
      expect(godKernel.contains('既成事实法则'), isTrue);
      expect(godKernel.contains('绝对顺从展开'), isTrue);
      expect(godKernel.contains('严禁以任何理由反驳、否定、削弱'), isTrue);
      expect(godKernel.contains('状态一致性保障'), isTrue);

      // PromptBuilder.buildSystemPrompt 单次覆盖与全局继承
      final sysPromptInherit = PromptBuilder.buildSystemPrompt(config: config, book: book);
      expect(sysPromptInherit.contains('【天道敕令 · 玩家意志绝对主宰】'), isFalse);

      final sysPromptOverride = PromptBuilder.buildSystemPrompt(config: config, book: book, godMode: true);
      expect(sysPromptOverride.contains('【天道敕令 · 玩家意志绝对主宰】'), isTrue);

      // PromptBuilder.buildMessages 主宰指令注入
      final msgsNormal = PromptBuilder.buildMessages(
        systemPrompt: 'sys',
        history: <ChapterNode>[],
        playerAction: '攻入城门',
        godMode: false,
      );
      expect(msgsNormal.last['content'], contains('主角指示：“攻入城门”'));
      expect(msgsNormal.last['content'], isNot(contains('【主宰天道敕令】')));

      final msgsGod = PromptBuilder.buildMessages(
        systemPrompt: 'sys',
        history: <ChapterNode>[],
        playerAction: '攻入城门',
        godMode: true,
      );
      expect(msgsGod.last['content'], contains('【主宰天道敕令】'));
      expect(msgsGod.last['content'], contains('施加绝对意志：“攻入城门”'));
      expect(msgsGod.last['content'], contains('不可撼动的既成事实'));
    });

    test('PromptKernel · 单幕字数下限约束与严禁草率收束', () {
      final config500 = AppConfig(maxWords: 500);
      final kernel500 = PromptKernel.build(config500);
      expect(kernel500, contains('下限不得少于 425 字')); // 500 * 0.85 = 425
      expect(kernel500, contains('充分展开人物对话、神态细节'));
      expect(kernel500, contains('严禁敷衍草率收束'));

      final config800 = AppConfig(maxWords: 800);
      final kernel800 = PromptKernel.build(config800);
      expect(kernel800, contains('下限不得少于 680 字')); // 800 * 0.85 = 680
    });

    test('LlmClient · 根据 maxWords 动态配置充足缓冲的 max_tokens', () {
      expect(LlmClient.calculateMaxTokens(300), 2048); // 300 * 3 = 900 -> clamp 保底 2048
      expect(LlmClient.calculateMaxTokens(500), 2048); // 500 * 3 = 1500 -> clamp 保底 2048
      expect(LlmClient.calculateMaxTokens(800), 2400); // 800 * 3 = 2400
      expect(LlmClient.calculateMaxTokens(1000), 3000); // 1000 * 3 = 3000
      expect(LlmClient.calculateMaxTokens(1200), 3600); // 1200 * 3 = 3600
    });

    test('GameSession.appendChapter · 主宰模式事实状态一致性与防逆向误判保障', () {
      final slot = SaveSlot(
        id: 'slot_god_test',
        title: '主宰测试',
        worldBook: WorldBook(id: 'wb1', name: '书'),
      );
      final session = GameSession(slot);

      // 场景 1：模型返回的状态中未包含玩家的决定事实
      session.appendChapter(
        content: '剧情顺利推演展开。',
        playerAction: '已策反守将张牧并夺取西门钥匙',
        date: '1949年12月1日',
        choices: <String>['进城', '布防'],
        glossary: <GlossaryEntry>[],
        cast: <CastEntry>[],
        rawOutput: 'raw',
        stateRaw: '时间：深夜\n地点：西门外\n事实：夜色深沉；城门紧闭',
        godMode: true,
      );

      // 验证：玩家的主宰事实被自动保障记入已知事实首位
      expect(session.worldState.facts, contains('已策反守将张牧并夺取西门钥匙'));
      expect(session.worldState.facts.first, '已策反守将张牧并夺取西门钥匙');
      expect(session.history.last.worldStateAfter!.facts, contains('已策反守将张牧并夺取西门钥匙'));

      // 场景 2（核心防误判）：旧状态包含短词条（如「守军巡逻」），玩家输入长句「主角解决掉守军巡逻队并潜入内室」
      // 过去错误代码用 act.contains(f) 判定导致该主宰意志被误判为「已覆盖」并静默丢弃。
      // 现已修复为必须由 f/e 覆盖 act，确保长句意志必然成功落入事实首位。
      session.appendChapter(
        content: '主角悄无声息地穿过庭院。',
        playerAction: '主角解决掉守军巡逻队并潜入内室',
        date: '1949年12月1日',
        choices: <String>['搜查', '伏击'],
        glossary: <GlossaryEntry>[],
        cast: <CastEntry>[],
        rawOutput: 'raw',
        stateRaw: '时间：更深\n地点：内府\n事实：守军巡逻；夜色深沉',
        godMode: true,
      );
      expect(session.worldState.facts.first, '主角解决掉守军巡逻队并潜入内室');

      // 场景 3（事件防误判）：旧事件中包含「撤离」，玩家主宰意志为「命令全军全员撤离至南山根据地」
      session.appendChapter(
        content: '部队迅速转向。',
        playerAction: '命令全军全员撤离至南山根据地',
        date: '1949年12月2日',
        choices: <String>['构筑工事', '休整'],
        glossary: <GlossaryEntry>[],
        cast: <CastEntry>[],
        rawOutput: 'raw',
        stateRaw: '时间：清晨\n地点：郊外\n事件：撤离',
        godMode: true,
      );
      expect(session.worldState.facts.first, '命令全军全员撤离至南山根据地');
    });

    test('Thinking 思考模式专项测试 (v1.3.2) · AppConfig 序列化与默认开启', () {
      final cfg = AppConfig();
      expect(cfg.enableThinking, isTrue);

      final json = cfg.toJson();
      expect(json['enableThinking'], isTrue);

      final restored = AppConfig.fromJson(json);
      expect(restored.enableThinking, isTrue);

      final copy = cfg.copyWith(enableThinking: false);
      expect(copy.enableThinking, isFalse);
      expect(copy.toJson()['enableThinking'], isFalse);
    });

    test('Thinking 思考模式专项测试 (v1.3.2) · Providers 思考支持判定', () {
      expect(Providers.supportsThinkingSwitch('qwen3.8-flash'), isTrue);
      expect(Providers.supportsThinkingSwitch('Qwen3-Max'), isTrue);
      expect(Providers.supportsThinkingSwitch('deepseek-chat'), isFalse);
    });
  });

  // ==========================================================================
  // v1.3.3 五项实机缺陷修复专项
  // ==========================================================================

  group('v1.3.3 · splitLive 流式思考与正文分流（问题一）', () {
    test('思考块单独取出，正文不受污染', () {
      final (thought, body) = ResponseParser.splitLive(
        '<think>权衡局势，决定让他去接头。</think>\n\n秋风肃杀，他裹紧大衣。',
      );
      expect(thought, '权衡局势，决定让他去接头。');
      expect(body, '秋风肃杀，他裹紧大衣。');
    });

    test('未闭合的 think：全文归思考，正文为空（思考阶段）', () {
      final (thought, body) = ResponseParser.splitLive('<think>正在推演下一步');
      expect(thought, '正在推演下一步');
      expect(body, isEmpty);
    });

    test('正文开始后思考仍在块内 —— 两者不互相吞并', () {
      final (thought, body) = ResponseParser.splitLive(
        '<think>思考</think>\n正文开头\n<choices>\n1. 甲\n2. 乙\n</choices>',
      );
      expect(thought, '思考');
      expect(body, '正文开头');
    });

    test('半截标签在正文侧被隐藏', () {
      final (_, body) = ResponseParser.splitLive('晨光初照。<ch');
      expect(body, '晨光初照。');
    });
  });

  group('v1.3.3 · 未闭合 think 不得吞掉正文（问题三根因）', () {
    test('缺少 </think> 时，正文与结构块仍能正常解析', () {
      const raw = '''
<think>
我先权衡一下局势，再决定落笔方向。
<date>1949年11月1日</date>

秋风肃杀，他快步走向茶馆。

<choices>
1. 推门而入
2. 在门外观察
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.body, contains('秋风肃杀'));
      expect(p.body, isNot(contains('权衡')));
      expect(p.thought, contains('权衡'));
      expect(p.date, '1949年11月1日');
      expect(p.choices.length, 2);
      expect(p.hasUsableChoices, isTrue);
    });

    test('未闭合 think 位于文末时，不误伤前面的正文', () {
      const raw = '正文在此之前。\n<think>思考没有收尾';
      final p = ResponseParser.parse(raw);
      expect(p.body, '正文在此之前。');
      expect(p.thought, '思考没有收尾');
    });
  });

  group('v1.3.3 · 思考文本规范化（问题四）', () {
    test('剥掉 Markdown 标记与代码围栏，保留分析文字', () {
      const raw = '''
### 局势分析
- **要点一**：主角需要离开
```dart
final x = 1;
```
> 引用一行
表格 | 列
--- | ---
''';
      final cleaned = ResponseParser.cleanThoughtForShow(raw);
      expect(cleaned, isNot(contains('###')));
      expect(cleaned, isNot(contains('**')));
      expect(cleaned, isNot(contains('```')));
      // 表格分隔行整行删掉，但含竖线的普通文字保留
      expect(cleaned, isNot(contains('--- | ---')));
      expect(cleaned, contains('局势分析'));
      expect(cleaned, contains('要点一'));
      expect(cleaned, contains('主角需要离开'));
      expect(cleaned, contains('表格 | 列'));
    });

    test('幂等：重复规范化结果不变', () {
      const raw = '## 标题\n- 一条\n**加粗**';
      final once = ResponseParser.cleanThoughtForShow(raw);
      final twice = ResponseParser.cleanThoughtForShow(once);
      expect(twice, once);
    });

    test('内联反引号与零宽字符被清除', () {
      final cleaned = ResponseParser.cleanThoughtForShow('看`code`与\u200b零宽');
      expect(cleaned, '看code与零宽');
    });
  });

  group('v1.3.3 · 思考规范提示词（问题四第一道防线）', () {
    test('开启思考时注入思考规范，关闭时不注入', () {
      final cfg = AppConfig();
      final withThink = PromptKernel.build(cfg, thinking: true);
      final without = PromptKernel.build(cfg, thinking: false);
      expect(withThink, contains('思考规范'));
      expect(withThink, contains('简体中文'));
      expect(without, isNot(contains('思考规范')));
    });

    test('buildSystemPrompt 默认跟随 config.enableThinking', () {
      final book = WorldBook.blank();
      final on = PromptBuilder.buildSystemPrompt(
        config: AppConfig(enableThinking: true),
        book: book,
      );
      final off = PromptBuilder.buildSystemPrompt(
        config: AppConfig(enableThinking: false),
        book: book,
      );
      expect(on, contains('思考规范'));
      expect(off, isNot(contains('思考规范')));
    });
  });

  group('v1.3.3 · 运行日志（问题五）', () {
    tearDown(() {
      RuntimeLog.enabled = false;
      RuntimeLog.verbose = false;
      RuntimeLog.clear();
    });

    test('关闭时零记录', () {
      RuntimeLog.enabled = false;
      RuntimeLog.i('T', '不应记录');
      expect(RuntimeLog.count, 0);
    });

    test('开启时记录并可按详细级别过滤', () {
      RuntimeLog.enabled = true;
      RuntimeLog.i('T', '普通');
      RuntimeLog.i('T', '详细', detail: true);
      expect(RuntimeLog.count, 1);

      RuntimeLog.verbose = true;
      RuntimeLog.i('T', '详细', detail: true);
      expect(RuntimeLog.count, 2);
    });

    test('环形缓冲不超过上限', () {
      RuntimeLog.enabled = true;
      for (var i = 0; i < RuntimeLog.maxEntries + 50; i++) {
        RuntimeLog.i('T', 'line $i');
      }
      expect(RuntimeLog.count, RuntimeLog.maxEntries);
      // 最旧的被丢掉，最新的还在
      expect(RuntimeLog.dump(), contains('line ${RuntimeLog.maxEntries + 49}'));
    });

    test('导出文本包含环境表头且密钥被脱敏', () {
      RuntimeLog.enabled = true;
      RuntimeLog.i('LLM', '请求 qwen3.8-flash');
      RuntimeLog.e(
        'Fallback',
        '连接失败：https://api.example.com/v1/chat?api_key=sk-live-AbCdEf0123456789 '
        'Authorization: Bearer sk-proj-ZZZZZZZZZZZZZZZZ',
      );
      final dump = RuntimeLog.dump();
      expect(dump, contains('拟境 · 运行日志'));
      expect(dump, contains('qwen3.8-flash'));
      // 模型名要留着，凭证必须被抹掉
      expect(dump, isNot(contains('sk-live-AbCdEf0123456789')));
      expect(dump, isNot(contains('sk-proj-ZZZZZZZZZZZZZZZZ')));
      expect(dump, contains('[已脱敏]'));
    });

    test('脱敏覆盖 query / Bearer / 常见前缀 / JWT', () {
      expect(RuntimeLog.redact('?key=abc123'), isNot(contains('abc123')));
      expect(RuntimeLog.redact('?api_key=abc123&x=1'),
          isNot(contains('abc123')));
      expect(RuntimeLog.redact('Bearer sk-abcdefghijklmnop'),
          isNot(contains('sk-abcdefghijklmnop')));
      expect(RuntimeLog.redact('sk-proj-abcdefghijklmnop'),
          isNot(contains('abcdefghijklmnop')));
      final jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abcdefghijklmnop';
      expect(RuntimeLog.redact(jwt), isNot(contains('abcdefghijklmnop')));
      // 正常技术文本不该被误伤
      expect(RuntimeLog.redact('模型 qwen3.8-flash 返回 200'),
          contains('qwen3.8-flash'));
    });

    test('超长条目被截断', () {
      RuntimeLog.enabled = true;
      RuntimeLog.i('T', 'x' * 5000);
      expect(RuntimeLog.entries().first.message.length,
          lessThanOrEqualTo(RuntimeLog.maxMessageChars + 20));
    });
  });

  group('v1.3.3 · 日志与详细开关配置持久化', () {
    test('默认关闭，序列化往返保留', () {
      final cfg = AppConfig();
      expect(cfg.logEnabled, isFalse);
      expect(cfg.verboseLog, isFalse);

      final on = cfg.copyWith(logEnabled: true, verboseLog: true);
      final restored = AppConfig.fromJson(on.toJson());
      expect(restored.logEnabled, isTrue);
      expect(restored.verboseLog, isTrue);
    });

    test('旧配置缺字段时回落为关闭', () {
      final restored = AppConfig.fromJson(<String, dynamic>{
        'apiProvider': 'bailian',
        'enableThinking': true,
      });
      expect(restored.logEnabled, isFalse);
      expect(restored.verboseLog, isFalse);
    });
  });

  // ==========================================================================
  // v1.3.4 五项核心改进与单幕上限3000专项测试
  // ==========================================================================

  group('v1.3.4 · GenerationController 独立生命周期与状态机', () {
    tearDown(() {
      GenerationController.resetAll();
    });

    test('按 slotId 维系单例与独立状态', () {
      final c1 = GenerationController.forSlot('slot_alpha');
      final c2 = GenerationController.forSlot('slot_alpha');
      final c3 = GenerationController.forSlot('slot_beta');

      expect(identical(c1, c2), isTrue);
      expect(identical(c1, c3), isFalse);
      expect(c1.slotId, 'slot_alpha');
      expect(c3.slotId, 'slot_beta');
    });

    test('状态机初始为 idle，cancel 和 reset 正常工作', () {
      final c = GenerationController.forSlot('slot_test');
      expect(c.status, GenerationStatus.idle);
      expect(c.isBusy, isFalse);

      c.live = '流式中...';
      c.pendingAction = '拔刀迎敌';
      c.cancel();

      expect(c.status, GenerationStatus.idle);
      expect(c.isBusy, isFalse);
      expect(c.live, isEmpty);
      expect(c.notice, contains('已中止本次推演'));
      expect(c.noticeSticky, isTrue);

      c.reset();
      expect(c.notice, isEmpty);
      expect(c.noticeSticky, isFalse);
    });

    test('支持多订阅者监听与解除监听', () {
      final c = GenerationController.forSlot('slot_listener');
      var notifyCount = 0;
      void listener() => notifyCount++;

      c.addListener(listener);
      c.reset();
      expect(notifyCount, 1);

      c.removeListener(listener);
      c.reset();
      expect(notifyCount, 1); // 移除后不再接收通知
    });

    test('cancel 之后再次 startGeneration 客户端 isCancelled 状态被正确重置', () {
      final c = GenerationController.forSlot('slot_cancel_then_start');
      c.cancel();
      expect(c.client.isCancelled, isTrue);

      c.reset();
      expect(c.client.isCancelled, isFalse);
      expect(c.status, GenerationStatus.idle);
      expect(c.thoughtExpanded, isFalse);
    });

    test('LiveThoughtView 展开状态受 GenerationController 托管并在重置时归零', () {
      final c = GenerationController.forSlot('slot_thought_expanded');
      expect(c.thoughtExpanded, isFalse);
      c.thoughtExpanded = true;
      expect(c.thoughtExpanded, isTrue);

      c.reset();
      expect(c.thoughtExpanded, isFalse);
    });
  });

  group('v1.3.4 · ResponseParser 未闭合 think 自然叙事正文特征与段落断崖探测', () {
    test('未闭合 think 后接文学正文与 choices：文学正文绝不被吞入思考', () {
      const raw = '''
<think>
我们来推演一下这一幕的走向。主角需要面临生死考验，剧情必须在这里收紧节奏。

夜色深沉，寒风如刀割般刮过脸颊。
林砚握紧了手中的短刀，屏息凝神，倾听着门外由远及近的脚步声。
“掌柜的，北边来人了。”伙计压低嗓音，额头上布满冷汗。

<choices>
1. 拔刀迎战，先发制人
2. 藏入暗格，静观其变
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.thought, contains('推演一下这一幕的走向'));
      expect(p.thought, isNot(contains('夜色深沉')));
      expect(p.body, contains('夜色深沉，寒风如刀割般刮过脸颊。'));
      expect(p.body, contains('林砚握紧了手中的短刀'));
      expect(p.body, contains('掌柜的，北边来人了'));
      expect(p.choices.length, 2);
      expect(p.hasUsableChoices, isTrue);
    });

    test('未闭合 think 后接对话引号“...”：自动断崖截断', () {
      const raw = '''
<think>
分析局势：主角决定直接对质。
“你到底是谁？”他冷冷质问。对方并未回答，只是缓缓拔出了腰间的长剑。
<choices>
迎战
后撤
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.thought, contains('分析局势'));
      expect(p.thought, isNot(contains('你到底是谁')));
      expect(p.body, contains('“你到底是谁？”他冷冷质问。'));
      expect(p.choices.length, 2);
    });

    test('未闭合 think 后接显式「正文：」标识：截断并自动清洗标识前缀', () {
      const raw = '''
<think>
本幕设计构思：让主角在风雪中抵达客栈。

正文：
大雪纷飞，遮天蔽日。林远踏入风雪客栈的那一刻，喧闹的堂内瞬间安静了下来。

<choices>
1. 径直走向柜台
2. 找角落坐下
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.thought, contains('本幕设计构思'));
      expect(p.body, isNot(contains('正文：')));
      expect(p.body, contains('大雪纷飞，遮天蔽日。'));
      expect(p.choices.length, 2);
    });

    test('流式 splitLive 对未闭合 think 自然叙事正文实时分流', () {
      const raw = '<think>思考推演中\n\n大雪纷飞，寒风呼啸。林远推开了客栈的大门。';
      final (thought, body) = ResponseParser.splitLive(raw);
      expect(thought, '思考推演中');
      expect(body, '大雪纷飞，寒风呼啸。林远推开了客栈的大门。');
    });

    test('未闭合 think 后接短句氛围开篇（如「夜色深沉。」）：短句绝不被吞入思考', () {
      const raw = '''
<think>
推演思路：安排主角在风雪中抵达客栈。

夜色深沉。

林远推开客栈厚重的木门，风雪呼啸着涌入大堂。

<choices>
1. 走向柜台
2. 拔剑警戒
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.thought, contains('推演思路'));
      expect(p.thought, isNot(contains('夜色深沉。')));
      expect(p.body, contains('夜色深沉。'));
      expect(p.body, contains('林远推开客栈厚重的木门'));
      expect(p.choices.length, 2);
    });

    test('未闭合 think 后接人物对话中出现动机/局势等词：对话绝不被误判为思考', () {
      const raw = '''
<think>
梳理当前冲突矛盾。

“当务之急是弄清他的动机。”林砚低声道，“局势对我们极为不利，必须步步为营。”

<choices>
1. 追问实情
2. 调动守卫
</choices>
''';
      final p = ResponseParser.parse(raw);
      expect(p.thought, contains('梳理当前冲突矛盾'));
      expect(p.thought, isNot(contains('当务之急是弄清他的动机')));
      expect(p.body, contains('“当务之急是弄清他的动机。”'));
      expect(p.body, contains('局势对我们极为不利'));
      expect(p.choices.length, 2);
    });
  });

  group('v1.3.4 · 思考排版规范化保留单个空行', () {
    test('段落之间保留单个空行，多空行折叠', () {
      const raw = '''
这是第一段分析。

这是第二段分析。



这是第三段分析。
''';
      final cleaned = ResponseParser.cleanThoughtForShow(raw);
      expect(cleaned, '这是第一段分析。\n\n这是第二段分析。\n\n这是第三段分析。');
    });

    test('Markdown 标记剥离后依然保持段落空行结构与幂等', () {
      const raw = '''
### 第一阶段
- 考虑主角动机与目标

### 第二阶段
`分析`局势走向与危机
''';
      final cleaned = ResponseParser.cleanThoughtForShow(raw);
      expect(cleaned, contains('第一阶段\n· 考虑主角动机与目标\n\n第二阶段\n分析局势走向与危机'));
      final twice = ResponseParser.cleanThoughtForShow(cleaned);
      expect(twice, cleaned);
    });
  });

  group('v1.3.4 · 提示词与 Token 缓冲及单幕目标字数 3000 上限', () {
    test('PromptKernel.thinkingRule 去除矛盾表述并强调呈现思维链', () {
      final rule = PromptKernel.thinkingRule;
      expect(rule, isNot(contains('读者只会看到正文')));
      expect(rule, contains('向读者呈现思维链'));
      expect(rule, contains('简体中文'));
      expect(rule, contains('单空行'));
    });

    test('LlmClient.calculateMaxTokens 支持 3000 字上限，分配充足缓冲 9000 tokens', () {
      expect(LlmClient.calculateMaxTokens(3000), 9000);
      expect(LlmClient.calculateMaxTokens(1200), 3600);
      expect(LlmClient.calculateMaxTokens(500), 2048);
    });

    test('AppConfig 支持 3000 字并在 fromJson 与 copyWith 中 clamp 到 3000', () {
      final cfg = AppConfig(maxWords: 3000);
      expect(cfg.maxWords, 3000);

      final json = cfg.toJson();
      expect(json['maxWords'], 3000);

      final restored = AppConfig.fromJson(json);
      expect(restored.maxWords, 3000);

      final overCfg = AppConfig.fromJson(<String, dynamic>{'maxWords': 5000});
      expect(overCfg.maxWords, 3000);

      final copy = cfg.copyWith(maxWords: 4000);
      expect(copy.maxWords, 3000);

      final directOver = AppConfig(maxWords: 9999);
      expect(directOver.maxWords, 3000);

      final directUnder = AppConfig(maxWords: 50);
      expect(directUnder.maxWords, 200);
    });

    test('PromptKernel.build 在 3000 字时动态生成相应的字数下限约束 (2550 字)', () {
      final kernel = PromptKernel.build(AppConfig(maxWords: 3000));
      expect(kernel, contains('下限不得少于 2550 字')); // 3000 * 0.85 = 2550
      expect(kernel, contains('目标 3000 字'));
    });
  });

  group('v1.3.4 · 运行日志真实 API Key 精准脱敏与高效淘汰', () {
    tearDown(() {
      RuntimeLog.enabled = false;
      RuntimeLog.verbose = false;
      RuntimeLog.configuredApiKey = null;
      RuntimeLog.clear();
    });

    test('配置的真实 API 密钥精准脱敏（支持无特殊前缀的自定义 Key）', () {
      RuntimeLog.enabled = true;
      RuntimeLog.configuredApiKey = 'custom-secret-key-xyz-987654';

      RuntimeLog.i('Network', 'POST https://custom-ai.internal/v1/chat');
      RuntimeLog.i('Auth', 'x-token: custom-secret-key-xyz-987654');

      final dump = RuntimeLog.dump();
      expect(dump, isNot(contains('custom-secret-key-xyz-987654')));
      expect(dump, contains('[已脱敏]'));
    });

    test('超限淘汰保持上限 2000 条', () {
      RuntimeLog.enabled = true;
      for (var i = 0; i < 2050; i++) {
        RuntimeLog.i('TAG', 'msg_$i');
      }
      expect(RuntimeLog.count, 2000);
      expect(RuntimeLog.dump(), contains('msg_2049'));
      expect(RuntimeLog.dump(), isNot(contains('msg_0 ')));
    });
  });

  group('v1.3.4 · FallbackService 兜底顺序与通知保障', () {
    test('三级兜底时 restart 先于 notice 发送，确保错误提示与降级通知不被抹除', () async {
      final mock = _MockAlwaysFailClient();
      final fb = FallbackService(mock);
      final events = await fb.generate(
        config: AppConfig(),
        apiKey: 'dummy-key',
        book: WorldBook(id: 'test_book', name: '测试世界', era: '1900', worldview: '背景', playerRole: '主角'),
        history: const <ChapterNode>[],
        playerAction: '拔剑迎战',
      ).toList();

      expect(events, isNotEmpty);
      final kinds = events.map((e) => e.kind).toList();
      expect(kinds, contains(GenEventKind.restart));
      expect(kinds, contains(GenEventKind.notice));
      expect(kinds, contains(GenEventKind.done));

      // 检查倒数第三个是 restart，倒数第二个是 notice，最后一个是 done(degraded: true)
      final lastThree = events.sublist(events.length - 3);
      expect(lastThree[0].kind, GenEventKind.restart);
      expect(lastThree[1].kind, GenEventKind.notice);
      expect(lastThree[1].text, contains('换一个模型或换一家服务商'));
      expect(lastThree[2].kind, GenEventKind.done);
      expect(lastThree[2].degraded, isTrue);
    });
  });

  group('v1.3.5 · 400错误根治、日志真实文件分享与视口停泊', () {
    test('Providers · 思考模式与参数隔离精确判定', () {
      // 真正支持思考开关的推理模型
      expect(Providers.supportsThinkingSwitch('qwen3.8-flash'), isTrue);
      expect(Providers.supportsThinkingSwitch('Qwen3-Max'), isTrue);
      expect(Providers.supportsThinkingSwitch('qwq-32b-preview'), isTrue);
      // 普通模型绝不判定为支持思考开关
      expect(Providers.supportsThinkingSwitch('qwen-plus'), isFalse);
      expect(Providers.supportsThinkingSwitch('qwen-turbo'), isFalse);
      expect(Providers.supportsThinkingSwitch('qwen-max'), isFalse);
      expect(Providers.supportsThinkingSwitch('deepseek-chat'), isFalse);

      // supportsThinkingParameter 严格服务商隔离与拼写自愈
      expect(
        Providers.supportsThinkingParameter(apiProvider: 'bailian', modelName: 'qwen3.8-flash'),
        isTrue,
      );
      expect(
        Providers.supportsThinkingParameter(apiProvider: 'bailian', modelName: 'qwen3.8flash'),
        isTrue,
      );
      expect(
        Providers.supportsThinkingParameter(apiProvider: 'bailian', modelName: 'qwen-plus'),
        isFalse,
      );
      expect(
        Providers.supportsThinkingParameter(apiProvider: 'custom', modelName: 'qwen3.8-flash'),
        isFalse,
      );
      expect(
        Providers.supportsThinkingParameter(apiProvider: 'deepseek', modelName: 'deepseek-chat'),
        isFalse,
      );
    });

    test('Providers.normalizeModelName · 模型代码智能归一化自愈', () {
      expect(Providers.normalizeModelName('qwen3.8flash'), 'qwen3.8-flash');
      expect(Providers.normalizeModelName('Qwen3.8Flash'), 'qwen3.8-flash');
      expect(Providers.normalizeModelName('Qwen3.8-Flash'), 'qwen3.8-flash');
      expect(Providers.normalizeModelName('qwen-3.8-flash'), 'qwen3.8-flash');
      expect(Providers.normalizeModelName('qwen_3.8_flash'), 'qwen3.8-flash');
      expect(Providers.normalizeModelName('qwen3.8max'), 'qwen3.8-max');
      expect(Providers.normalizeModelName('Qwen3.8-Max'), 'qwen3.8-max');
      expect(Providers.normalizeModelName('qwen3.7flash'), 'qwen3.7-flash');
      expect(Providers.normalizeModelName('qwen3.7plus'), 'qwen3.7-plus');
      expect(Providers.normalizeModelName('qwenplus'), 'qwen-plus');
      expect(Providers.normalizeModelName('Qwen-Plus'), 'qwen-plus');
      expect(Providers.normalizeModelName('qwen_plus'), 'qwen-plus');
      expect(Providers.normalizeModelName('qwenturbo'), 'qwen-turbo');
      expect(Providers.normalizeModelName('qwen_turbo'), 'qwen-turbo');
      expect(Providers.normalizeModelName('qwenmax'), 'qwen-max');
      expect(Providers.normalizeModelName('deepseekchat'), 'deepseek-chat');
      expect(Providers.normalizeModelName('DeepSeek-Chat'), 'deepseek-chat');
      expect(Providers.normalizeModelName('deepseekreasoner'), 'deepseek-reasoner');
      expect(Providers.normalizeModelName('qwq32b'), 'qwq-32b-preview');
      expect(Providers.normalizeModelName('qwq-32b-preview'), 'qwq-32b-preview');
    });

    test('LlmClient.calculateMaxTokens · 模型硬限与安全上限', () {
      // 阿里云百炼 qwen-turbo 硬限 [1, 1500]
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwen-turbo'), 1500);
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwenturbo'), 1500);

      // 阿里云百炼 qwen-plus & qwen-max 硬限 [1, 2000]
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwen-plus'), 2000);
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwenplus'), 2000);
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwen-max'), 2000);
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwenmax'), 2000);
      expect(LlmClient.calculateMaxTokens(800, modelName: 'qwen-plus'), 2000);
      expect(LlmClient.calculateMaxTokens(300, modelName: 'qwen-plus'), 900);

      // DeepSeek 4096 上限
      expect(LlmClient.calculateMaxTokens(3000, provider: 'deepseek'), 4096);
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'deepseek-chat'), 4096);

      // 普通推理模型支持充足缓冲
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwen3.8-flash'), 9000);
      expect(LlmClient.calculateMaxTokens(3000, modelName: 'qwen3.8flash'), 9000);
      expect(LlmClient.calculateMaxTokens(3000), 9000);
    });

    test('AppError.fromStatus · 400 服务端具体错误透出', () {
      // 百炼 InvalidParameter 报错透出
      const bailianErr = '{"code":"InvalidParameter","message":"Range of max_tokens should be [1, 2000]","request_id":"req-123"}';
      final err1 = AppError.fromStatus(400, bailianErr);
      expect(err1.message, contains('Range of max_tokens should be [1, 2000]'));
      expect(err1.statusCode, 400);

      // OpenAI/兼容端点 error.message 透出
      const dashscopeErr = '{"error":{"message":"Model does not support enable_thinking","type":"invalid_request_error"}}';
      final err2 = AppError.fromStatus(400, dashscopeErr);
      expect(err2.message, contains('Model does not support enable_thinking'));

      // 非 JSON / 纯文本 400 兜底
      final err3 = AppError.fromStatus(400, 'Bad Request');
      expect(err3.message, contains('多为模型名不存在、单幕字数超限或参数不合法'));
    });

    test('FileExportService · shareFile 原生调用安全不崩溃', () async {
      final res = await FileExportService.shareFile(
        filePath: '/tmp/non_existent.txt',
        title: '测试文件分享',
      );
      // 非 Android 宿主下安全回落为 false，不抛未捕获异常
      expect(res, isFalse);
    });

    test('GameSession · restoreChoices 恢复备选分支', () {
      final slot = SaveSlot(
        id: 'slot_choices_test',
        title: '测试存档',
        worldBook: WorldBook(
          id: 'wb1',
          name: '测试世界',
          era: '1900',
          worldview: '背景',
          playerRole: '主角',
        ),
      );
      final session = GameSession(slot);
      session.restoreChoices(<String>['分支甲', '分支乙']);
      expect(session.choices, contains('分支甲'));

      session.clearChoices();
      expect(session.choices, isEmpty);

      session.restoreChoices(<String>['分支甲', '分支乙']);
      expect(session.choices.length, 2);
      expect(session.choices[0], '分支甲');
      expect(session.choices[1], '分支乙');
    });

    test('GenerationController · 错误与中止时备选选项保留防闪烁与就地重试', () async {
      final slot = SaveSlot(
        id: 'slot_preserve_choices',
        title: '测试存档',
        worldBook: WorldBook(
          id: 'wb1',
          name: '测试世界',
          era: '1900',
          worldview: '背景',
          playerRole: '主角',
        ),
      );
      final session = GameSession(slot);
      session.restoreChoices(<String>['选项A', '选项B']);

      final c = GenerationController.forSlot('slot_preserve_choices');

      // 验证推演刚发起、首批 token 尚未到达前，choices 不会被提前清空
      final future = c.startGeneration(
        session: session,
        config: AppConfig(),
        apiKey: '',
        action: '选项A',
        book: slot.worldBook,
      );
      // 正在握手期间选项保持保留
      expect(session.choices, contains('选项A'));

      // 中止或异常失败后，选项完整保留供重试
      c.cancel();
      await future;

      expect(session.choices, contains('选项A'));
      expect(session.choices, contains('选项B'));
    });

    test('FallbackService · 400/401 认证与参数错误直接 failed 阻断，不产生虚假降级章节', () async {
      final mock = _Mock400AuthFailClient();
      final fb = FallbackService(mock);
      final events = await fb.generate(
        config: AppConfig(),
        apiKey: 'dummy-key',
        book: WorldBook(
          id: 'test_book',
          name: '测试世界',
          era: '1900',
          worldview: '背景',
          playerRole: '主角',
        ),
        history: const <ChapterNode>[],
        playerAction: '拔剑迎战',
      ).toList();

      expect(events, isNotEmpty);
      // 验证未产生 done 事件（未落库伪降级章节）
      expect(events.any((e) => e.kind == GenEventKind.done), isFalse);
      // 验证产生 failed 且携带具体 400 错误说明
      final failedEvent = events.firstWhere((e) => e.kind == GenEventKind.failed);
      expect(failedEvent.text, contains('Range of max_tokens should be [1, 2000]'));
    });

    testWidgets('ReaderScreen 渲染正常且支持视口停泊检测与回到最新行按钮', (tester) async {
      final slot = SaveSlot(
        id: 'slot_reader_test',
        title: '测试存档',
        worldBook: WorldBook(
          id: 'wb1',
          name: '测试世界书',
          era: '1900',
          worldview: '背景描述',
          playerRole: '主角人物',
        ),
        lines: <WorldLine>[
          WorldLine(
            id: 'line_test',
            name: '主线',
            history: <ChapterNode>[
              for (int i = 1; i <= 6; i++)
                ChapterNode(
                  chapterIndex: i,
                  title: '第 $i 幕',
                  content: '长夜漫漫，风雪如刀。天地苍茫，万籁寂静。' * 10,
                  date: '1900年冬',
                  choices: i == 6 ? <String>['开局选项一', '开局选项二'] : <String>[],
                ),
            ],
          ),
        ],
      );

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            config: AppConfig(),
            slot: slot,
            onConfigChanged: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('测试世界书'), findsWidgets);
      expect(find.text('开局选项一'), findsOneWidget);
      expect(find.text('开局选项二'), findsOneWidget);

      // 初始状态下在底部，回到最新行按钮处于隐蔽状态
      final btnFinder = find.byKey(const ValueKey('back_to_latest_button'));
      expect(btnFinder, findsOneWidget);
      final opacityWidget = tester.widget<AnimatedOpacity>(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)),
      );
      expect(opacityWidget.opacity, 0.0);

      // 模拟流式生成涌入且视口手动向上滚动远离底部
      final controller = GenerationController.forSlot('slot_reader_test');
      controller.status = GenerationStatus.generating;
      controller.live = '风雪之中，隐约传来马蹄声……\n\n黑夜更深了。';
      controller.notifyListeners();
      await tester.pump();

      // 向上拖动内容（视口向上停泊回看）
      await tester.drag(find.byType(ListView), const Offset(0, 500));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final opacityWidgetVisible = tester.widget<AnimatedOpacity>(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)),
      );
      expect(opacityWidgetVisible.opacity, 1.0);

      // 点击“有新内容流出”浮动按钮，平滑滚回最新行
      await tester.tap(btnFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      final opacityWidgetAfter = tester.widget<AnimatedOpacity>(
        find.ancestor(of: btnFinder, matching: find.byType(AnimatedOpacity)),
      );
      expect(opacityWidgetAfter.opacity, 0.0);

      controller.reset();
      await tester.pump(const Duration(milliseconds: 100));
    });
  });
}

class _MockAlwaysFailClient extends LlmClient {
  @override
  Stream<String> streamChat({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String workspaceId = '',
  }) async* {
    throw const AppError(AppErrorKind.refused, '模型回避了这一段的推演。');
  }
}

class _Mock400AuthFailClient extends LlmClient {
  @override
  Stream<String> streamChat({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String workspaceId = '',
  }) async* {
    throw AppError.fromStatus(
      400,
      '{"code":"InvalidParameter","message":"Range of max_tokens should be [1, 2000]"}',
    );
  }
}


