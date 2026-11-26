import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_config.dart';
import '../services/runtime_log.dart';

/// 多服务商 / 多模型档案 / 主辅双模型分槽加密 API Key 存储（v2.0 升级）。
///
/// 核心保障：
/// 1. **按 `providerId` / `profileId` / `aux` 分槽加密保存**：
///    百炼、DeepSeek、自定义中转与每个 `ModelProfile` 拥有独立密文槽位，一键切换永不串 Key；
/// 2. **100% 向下兼容迁移旧默认 Key**：
///    老版本只有一个 `nijing_api_key_v1` 键，首次按服务商读取时自动平滑读取并回填；
/// 3. **平台安全降级**：
///    Android 走 EncryptedSharedPreferences；桌面端/单测无系统密钥链时自动降级为内存多槽 Map。
class SecureStore {
  SecureStore._();

  static const String _legacyDefaultKey = 'nijing_api_key_v1';
  static const String _slotIndexKey = 'nijing_api_key_slots_v2';
  static const String _slotKeyPrefix = 'nijing_api_key_slot_';

  /// 独立后台辅助模型专用槽位（为空时自动回退至 `auxApiProvider` 对应槽位）。
  static const String auxSlotId = 'aux_model';

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static final Map<String, String> _memorySlots = <String, String>{};
  static final Set<String> _knownSlotIds = <String>{};
  static String _memoryLegacy = '';
  static bool _degraded = false;

  static bool get isDegraded => _degraded;

  static String providerSlot(String providerId) {
    final safe = providerId.trim().isEmpty ? 'bailian' : providerId.trim();
    return 'provider_${_sanitize(safe)}';
  }

  static String profileSlot(String profileId) =>
      'profile_${_sanitize(profileId)}';

  static String _sanitize(String raw) =>
      raw.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');

  static String _storageKeyFor(String slotId) =>
      '$_slotKeyPrefix${_sanitize(slotId)}';

  static Future<String> _readRaw(String storageKey, String fallback) async {
    try {
      final v = await _storage.read(key: storageKey);
      if (v != null) return v;
    } catch (_) {
      _degraded = true;
    }
    return fallback;
  }

  static Future<void> _writeRaw(String storageKey, String value) async {
    try {
      await _storage.write(key: storageKey, value: value);
      _degraded = false;
    } catch (_) {
      _degraded = true;
    }
  }

  static Future<void> _deleteRaw(String storageKey) async {
    try {
      await _storage.delete(key: storageKey);
    } catch (_) {
      _degraded = true;
    }
  }

  static Future<void> _registerSlotId(String slotId) async {
    if (_knownSlotIds.add(slotId)) {
      await _persistSlotIndex();
    }
  }

  static Future<void> _persistSlotIndex() async {
    await _writeRaw(_slotIndexKey, jsonEncode(_knownSlotIds.toList()));
  }

