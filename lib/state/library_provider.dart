import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/prefs_store.dart';
import '../data/secure_store.dart';
import '../data/world_book_repository.dart';
import '../models/save_slot.dart';
import '../models/world_book.dart';
import '../services/game_session.dart';
import '../services/generation_controller.dart';
import '../services/save_service.dart';

/// 世界书与推演存档的统一状态仓库（基于 `provider`）。
///
/// 将原先塞在千行 `HomeShell` 中的所有业务逻辑、IO 持久化、文件导入与示例世界书加载
/// 干净剥离到纯状态层，UI 只做声明式渲染。
class LibraryProvider extends ChangeNotifier {
  static const String kActiveSlotKey = 'nijing_active_slot';
  static const String sampleAssetPath = 'worldbooks/deng_1949.json';

  List<SaveSlot> _slots = <SaveSlot>[];
  List<WorldBook> _books = <WorldBook>[];
  List<SaveSlot> _backups = <SaveSlot>[];
  String? _activeSlotId;
  bool _loading = true;

  List<SaveSlot> get slots => _slots;
  List<WorldBook> get books => _books;
  List<SaveSlot> get backups => _backups;
  String? get activeSlotId => _activeSlotId;
  bool get loading => _loading;

  Map<String, int> get progressByBook => <String, int>{
        for (final s in _slots) s.worldBook.id: s.chapterCount,
      };

  int get totalLineCount => _slots.fold(0, (sum, s) => sum + s.lines.length);

  List<WorldBook> get blankBooks => _books
      .where((b) => b.worldview.trim().isEmpty && b.playerRole.trim().isEmpty)
      .toList();

  SaveSlot? slotForBook(String bookId) {
    for (final s in _slots) {
      if (s.worldBook.id == bookId) return s;
    }
    return null;
  }

  Future<void> reload() async {
    final results = await Future.wait<dynamic>(<Future<dynamic>>[
      SaveService.loadAll(),
      WorldBookRepository.loadAll(),
      SaveService.loadBackups(),
      PrefsStore.getString(kActiveSlotKey),
    ]);
    _slots = results[0] as List<SaveSlot>;
    _books = results[1] as List<WorldBook>;
    _backups = results[2] as List<SaveSlot>;
    _activeSlotId = results[3] as String?;
    _loading = false;
    notifyListeners();
  }

  Future<void> setActiveSlot(String id) async {
    _activeSlotId = id;
    await PrefsStore.setString(kActiveSlotKey, id);
    notifyListeners();
  }

  /// 获取或创建某本世界书对应的存档槽（一本书一局）。
  Future<SaveSlot> ensureSlotForBook(WorldBook book) async {
    final existing = slotForBook(book.id);
    if (existing != null) {
      await setActiveSlot(existing.id);
      return existing;
    }
    return createSession(book);
  }

  /// 新建一局（通过 `GameSession.seedOpening` 确保开篇带完整每幕快照）。
  Future<SaveSlot> createSession(WorldBook book) async {
    final slot = SaveSlot(
      id: SaveSlot.newId(),
      title: book.name,
      worldBook: book,
    );
    if (book.openingScene.trim().isNotEmpty) {
      GameSession(slot).seedOpening(
        content: book.openingScene.trim(),
        date: book.era.trim(),
        choices: book.openingChoices,
      );
    }
    await SaveService.upsert(slot);
    await setActiveSlot(slot.id);
    await reload();
    return slot;
  }

  /// 清空该书已有进度并从头重开（先销毁内存控制器缓存，彻底杜绝旧进度复活）。
  Future<SaveSlot> restartBook(WorldBook book) async {
    final existing = slotForBook(book.id);
    if (existing == null) {
      return createSession(book);
    }
    GenerationController.disposeSlot(existing.id);
    final fresh = SaveSlot(
      id: existing.id,
      title: book.name,
      worldBook: book,
      createdAt: existing.createdAt,
    );
    if (book.openingScene.trim().isNotEmpty) {
      GameSession(fresh).seedOpening(
        content: book.openingScene.trim(),
        date: book.era.trim(),
        choices: book.openingChoices,
      );
    }
    await SaveService.upsert(fresh);
    await setActiveSlot(fresh.id);
    await reload();
    return fresh;
  }

  Future<void> deleteSlot(String slotId) async {
    GenerationController.disposeSlot(slotId);
    await SaveService.delete(slotId);
    if (_activeSlotId == slotId) {
      await PrefsStore.remove(kActiveSlotKey);
      _activeSlotId = null;
    }
    await reload();
  }

  Future<void> upsertBook(WorldBook book) async {
    await WorldBookRepository.upsert(book);
    await reload();
  }

  Future<void> deleteBook(String bookId) async {
    await WorldBookRepository.delete(bookId);
    await reload();
  }

  /// 从原始文本（JSON 或纯文本）导入世界书并落库。
  Future<WorldBook> importBookFromText(String raw) async {
    final book = WorldBook.fromImportText(raw);
    await WorldBookRepository.upsert(book);
    await reload();
    return book;
  }

  /// 一键导入仓库内置示例世界书《决胜西南1949》（解决新用户冷启动空屏问题）。
  Future<WorldBook> importSampleWorldBook() async {
    final raw = await rootBundle.loadString(sampleAssetPath);
    final book = WorldBook.fromImportText(raw);
    await WorldBookRepository.upsert(book);
    await reload();
    return book;
  }

  /// 使用系统文件选择器选取本地 `.json` / `.txt` 世界书或存档文件。
  /// 返回 null 表示用户取消选择。
  Future<String?> pickLocalTextFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json', 'txt', 'md'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final picked = result.files.first;
    if (picked.bytes != null) {
      return utf8.decode(picked.bytes!, allowMalformed: true);
    }
    if (picked.path != null && picked.path!.isNotEmpty) {
      return File(picked.path!).readAsString();
    }
    return null;
  }

  /// 从 JSON 文本导入一个推演存档并落库。
  Future<SaveSlot> importSaveFromText(String raw) async {
    final slot = SaveService.importSlot(raw);
    await SaveService.upsert(slot);
    await reload();
    return slot;
  }

  Future<int> purgeBlankBooks() async {
    final blanks = blankBooks;
    if (blanks.isEmpty) return 0;
    for (final b in blanks) {
      await WorldBookRepository.delete(b.id);
    }
    await reload();
    return blanks.length;
  }

  Future<void> purgeBackups() async {
    final remaining = (await SaveService.loadAll(includeBackups: true))
        .where((s) => !s.isBackup)
        .toList();
    await SaveService.saveAll(remaining);
    await reload();
  }

  Future<void> clearAllData() async {
    GenerationController.resetAll();
    await SaveService.saveAll(<SaveSlot>[]);
    await WorldBookRepository.saveAll(<WorldBook>[]);
    await SecureStore.clearAllKeys();
    await PrefsStore.remove(kActiveSlotKey);
    await PrefsStore.remove('nijing_workspace_id');
    _activeSlotId = null;
    await reload();
  }
}
