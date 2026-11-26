import '../models/annotation.dart';
import '../models/chapter_node.dart';
import '../models/save_slot.dart';
import '../models/world_line.dart';
import '../models/world_state.dart';
import 'scene_extractor_service.dart';
import 'world_state_service.dart';

/// 一局推演的**状态与纯逻辑**，与 UI 完全解耦。
///
/// 核心不变量（**三者必须永远处于同一个时间点**）：
/// `history` · `chronicle` · `worldState`（都在当前世界线上）
class GameSession {
  final SaveSlot slot;

  /// 当前可选行动。切换世界线时会跟着换成那条线的。
  List<String> _choices;

  GameSession(this.slot) : _choices = _choicesOf(slot.activeLine) {
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

  void clearChoices() => _choices = <String>[];

  void restoreChoices(List<String> restored) =>
      _choices = List<String>.from(restored);

  // ---------- 世界线管理 ----------

  void switchLine(String lineId) {
    slot.switchTo(lineId);
    _choices = _choicesOf(line);
  }

  WorldLine branchFrom(int index) {
    ensureSnapshots();
    if (index < 0 || index >= history.length) return line;

    final source = line;
    final kept = List<ChapterNode>.from(source.history.sublist(0, index + 1));
    final head = kept.last;

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

  String nextBranchName() {
    final used = slot.lines.map((l) => l.name).toSet();
    var n = slot.lines.where((l) => l.isBranch).length + 1;
    while (used.contains('世界线 $n')) {
      n++;
    }
    return '世界线 $n';
  }

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
    int thinkingDurationMs = 0,
    String stateDiffSummary = '',
    bool godMode = false,
  }) {
    var nextState = WorldStateService.merge(
      worldState,
      WorldStateService.parse(stateRaw),
    );

    if (godMode && playerAction.trim().isNotEmpty) {
      nextState = _ensureGodModeFact(nextState, playerAction.trim());
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
      thinkingDurationMs: thinkingDurationMs,
      stateDiffSummary: stateDiffSummary,
      godMode: godMode,
    );

    target.history = <ChapterNode>[...target.history, node];
    target.worldState = nextState;
    target.updatedAt = DateTime.now();
    _choices = List<String>.from(choices);
    return node;
  }

