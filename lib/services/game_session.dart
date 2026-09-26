import '../models/annotation.dart';
import '../models/chapter_node.dart';
import '../models/save_slot.dart';
import '../models/world_line.dart';
import '../models/world_state.dart';
import 'world_state_service.dart';

/// 一局推演的**状态与纯逻辑**，与 UI 完全解耦。
///
/// 一个存档槽里有**若干条世界线**，本类始终操作「当前活动的那条」。
/// 玩家从某一幕分岔出新线时，**原线原样保留** —— 这正是它和旧「回滚」的
/// 根本区别：回滚是单向销毁，分支是保留并新增。
///
/// 核心不变量（**三者必须永远处于同一个时间点**）：
/// `history` · `chronicle` · `worldState`（都在当前世界线上）
///
/// 从上千行的 ReaderScreen 里拆出来，好处是这些逻辑**可以单测** ——
/// 世界线切换与分岔的一致性最容易出隐蔽 bug，靠手点界面根本测不出来。
class GameSession {
  final SaveSlot slot;

  /// 当前可选行动。切换世界线时会跟着换成那条线的。
  List<String> _choices;

  GameSession(this.slot) : _choices = _choicesOf(slot.activeLine) {
    // 旧存档可能缺每幕快照（世界书自带开篇时，第一幕是在 UI 层直接构造的），
    // 读入时先补齐 —— 否则从那一幕分岔会拿到错误的状态。
    ensureSnapshots();
  }

  static List<String> _choicesOf(WorldLine line) => line.history.isEmpty
      ? <String>[]
      : List<String>.from(line.history.last.choices);

  // ---------- 当前世界线 ----------

  WorldLine get line => slot.activeLine;

  List<WorldLine> get lines => slot.lines;

  List<ChapterNode> get history => line.history;

  String get chronicle => line.chronicle;

  WorldState get worldState => line.worldState;

  List<String> get choices => _choices;

  int get chapterCount => history.length;

  bool get isEmpty => history.isEmpty;

  String get worldName => slot.worldBook.name;

  /// 生成过程中先清空可选行动，避免用户点到上一轮的。
  void clearChoices() => _choices = <String>[];

  /// 恢复备选行动（用于网络报错/请求拒绝时保留用户当前的选项分支，防闪烁并支持就地重试）。
  void restoreChoices(List<String> restored) =>
      _choices = List<String>.from(restored);

  // ---------- 世界线管理 ----------

  /// 切换世界线。
  ///
  /// 切换后 `history` / `chronicle` / `worldState` / `choices` 全部换成
  /// 那条线的 —— 因为每条线自带这三件套，**天然互不干扰**。
  void switchLine(String lineId) {
    slot.switchTo(lineId);
    _choices = _choicesOf(line);
  }

  /// 从第 [index] 幕（0-based）**分岔**出一条新世界线，并切过去。
  ///
  /// 新线保留 1..index+1 幕，`chronicle` / `worldState` 恢复到那一幕的快照，
  /// 玩家可以从这里重新做选择。
  ///
  /// **原来的线完全不动** —— 它连同后续所有幕原样留在列表里，
  /// 随时可以切回去看。
  WorldLine branchFrom(int index) {
    ensureSnapshots();
    if (index < 0 || index >= history.length) return line;

    final source = line;
    final kept = List<ChapterNode>.from(source.history.sublist(0, index + 1));
    final head = kept.last;

    // 分岔点**之前**的状态：从上一幕的快照取；没有上一幕就是空。
    final beforeState = index > 0
        ? (source.history[index - 1].worldStateAfter ?? WorldState()).copy()
        : WorldState();
    final beforeChronicle =
        index > 0 ? (source.history[index - 1].chronicleAfter ?? '') : '';

    final branch = WorldLine(
      id: WorldLine.newId(),
      name: nextBranchName(),
      history: kept,
      chronicle: head.chronicleAfter ?? '',
      worldState: (head.worldStateAfter ?? WorldState()).copy(),
      parentLineId: source.id,
      branchedAtChapter: head.chapterIndex,
      baseState: beforeState,
      baseChronicle: beforeChronicle,
    );

    slot.lines = <WorldLine>[...slot.lines, branch];
    slot.switchTo(branch.id);
    _choices = _choicesOf(branch);
    return branch;
  }

