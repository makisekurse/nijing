import 'dart:async';
import 'package:flutter/foundation.dart';

import '../models/app_config.dart';
import '../models/save_slot.dart';
import '../models/world_book.dart';
import 'chronicle_service.dart';
import 'fallback_service.dart';
import 'game_session.dart';
import 'llm_client.dart';
import 'response_parser.dart';
import 'runtime_log.dart';
import 'save_service.dart';
import 'world_state_service.dart';

enum GenerationStatus {
  idle,
  generating,
  completed,
  failed,
}

/// 长生命周期的推演控制器（按 slotId 维系独立的推演状态机、LlmClient、流式缓冲区与持久化）。
///
/// [ReaderScreen] 仅作为订阅者，退出页面时只 detach 不 cancel；
/// 后台推演完成后自动写入存档；再次进入时自动 re-attach 恢复流式现场。
class GenerationController extends ChangeNotifier {
  final String slotId;
  final LlmClient client;

  GenerationController(this.slotId) : client = LlmClient();

  static final Map<String, GenerationController> _registry =
      <String, GenerationController>{};

  static GenerationController forSlot(String slotId) =>
      _registry.putIfAbsent(slotId, () => GenerationController(slotId));

  static GenerationController? get(String slotId) => _registry[slotId];

  // ---------- 状态 ----------
  GenerationStatus status = GenerationStatus.idle;
  bool get isBusy => status == GenerationStatus.generating;

  String pendingAction = '';
  String live = '';
  String notice = '';
  bool noticeSticky = false;
  bool degraded = false;
  bool godMode = false;
  bool thoughtExpanded = false;

  GameSession? session;
  SaveSlot? lastSavedSlot;

  /// 开始推演。
  Future<void> startGeneration({
    required GameSession session,
    required AppConfig config,
    required String apiKey,
    required String action,
    required WorldBook book,
    bool godMode = false,
  }) async {
    if (isBusy) return;

    final backupChoices = List<String>.from(session.choices);
    client.reset();
    this.session = session;
    this.godMode = godMode;
    pendingAction = action;
    status = GenerationStatus.generating;
    live = '';
    notice = '';
    noticeSticky = false;
    degraded = false;
    thoughtExpanded = false;
    // 选项保留防闪烁：不在此刻提前清空 choices；
    // 待服务端握手成功并涌入首个 delta 增量时再清空。若在 100ms 握手阶段即报 400，原有选项完好保留供就地重试。
    notifyListeners();

    RuntimeLog.i('GenerationController', '[$slotId] 开始推演：action="$action"');

    ParsedChapter? parsed;
    var wasDegraded = false;

    try {
      final stream = FallbackService(client).generate(
        config: config,
        apiKey: apiKey,
        book: book,
        history: session.history,
        playerAction: action,
        chronicle: session.chronicle,
        worldState: WorldStateService.renderForPrompt(session.worldState),
        godMode: godMode,
      );

      await for (final ev in stream) {
        if (client.isCancelled) break;
        switch (ev.kind) {
          case GenEventKind.delta:
            if (session.choices.isNotEmpty) {
              session.clearChoices();
            }
            live += ev.text;
            notifyListeners();
            break;
          case GenEventKind.notice:
            notice = ev.text;
            noticeSticky = false;
            notifyListeners();
            break;
          case GenEventKind.restart:
            live = '';
            notice = '';
            noticeSticky = false;
            notifyListeners();
            break;
          case GenEventKind.done:
            parsed = ev.chapter;
            wasDegraded = ev.degraded;
            if (wasDegraded) {
              if (notice.isEmpty) {
                notice = '本幕未能取得模型响应，已进入本地降级，可重新生成本幕。';
              }
              noticeSticky = true;
            } else {
              notice = '';
              noticeSticky = false;
            }
            notifyListeners();
            break;
          case GenEventKind.failed:
            if (!client.isCancelled) {
              notice = ev.text;
              noticeSticky = true;
              notifyListeners();
            }
            break;
        }
      }

      if (client.isCancelled) {
        status = GenerationStatus.idle;
        live = '';
        pendingAction = '';
        notice = '已中止本次推演。';
        noticeSticky = true;
        if (session.choices.isEmpty && backupChoices.isNotEmpty) {
          session.restoreChoices(backupChoices);
        }
        notifyListeners();
        return;
      }

      final p = parsed ?? _trySalvageLive();
      if (p != null) {
        session.appendChapter(
          content: p.body,
          playerAction: action,
          date: p.date,
          choices: p.choices,
          glossary: p.glossary,
          cast: p.cast,
          rawOutput: p.rawOutput,
          stateRaw: p.stateRaw,
          thought: p.thought,
          godMode: godMode,
        );
        live = '';
        pendingAction = '';
        degraded = wasDegraded;
        status = GenerationStatus.completed;
        if (parsed == null) {
          notice = '网络连接中断，已成功抢救并保存推演正文。';
          noticeSticky = true;
        }

        // 后台推演完成后自动写入存档
        final slot = session.toSlot();
        await SaveService.upsert(slot);
        lastSavedSlot = slot;
        RuntimeLog.i('GenerationController', '[$slotId] 推演完成并已持久化保存存档');

        // 编年史压缩
        if (ChronicleService.shouldCompress(session.history.length) &&
            apiKey.trim().isNotEmpty) {
          final updated = await ChronicleService.compress(
            config: config,
            apiKey: apiKey,
            book: book,
            previousChronicle: session.chronicle,
            history: session.history,
          );
          if (updated != session.chronicle) {
            session.attachChronicle(updated);
            final updatedSlot = session.toSlot();
            await SaveService.upsert(updatedSlot);
            lastSavedSlot = updatedSlot;
            RuntimeLog.i('GenerationController', '[$slotId] 编年史压缩完成并已更新存档');
          }
        }
        notifyListeners();
      } else {
        status = GenerationStatus.failed;
        live = '';
        pendingAction = '';
        if (session.choices.isEmpty && backupChoices.isNotEmpty) {
          session.restoreChoices(backupChoices);
        }
        notifyListeners();
      }
    } catch (e) {
      if (client.isCancelled) {
        status = GenerationStatus.idle;
        live = '';
        pendingAction = '';
        notice = '已中止本次推演。';
        noticeSticky = true;
        if (session.choices.isEmpty && backupChoices.isNotEmpty) {
          session.restoreChoices(backupChoices);
        }
        notifyListeners();
        return;
      }
      RuntimeLog.e('GenerationController', '[$slotId] 推演发生未捕获异常: $e');

      final salvaged = _trySalvageLive();
      if (salvaged != null && this.session != null) {
        this.session!.appendChapter(
          content: salvaged.body,
          playerAction: action,
          date: salvaged.date,
          choices: salvaged.choices,
          glossary: salvaged.glossary,
          cast: salvaged.cast,
          rawOutput: salvaged.rawOutput,
          stateRaw: salvaged.stateRaw,
          thought: salvaged.thought,
          godMode: godMode,
        );
        live = '';
        pendingAction = '';
        status = GenerationStatus.completed;
        notice = '推演发生异常中断，但已成功抢救并保存推演正文。';
        noticeSticky = true;
        final slot = this.session!.toSlot();
        await SaveService.upsert(slot);
        lastSavedSlot = slot;
        notifyListeners();
        return;
      }

      status = GenerationStatus.failed;
      notice = '推演发生异常：$e';
      noticeSticky = true;
      live = '';
      pendingAction = '';
      if (session.choices.isEmpty && backupChoices.isNotEmpty) {
        session.restoreChoices(backupChoices);
      }
      notifyListeners();
    }
  }

