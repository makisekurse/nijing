import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/prefs_store.dart';
import '../models/save_slot.dart';
import 'runtime_log.dart';

/// 存档槽持久化服务（独立文件分槽存储 + 原子写入 + 旧数据无缝迁移）。
///
/// 相比旧版把全部存档塞进单条 `SharedPreferences` 字符串的脆弱做法：
/// 1. **分槽独立 JSON 文件**：每个存档槽独立存储为 `slot_<id>.json`，读写单局不再序列化全量存档；
/// 2. **原子写防损坏**：先写 `.tmp` 再 `rename` 替换正式文件，杜绝中途杀进程导致空档；
/// 3. **坏档隔离**：单文件解析失败只跳过该文件并记日志，绝不连坐清空其他存档；
/// 4. **无缝迁移**：首次切换到文件存储时自动把旧 `nijing_saves_v1` 迁出为独立文件；
/// 5. **测试安全**：在 `FLUTTER_TEST` 环境下未显式指定 [testStorageDirectory] 时自动走内存/Prefs 隔离，不污染宿主机目录。
class SaveService {
  SaveService._();

  static const String _legacyPrefsKey = 'nijing_saves_v1';
  static const String _migratedKey = 'nijing_saves_file_migrated_v2';
  static const MethodChannel _nativeChannel =
      MethodChannel('io.github.makisekurse.nijing/file_export');

  /// 仅供单元测试注入临时文件目录。
  @visibleForTesting
  static Directory? testStorageDirectory;

  static Directory? _cachedDir;
  static bool _migrationChecked = false;

  @visibleForTesting
  static void resetCacheForTest() {
    _cachedDir = null;
    _migrationChecked = false;
  }

  static bool get _isFlutterTest =>
      !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');

  /// 解析独立分槽存储目录；返回 null 表示回退到 `PrefsStore`（如 Web 或无目录测试）。
  static Future<Directory?> _resolveDir() async {
    if (testStorageDirectory != null) {
      if (!testStorageDirectory!.existsSync()) {
        testStorageDirectory!.createSync(recursive: true);
      }
      return testStorageDirectory;
    }
    if (kIsWeb || _isFlutterTest) return null;
    if (_cachedDir != null) return _cachedDir;

    try {
      String? basePath;
      if (defaultTargetPlatform == TargetPlatform.android) {
        basePath = await _nativeChannel.invokeMethod<String>('getAppDataDir');
      } else if (Platform.isWindows) {
        final localAppData = Platform.environment['LOCALAPPDATA'];
        if (localAppData != null && localAppData.isNotEmpty) {
          basePath = '$localAppData\\nijing';
        }
      } else {
        final home = Platform.environment['HOME'];
        if (home != null && home.isNotEmpty) {
          basePath = '$home/.nijing';
        }
      }

      if (basePath == null || basePath.trim().isEmpty) return null;
      final dir = Directory('$basePath${Platform.pathSeparator}saves');
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      _cachedDir = dir;
      return dir;
    } catch (e) {
      RuntimeLog.w('SaveService', '解析文件存档目录失败，回退至 PrefsStore：$e');
      return null;
    }
  }

  static String _fileNameFor(String slotId) {
    final safe = slotId.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
    return 'slot_$safe.json';
  }

  static Future<void> _atomicWriteSlot(Directory dir, SaveSlot slot) async {
    final targetPath =
        '${dir.path}${Platform.pathSeparator}${_fileNameFor(slot.id)}';
    final tmpFile = File('$targetPath.tmp');
    final targetFile = File(targetPath);
    final payload = jsonEncode(slot.toJson());
    await tmpFile.writeAsString(payload, flush: true);
    if (await targetFile.exists()) {
      await targetFile.delete();
    }
    await tmpFile.rename(targetPath);
  }

  /// 若存在旧版 `SharedPreferences` 存档，自动迁移到分槽文件存储（仅执行一次）。
  static Future<void> _ensureMigrated(Directory dir) async {
    if (_migrationChecked) return;
    _migrationChecked = true;

    final alreadyDone = (await PrefsStore.getString(_migratedKey)) == 'done';
    if (alreadyDone) return;

    final legacy = await _loadAllFromPrefs();
    if (legacy.isNotEmpty) {
      for (final slot in legacy) {
        final target = File(
          '${dir.path}${Platform.pathSeparator}${_fileNameFor(slot.id)}',
        );
        if (!target.existsSync()) {
          await _atomicWriteSlot(dir, slot);
        }
      }
      RuntimeLog.i('SaveService', '已自动将 ${legacy.length} 个旧存档迁移至独立文件存储');
    }
    await PrefsStore.setString(_migratedKey, 'done');
  }