  /// 下一个可用的分支名（避开重名）。
  String nextBranchName() {
    final used = slot.lines.map((l) => l.name).toSet();
    var n = slot.lines.where((l) => l.isBranch).length + 1;
    while (used.contains('世界线 $n')) {
      n++;
    }
    return '世界线 $n';
  }

  /// 删除一条世界线。**至少保留一条**，删不掉返回 false。
  bool deleteLine(String lineId) {
    if (slot.lines.length <= 1) return false;
    if (!slot.lines.any((l) => l.id == lineId)) return false;

    slot.lines = slot.lines.where((l) => l.id != lineId).toList();
    if (slot.activeLineId == lineId) {
      slot.switchTo(slot.lines.first.id);
      _choices = _choicesOf(line);
    }
    return true;
  }

  void renameLine(String lineId, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    for (final l in slot.lines) {
      if (l.id == lineId) {
        l.name = trimmed;
        l.updatedAt = DateTime.now();
      }
    }
  }

  // ---------- 快照自愈 ----------

  /// 补齐缺失的每幕快照。
  ///
  /// ⚠️ 为什么需要它：世界书自带开篇时，第一幕是在 UI 层直接构造的，
  /// 没有 `chronicleAfter` / `worldStateAfter`。结果从第一幕分岔时
  /// 「没快照就跳过」→ 状态停在后来的幕，世界观察显示的还是未来的内容。
  ///
  /// 补法：缺快照的幕取**上一幕**的快照；第一幕取空状态 ——
  /// 它没跑过模型，状态本来就是空的，对开篇场景这是**精确值**。
  ///
  /// 只在内存里补，不主动落盘：等用户下次正常保存时自然写回，
  /// 避免「打开一下就把存档改了」。
  void ensureSnapshots() {
    for (final l in slot.lines) {
      var prevChronicle = l.baseChronicle;
      var prevState = l.baseState.copy();
      for (var i = 0; i < l.history.length; i++) {
        final node = l.history[i];
        if (node.chronicleAfter == null || node.worldStateAfter == null) {
          l.history[i] = node.copyWith(
            chronicleAfter: node.chronicleAfter ?? prevChronicle,
            worldStateAfter: node.worldStateAfter ?? prevState.copy(),
          );
        }
        prevChronicle = l.history[i].chronicleAfter ?? prevChronicle;
        prevState = l.history[i].worldStateAfter ?? prevState;
      }
    }
  }

  // ---------- 推演 ----------

  /// 落定一幕：合并状态、写入快照。
  ///
  /// 快照（chronicleAfter / worldStateAfter）是**分岔与重生成**的基础。
  ChapterNode appendChapter({
    required String content,
    required String playerAction,
    required String date,
    required List<String> choices,
    required List<GlossaryEntry> glossary,
    required List<CastEntry> cast,
    required String rawOutput,
    required String stateRaw,
    String? title,
    String thought = '',
    bool godMode = false,
  }) {
    // 模型只提出状态变化；校验、合并、截断都在这里做。
    var nextState = WorldStateService.merge(
      worldState,
      WorldStateService.parse(stateRaw),
    );

    // 主宰模式状态一致性保障：若主宰行动陈述了确定事实，确保进入世界状态
    if (godMode && playerAction.trim().isNotEmpty) {
      final act = playerAction.trim();
      // 判定世界状态是否已包含玩家意志：必须是事实或事件已精确覆盖行动（绝不能反向以 act.contains(f) 判定，
      // 否则行动中只要提到已有短词条如「城门」「守军」「大雨」就会导致主宰意志被错误跳过丢弃）。
      final alreadyCovered = nextState.facts.any((f) => f == act || f.contains(act)) ||
          nextState.events.any((e) => e == act || e.contains(act));
      if (!alreadyCovered) {
        final cappedAct = act.length > WorldState.maxItemChars
            ? act.substring(0, WorldState.maxItemChars)
            : act;
        final newFacts = <String>[
          cappedAct,
          ...nextState.facts.where((f) => f != cappedAct),
        ];
        if (newFacts.length > WorldState.maxFacts) {
          newFacts.removeLast();
        }
        nextState = nextState.copy()..facts = newFacts;
      }
    }

    final target = line;
    final node = ChapterNode(
      chapterIndex: target.history.length + 1,
      title: title ?? '第 ${target.history.length + 1} 幕',
      content: content,
      playerAction: playerAction,
      date: date,
      choices: choices,
      glossary: glossary,
      cast: cast,
      rawOutput: rawOutput,
      chronicleAfter: target.chronicle,
      worldStateAfter: nextState,
      thought: thought,
    );

    target.history = <ChapterNode>[...target.history, node];
    target.worldState = nextState;
    target.updatedAt = DateTime.now();
    _choices = List<String>.from(choices);
    return node;
  }