  /// 将后台档案官提取的增量状态、新人物与词条定向合入指定世界线与幕次，并维护后续快照一致性。
  ///
  /// 支持玩家在后台抽取返回前快节奏继续推演下一幕，绝不因 `history.length` 增长而静默丢弃档案。
  bool applyBackgroundExtraction(
    SceneExtractionResult result, {
    bool godMode = false,
    String? targetLineId,
    int? targetChapterIndex,
  }) {
    WorldLine? target;
    if (targetLineId != null && targetLineId.isNotEmpty) {
      for (final l in slot.lines) {
        if (l.id == targetLineId) {
          target = l;
          break;
        }
      }
    } else {
      target = line;
    }
    if (target == null || target.history.isEmpty) return false;

    final int targetIdx;
    if (targetChapterIndex != null) {
      targetIdx = target.history.indexWhere(
        (n) => n.chapterIndex == targetChapterIndex,
      );
      if (targetIdx < 0) return false;
    } else {
      targetIdx = target.history.length - 1;
    }

    final node = target.history[targetIdx];
    final baseState = node.worldStateAfter ?? target.worldState;

    var mergedAtNode = WorldStateService.merge(baseState, result.stateDelta);
    final isGod = godMode || node.godMode;
    if (isGod && (node.playerAction ?? '').trim().isNotEmpty) {
      mergedAtNode = _ensureGodModeFact(mergedAtNode, node.playerAction!.trim());
    }

    final mergedGlossary = <GlossaryEntry>[
      ...node.glossary,
      for (final g in result.glossary)
        if (!node.glossary.any((e) => e.term == g.term)) g,
    ];
    final mergedCast = <CastEntry>[
      ...node.cast,
      for (final c in result.cast)
        if (!node.cast.any((e) => e.name == c.name)) c,
    ];

    target.history[targetIdx] = node.copyWith(
      date: node.date.trim().isEmpty && result.date.isNotEmpty
          ? result.date
          : node.date,
      glossary: mergedGlossary,
      cast: mergedCast,
      worldStateAfter: mergedAtNode.copy(),
      stateDiffSummary: result.diffSummary.isNotEmpty
          ? result.diffSummary
          : node.stateDiffSummary,
    );

    // 若玩家在后台抽取返回前已经推进到后续幕次，则把本幕新增的事实/事件/关系增量顺延补并到后续快照与当前 worldState，
    // 既保留后续幕次已更新的时间、地点与新状态，也不丢失本幕晚到的档案增量。
    final oldFacts = baseState.facts.toSet();
    final oldEvents = baseState.events.toSet();
    final addedFacts =
        mergedAtNode.facts.where((f) => !oldFacts.contains(f)).toList();
    final addedEvents =
        mergedAtNode.events.where((e) => !oldEvents.contains(e)).toList();
    final addedRelations = <String, String>{};
    mergedAtNode.relations.forEach((k, v) {
      if (baseState.relations[k] != v) addedRelations[k] = v;
    });

    var rolling = mergedAtNode.copy();
    for (var i = targetIdx + 1; i < target.history.length; i++) {
      final later = target.history[i];
      final laterSnap = (later.worldStateAfter ?? rolling).copy();
      if (laterSnap.time.trim().isEmpty && rolling.time.trim().isNotEmpty) {
        laterSnap.time = rolling.time;
      }
      if (laterSnap.location.trim().isEmpty &&
          rolling.location.trim().isNotEmpty) {
        laterSnap.location = rolling.location;
      }
      for (final f in addedFacts) {
        if (!laterSnap.facts.contains(f)) {
          laterSnap.facts.add(f);
        }
      }
      for (final e in addedEvents) {
        if (!laterSnap.events.contains(e)) {
          laterSnap.events.add(e);
        }
      }
      addedRelations.forEach((k, v) {
        laterSnap.relations.putIfAbsent(k, () => v);
      });
      var capped = WorldStateService.merge(laterSnap, WorldState());
      if (later.godMode && (later.playerAction ?? '').trim().isNotEmpty) {
        capped = _ensureGodModeFact(capped, later.playerAction!.trim());
      }
      rolling = capped;
      target.history[i] = later.copyWith(worldStateAfter: rolling.copy());
    }

    target.worldState = rolling;
    target.updatedAt = DateTime.now();
    return true;
  }

  static WorldState _ensureGodModeFact(WorldState state, String act) {
    final alreadyCovered =
        state.facts.any((f) => f == act || f.contains(act)) ||
            state.events.any((e) => e == act || e.contains(act));
    if (alreadyCovered) return state;
    final cappedAct = act.length > WorldState.maxItemChars
        ? act.substring(0, WorldState.maxItemChars)
        : act;
    final newFacts = <String>[
      cappedAct,
      ...state.facts.where((f) => f != cappedAct),
    ];
    if (newFacts.length > WorldState.maxFacts) {
      newFacts.removeLast();
    }
    return state.copy()..facts = newFacts;
  }

  void editChapterContent(int index, String newContent) {
    if (index < 0 || index >= line.history.length) return;
    final old = line.history[index];
    line.history[index] = old.copyWith(content: newContent);
    line.updatedAt = DateTime.now();
  }

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

  bool attachChronicle(String updated, {String? targetLineId}) {
    WorldLine? target;
    if (targetLineId != null && targetLineId.isNotEmpty) {
      for (final l in slot.lines) {
        if (l.id == targetLineId) {
          target = l;
          break;
        }
      }
    } else {
      target = line;
    }
    if (target == null) return false;
    target.chronicle = updated;
    if (target.history.isNotEmpty) {
      target.history[target.history.length - 1] =
          target.history.last.copyWith(chronicleAfter: updated);
    }
    target.updatedAt = DateTime.now();
    return true;
  }

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

  SaveSlot toSlot() {
    slot.updatedAt = DateTime.now();
    return slot;
  }

  String get worldStateForPrompt =>
      WorldStateService.renderForPrompt(worldState);
}