  /// 残文抢救检测：若当前 live 包含剧中日期 `<date>` 且小说正文达 200 字以上，执行残文抢救 (Salvage)
  ParsedChapter? _trySalvageLive() {
    if (live.trim().isEmpty) return null;
    final candidate = ResponseParser.parse(live);
    final hasDate = candidate.date.isNotEmpty ||
        RegExp(r'[<＜《]\s*date\s*[>＞》]', caseSensitive: false).hasMatch(live);
    if (!hasDate || candidate.body.trim().length < 200) {
      return null;
    }
    final choices = List<String>.from(candidate.choices);
    if (choices.isEmpty) {
      choices.addAll(<String>[
        '继续深入探查眼下局势',
        '按兵不动，静观其变',
      ]);
    } else if (choices.length == 1) {
      choices.add('按兵不动，静观其变');
    }
    return ParsedChapter(
      body: candidate.body,
      date: candidate.date,
      choices: choices,
      glossary: candidate.glossary,
      cast: candidate.cast,
      stateRaw: candidate.stateRaw,
      thought: candidate.thought,
      rawOutput: live,
    );
  }

  void cancel() {
    client.cancel();
    status = GenerationStatus.idle;
    live = '';
    pendingAction = '';
    notice = '已中止本次推演。';
    noticeSticky = true;
    notifyListeners();
  }

  void reset() {
    client.reset();
    status = GenerationStatus.idle;
    live = '';
    pendingAction = '';
    notice = '';
    noticeSticky = false;
    degraded = false;
    thoughtExpanded = false;
    notifyListeners();
  }

  static void disposeSlot(String slotId) {
    final c = _registry.remove(slotId);
    c?.client.cancel();
  }

  static void resetAll() {
    for (final c in _registry.values) {
      c.client.cancel();
    }
    _registry.clear();
  }
}