  /// 读取存档（默认不包含旧版自动备份）。
  static Future<List<SaveSlot>> loadAll({bool includeBackups = false}) async {
    final slots = await _loadAllRaw();
    if (!includeBackups) slots.removeWhere((s) => s.isBackup);
    return slots;
  }

  /// 只取旧版自动备份。
  static Future<List<SaveSlot>> loadBackups() async {
    final slots = await _loadAllRaw();
    return slots.where((s) => s.isBackup).toList();
  }

  static Future<List<SaveSlot>> _loadAllRaw() async {
    final dir = await _resolveDir();
    if (dir == null) {
      return _loadAllFromPrefs();
    }
    await _ensureMigrated(dir);

    final slots = <SaveSlot>[];
    if (!dir.existsSync()) return slots;

    final entities = dir.listSync();
    for (final entity in entities) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('slot_') || !name.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        if (raw.trim().isEmpty) continue;
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          slots.add(SaveSlot.fromJson(Map<String, dynamic>.from(decoded)));
        }
      } catch (e) {
        // 单文件损坏只记录告警，绝不影响其他存档读取
        RuntimeLog.e('SaveService', '读取存档文件 $name 失败（已隔离跳过）：$e');
      }
    }

    slots.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return slots;
  }

  static Future<List<SaveSlot>> _loadAllFromPrefs() async {
    final raw = await PrefsStore.getString(_legacyPrefsKey);
    if (raw == null || raw.isEmpty) return <SaveSlot>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final slots = list
          .whereType<Map>()
          .map((e) => SaveSlot.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      slots.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return slots;
    } catch (_) {
      return <SaveSlot>[];
    }
  }

  static Future<void> saveAll(List<SaveSlot> slots) async {
    final dir = await _resolveDir();
    if (dir == null) {
      await PrefsStore.setString(
        _legacyPrefsKey,
        jsonEncode(slots.map((e) => e.toJson()).toList()),
      );
      return;
    }
    await _ensureMigrated(dir);

    final keepFiles = <String>{
      for (final s in slots) _fileNameFor(s.id),
    };
    for (final s in slots) {
      await _atomicWriteSlot(dir, s);
    }
    if (dir.existsSync()) {
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (name.startsWith('slot_') &&
            name.endsWith('.json') &&
            !keepFiles.contains(name)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    }
    // 清空时同步清掉旧 Prefs key，避免再次迁回
    if (slots.isEmpty) {
      await PrefsStore.remove(_legacyPrefsKey);
    }
  }

  static Future<void> upsert(SaveSlot slot) async {
    slot.updatedAt = DateTime.now();
    final dir = await _resolveDir();
    if (dir == null) {
      final all = await _loadAllFromPrefs();
      final idx = all.indexWhere((e) => e.id == slot.id);
      if (idx >= 0) {
        all[idx] = slot;
      } else {
        all.add(slot);
      }
      await PrefsStore.setString(
        _legacyPrefsKey,
        jsonEncode(all.map((e) => e.toJson()).toList()),
      );
      return;
    }
    await _ensureMigrated(dir);
    await _atomicWriteSlot(dir, slot);
  }

  static Future<void> delete(String id) async {
    final dir = await _resolveDir();
    if (dir == null) {
      final all = await _loadAllFromPrefs();
      all.removeWhere((e) => e.id == id);
      await PrefsStore.setString(
        _legacyPrefsKey,
        jsonEncode(all.map((e) => e.toJson()).toList()),
      );
      return;
    }
    await _ensureMigrated(dir);
    final file = File('${dir.path}${Platform.pathSeparator}${_fileNameFor(id)}');
    if (await file.exists()) {
      await file.delete();
    }
  }

  static Future<SaveSlot?> findById(String id) async {
    final dir = await _resolveDir();
    if (dir != null) {
      await _ensureMigrated(dir);
      final file =
          File('${dir.path}${Platform.pathSeparator}${_fileNameFor(id)}');
      if (await file.exists()) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            return SaveSlot.fromJson(Map<String, dynamic>.from(decoded));
          }
        } catch (e) {
          RuntimeLog.e('SaveService', '读取指定存档 $id 失败：$e');
          return null;
        }
      }
      return null;
    }

    final all = await _loadAllFromPrefs();
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// 导出成可分享的 JSON 文本。
  static String exportSlot(SaveSlot slot) =>
      const JsonEncoder.withIndent('  ').convert(slot.toJson());

  /// 从 JSON 文本导入一个存档。
  static SaveSlot importSlot(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is List && decoded.isNotEmpty) {
      final first = decoded.first;
      if (first is Map) {
        return SaveSlot.fromJson(Map<String, dynamic>.from(first));
      }
    }
    if (decoded is! Map) throw const FormatException('存档格式不正确');
    return SaveSlot.fromJson(Map<String, dynamic>.from(decoded));
  }
}
