import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences 封装，带**写盘防抖**。
///
/// 旧版把 `saveConfig()` 直接挂在每个输入框的 `onChanged` 上，
/// 结果是每敲一个字符就写一次盘、还顺带触发整页 setState。
/// 现在同一 key 在 [debounce] 窗口内的多次写入只会真正落盘一次。
class PrefsStore {
  PrefsStore._();

  static const Duration debounce = Duration(milliseconds: 700);

  static final Map<String, Timer> _timers = <String, Timer>{};
  static final Map<String, Object?> _pending = <String, Object?>{};

  static Future<SharedPreferences> _instance() =>
      SharedPreferences.getInstance();

  static Future<String?> getString(String key) async {
    if (_pending.containsKey(key)) {
      final v = _pending[key];
      return v is String ? v : null;
    }
    final p = await _instance();
    return p.getString(key);
  }

  /// 立即写入（用于退出、切档等不能丢的场合）。
  static Future<void> setString(String key, String value) async {
    _timers.remove(key)?.cancel();
    _pending.remove(key);
    final p = await _instance();
    await p.setString(key, value);
  }

  static Future<void> remove(String key) async {
    _timers.remove(key)?.cancel();
    _pending.remove(key);
    final p = await _instance();
    await p.remove(key);
  }

  /// 防抖写入。高频调用安全。
  static void setStringDebounced(String key, String value) {
    _pending[key] = value;
    _timers[key]?.cancel();
    _timers[key] = Timer(debounce, () {
      final v = _pending.remove(key);
      _timers.remove(key);
      if (v is String) {
        _instance().then((p) => p.setString(key, v));
      }
    });
  }

  /// 把还在防抖窗口里的写入立刻落盘。
  static Future<void> flush() async {
    final keys = _pending.keys.toList();
    for (final k in keys) {
      final v = _pending.remove(k);
      _timers.remove(k)?.cancel();
      if (v is String) {
        final p = await _instance();
        await p.setString(k, v);
      }
    }
  }
}
