import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/prefs_store.dart';
import '../data/secure_store.dart';
import '../models/app_config.dart';
import '../models/model_profile.dart';
import '../services/runtime_log.dart';
import '../ui/themes/app_theme.dart';

/// 全局配置、多模型档案与跨厂商分槽密钥状态管理器（基于 `provider`）。
///
/// 彻底消灭过去层层 `widget.config` + `onConfigChanged` 回调透传与不同步缺陷。
class ConfigProvider extends ChangeNotifier {
  static const String kConfigKey = 'nijing_config_v1';
  static const String kThemeMigratedKey = 'nijing_theme_migrated_v2';
  static const String kLegacyWorkspaceKey = 'nijing_workspace_id';

  AppConfig _config;

  ConfigProvider(AppConfig initialConfig)
      : _config = _normalizeActiveProfile(initialConfig) {
    _syncLogFlags(_config);
  }

  AppConfig get config => _config;
  String get activeProfileId => _config.activeProfileId;

  /// 若当前 `activeProfileId` 对应的档案不存在，或核心路由参数已手动偏离该档案，
  /// 自动清空 `activeProfileId`，彻底杜绝手动切换服务商/端点后仍串用旧档案 Key。
  static AppConfig _normalizeActiveProfile(AppConfig cfg) {
    final pid = cfg.activeProfileId.trim();
    if (pid.isEmpty) return cfg;
    ModelProfile? matched;
    for (final p in cfg.savedProfiles) {
      if (p.id == pid) {
        matched = p;
        break;
      }
    }
    if (matched == null ||
        matched.apiProvider != cfg.apiProvider ||
        matched.baseUrl != cfg.baseUrl ||
        matched.modelName != cfg.modelName ||
        matched.workspaceId != cfg.workspaceId) {
      return cfg.copyWith(activeProfileId: '');
    }
    return cfg;
  }

  /// 启动时加载配置并完成历史字段的一次性迁移。
  static Future<AppConfig> loadInitialConfig() async {
    var cfg = AppConfig();
    final raw = await PrefsStore.getString(kConfigKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          cfg = AppConfig.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {}
    }

    if (cfg.workspaceId.trim().isEmpty) {
      final legacyWs = (await PrefsStore.getString(kLegacyWorkspaceKey)) ?? '';
      if (legacyWs.trim().isNotEmpty) {
        cfg = cfg.copyWith(workspaceId: legacyWs.trim());
        await PrefsStore.setString(kConfigKey, cfg.encode());
      }
    }

    final migrated = (await PrefsStore.getString(kThemeMigratedKey)) == 'done';
    if (!migrated) {
      cfg = cfg.copyWith(themeMode: AppTheme.defaultId);
      await PrefsStore.setString(kConfigKey, cfg.encode());
      await PrefsStore.setString(kThemeMigratedKey, 'done');
    }

    // 预热读取当前服务商与辅助模型密钥进内存脱敏池
    await SecureStore.readMainKeyForConfig(cfg);
    await SecureStore.readAuxKeyForConfig(cfg);
    return cfg;
  }

  static void _syncLogFlags(AppConfig c) {
    RuntimeLog.enabled = c.logEnabled;
    RuntimeLog.verbose = c.verboseLog;
  }

  /// 更新配置并同步持久化（离散开关立即落盘，滑杆/输入框走防抖）。
  void updateConfig(AppConfig next, {bool immediate = false}) {
    final normalized = _normalizeActiveProfile(next);
    _config = normalized;
    _syncLogFlags(normalized);
    final raw = normalized.encode();
    if (immediate) {
      PrefsStore.setString(kConfigKey, raw);
      PrefsStore.setString(kLegacyWorkspaceKey, normalized.workspaceId.trim());
    } else {
      PrefsStore.setStringDebounced(kConfigKey, raw);
      PrefsStore.setStringDebounced(
        kLegacyWorkspaceKey,
        normalized.workspaceId.trim(),
      );
    }
    notifyListeners();
  }

  /// 写入当前服务商的独立加密 API Key。
  Future<void> saveProviderApiKey(String providerId, String apiKey) async {
    await SecureStore.writeKeyForProvider(providerId, apiKey);
    notifyListeners();
  }

  /// 读取当前主配置对应的有效 API Key（若已选中同厂商有效档案则优先取档案 Key）。
  Future<String> resolveActiveMainKey() async {
    final pid = _config.activeProfileId.trim();
    if (pid.isNotEmpty) {
      ModelProfile? matched;
      for (final p in _config.savedProfiles) {
        if (p.id == pid) {
          matched = p;
          break;
        }
      }
      if (matched != null && matched.apiProvider == _config.apiProvider) {
        final key = await SecureStore.readKeyForProfile(
          pid,
          fallbackProviderId: _config.apiProvider,
        );
        if (key.isNotEmpty) return key;
      }
    }
    return SecureStore.readMainKeyForConfig(_config);
  }

  /// 读取后台辅助模型对应的有效 API Key（支持跨厂商独立 Key，不与主模型串 Key）。
  Future<String> resolveActiveAuxKey() =>
      SecureStore.readAuxKeyForConfig(_config);

  /// 将当前模型配置另存为可一键切换的档案（并同时保存该档案独立加密 Key）。
  Future<ModelProfile> saveCurrentAsProfile({
    required String name,
    required String apiKey,
  }) async {
    final profile = ModelProfile(
      id: ModelProfile.newId(),
      name: name.trim().isEmpty ? _config.modelName : name.trim(),
      apiProvider: _config.apiProvider,
      baseUrl: _config.baseUrl,
      workspaceId: _config.workspaceId,
      modelName: _config.modelName,
      reasoningDialect: _config.reasoningDialect,
      enableThinking: _config.enableThinking,
      thinkingBudget: _config.thinkingBudget,
      reasoningEffort: _config.reasoningEffort,
    );
    if (apiKey.trim().isNotEmpty) {
      await SecureStore.writeKeyForProfile(profile.id, apiKey);
    }
    final nextProfiles = <ModelProfile>[..._config.savedProfiles, profile];
    updateConfig(
      _config.copyWith(
        savedProfiles: nextProfiles,
        activeProfileId: profile.id,
      ),
      immediate: true,
    );
    return profile;
  }

  /// 一键切换至已保存的 [ModelProfile]，保持档案 Key 与服务商全局槽位严格分离。
  Future<String> applyProfile(ModelProfile profile) async {
    final key = await SecureStore.readKeyForProfile(
      profile.id,
      fallbackProviderId: profile.apiProvider,
    );
    updateConfig(_config.applyProfile(profile), immediate: true);
    return key;
  }

  /// 删除一个模型档案及其关联的独立加密 Key。
  Future<void> deleteProfile(String profileId) async {
    await SecureStore.deleteProfileKey(profileId);
    final next = _config.savedProfiles
        .where((p) => p.id != profileId)
        .toList();
    updateConfig(
      _config.copyWith(
        savedProfiles: next,
        activeProfileId:
            _config.activeProfileId == profileId ? '' : _config.activeProfileId,
      ),
      immediate: true,
    );
  }
}