  static Future<Set<String>> _loadAllSlotIds() async {
    final raw = await _readRaw(_slotIndexKey, '');
    if (raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            final s = item.toString().trim();
            if (s.isNotEmpty) _knownSlotIds.add(s);
          }
        }
      } catch (_) {}
    }
    return Set<String>.from(_knownSlotIds);
  }

  // ---------- 兼容旧默认接口（单槽读写） ----------

  /// 读取默认 API Key（若传入 [slotId] 则优先读该槽位，未配置时平滑回退旧默认 Key）。
  static Future<String> readApiKey({
    String? slotId,
    bool fallbackToLegacy = true,
  }) async {
    if (slotId != null && slotId.trim().isNotEmpty) {
      final key = await _readRaw(
        _storageKeyFor(slotId),
        _memorySlots[slotId] ?? '',
      );
      if (key.isNotEmpty) {
        _memorySlots[slotId] = key;
        RuntimeLog.registerSecret(key);
        return key;
      }
      if (!fallbackToLegacy) return '';
    }

    final legacy = await _readRaw(_legacyDefaultKey, _memoryLegacy);
    if (legacy.isNotEmpty) {
      _memoryLegacy = legacy;
      RuntimeLog.configuredApiKey = legacy;
    }
    return legacy;
  }

  /// 写入 API Key（若指定 [slotId] 则写入对应独立加密槽位；未指定则写默认旧槽位）。
  static Future<void> writeApiKey(String value, {String? slotId}) async {
    final trimmed = value.trim();
    if (slotId != null && slotId.trim().isNotEmpty) {
      final cleanSlot = slotId.trim();
      _memorySlots[cleanSlot] = trimmed;
      await _registerSlotId(cleanSlot);
      if (trimmed.isEmpty) {
        await _deleteRaw(_storageKeyFor(cleanSlot));
      } else {
        await _writeRaw(_storageKeyFor(cleanSlot), trimmed);
        RuntimeLog.registerSecret(trimmed);
      }
      return;
    }

    _memoryLegacy = trimmed;
    RuntimeLog.configuredApiKey = trimmed;
    if (trimmed.isEmpty) {
      await _deleteRaw(_legacyDefaultKey);
    } else {
      await _writeRaw(_legacyDefaultKey, trimmed);
    }
  }

  // ---------- 分服务商 / 分档案 / 跨厂商主辅双模型专用接口 ----------

  static Future<String> readKeyForProvider(
    String providerId, {
    bool fallbackToLegacy = true,
  }) async {
    final slot = providerSlot(providerId);
    final v = await readApiKey(slotId: slot, fallbackToLegacy: false);
    if (v.isNotEmpty) return v;
    if (!fallbackToLegacy) return '';
    // 兼容老版本：如果此前从未按服务商分槽存过任何 Key，则允许迁移读取旧默认 Key
    final allSlots = await _loadAllSlotIds();
    final hasAnyProviderSlot =
        allSlots.any((s) => s.startsWith('provider_') && (_memorySlots[s]?.isNotEmpty ?? true));
    if (!hasAnyProviderSlot) {
      return readApiKey(fallbackToLegacy: true);
    }
    return '';
  }

  static Future<void> writeKeyForProvider(
    String providerId,
    String value,
  ) async {
    final slot = providerSlot(providerId);
    await writeApiKey(value, slotId: slot);
    // 同步维护旧默认槽位一份（若为空时填入），确保旧路径零回归
    if (value.trim().isNotEmpty && _memoryLegacy.isEmpty) {
      await writeApiKey(value);
    }
  }

  static Future<String> readKeyForProfile(
    String profileId, {
    required String fallbackProviderId,
  }) async {
    final v = await readApiKey(
      slotId: profileSlot(profileId),
      fallbackToLegacy: false,
    );
    if (v.isNotEmpty) return v;
    return readKeyForProvider(fallbackProviderId);
  }

  static Future<void> writeKeyForProfile(
    String profileId,
    String value,
  ) async {
    await writeApiKey(value, slotId: profileSlot(profileId));
  }

  static Future<void> deleteProfileKey(String profileId) async {
    final slot = profileSlot(profileId);
    _memorySlots.remove(slot);
    _knownSlotIds.remove(slot);
    await _deleteRaw(_storageKeyFor(slot));
    await _persistSlotIndex();
  }

  /// 读取当前主配置对应的有效 API Key。
  static Future<String> readMainKeyForConfig(AppConfig config) =>
      readKeyForProvider(config.apiProvider);

  /// 读取当前后台辅助模型对应的有效 API Key（支持跨厂商主辅双模型独立 Key！）。
  ///
  /// 优先级：
  /// 1. 独立配置的 `aux_model` 槽位（仅在开启独立辅模型时）；
  /// 2. 辅助服务商（`auxApiProvider`）对应的服务商槽位；
  /// 3. 同服务商时回退主模型 Key。
  static Future<String> readAuxKeyForConfig(AppConfig config) async {
    if (!config.enableAuxModel || config.auxModelName.trim().isEmpty) {
      return readMainKeyForConfig(config);
    }
    final dedicated =
        await readApiKey(slotId: auxSlotId, fallbackToLegacy: false);
    if (dedicated.isNotEmpty) return dedicated;

    final effProvider = config.auxApiProvider.trim().isEmpty
        ? config.apiProvider
        : config.auxApiProvider.trim();
    final byProvider = await readKeyForProvider(
      effProvider,
      fallbackToLegacy: effProvider == config.apiProvider,
    );
    if (byProvider.isNotEmpty) return byProvider;
    if (effProvider == config.apiProvider) {
      return readMainKeyForConfig(config);
    }
    return '';
  }

  static Future<void> writeAuxKey(String value) =>
      writeApiKey(value, slotId: auxSlotId);

  static Future<String> readAuxDedicatedKey() =>
      readApiKey(slotId: auxSlotId, fallbackToLegacy: false);

  /// 清空全部已保存的加密密钥（含旧默认键及所有分服务商/分档案/辅模型槽位）。
  static Future<void> clearApiKey() => clearAllKeys();

  static Future<void> clearAllKeys() async {
    final slots = await _loadAllSlotIds();
    // 把常见固定槽位也一并纳入清理，防止索引未记录时漏删
    slots.addAll(<String>[
      providerSlot('bailian'),
      providerSlot('deepseek'),
      providerSlot('custom'),
      auxSlotId,
    ]);
    for (final slot in slots) {
      await _deleteRaw(_storageKeyFor(slot));
    }
    await _deleteRaw(_legacyDefaultKey);
    await _deleteRaw(_slotIndexKey);
    _memorySlots.clear();
    _knownSlotIds.clear();
    _memoryLegacy = '';
    RuntimeLog.clearSecrets();
  }
}