  /// 就地修正某幕的正文（错字微调）。
  ///
  /// 严格保证 history · chronicle · worldState 快照与三位一体不变量不受影响。
  void editChapterContent(int index, String newContent) {
    if (index < 0 || index >= line.history.length) return;
    final old = line.history[index];
    line.history[index] = old.copyWith(content: newContent);
    line.updatedAt = DateTime.now();
  }

  /// 世界书自带开篇时，直接落第一幕（不走模型）。
  ///
  /// ⚠️ 新建局**必须走这里**，不要在外面直接 `ChapterNode(...)` ——
  /// 那样会漏掉快照，导致从第一幕分岔时状态退不回去。
  ChapterNode seedOpening({
    required String content,
    required String date,
    required List<String> choices,
  }) {
    final target = line;
    final node = ChapterNode(
      chapterIndex: 1,
      title: '第一幕',
      content: content,
      date: date,
      choices: choices,
      chronicleAfter: target.chronicle,
      worldStateAfter: target.worldState.copy(),
    );
    target.history = <ChapterNode>[node];
    target.updatedAt = DateTime.now();
    _choices = List<String>.from(choices);
    return node;
  }

  /// 编年史被压缩后，把它记到最后一幕的快照上 ——
  /// 否则从这一幕分岔时，编年史会停留在「未来」的版本。
  void attachChronicle(String updated) {
    final target = line;
    target.chronicle = updated;
    if (target.history.isNotEmpty) {
      target.history[target.history.length - 1] =
          target.history.last.copyWith(chronicleAfter: updated);
    }
    target.updatedAt = DateTime.now();
  }

  /// 弹出最后一幕以便重新生成，并把状态恢复到**这一幕之前**。
  ///
  /// 恢复到 [WorldLine.baseState] / [WorldLine.baseChronicle] 而不是空 ——
  /// 在分岔点那一幕重生成时，这条线继承来的局势不能被抹掉。
  ///
  /// 返回被弹出的那一幕；history 为空时返回 null。
  ChapterNode? popLastForReroll() {
    final target = line;
    if (target.history.isEmpty) return null;
    final last = target.history.last;

    target.history = target.history.sublist(0, target.history.length - 1);
    final prev = target.history.isEmpty ? null : target.history.last;

    if (prev == null) {
      target.worldState = target.baseState.copy();
      target.chronicle = target.baseChronicle;
      _choices = <String>[];
    } else {
      if (prev.chronicleAfter != null) target.chronicle = prev.chronicleAfter!;
      if (prev.worldStateAfter != null) {
        target.worldState = prev.worldStateAfter!.copy();
      }
      _choices = List<String>.from(prev.choices);
    }
    target.updatedAt = DateTime.now();
    return last;
  }

  /// 把当前状态写回存档对象（调用方负责持久化）。
  SaveSlot toSlot() {
    slot.updatedAt = DateTime.now();
    return slot;
  }

  /// 塞进 system prompt 的世界状态文本。
  String get worldStateForPrompt =>
      WorldStateService.renderForPrompt(worldState);
}
