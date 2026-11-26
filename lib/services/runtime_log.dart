import 'package:flutter/foundation.dart';

/// 运行日志条目。
class LogEntry {
  final DateTime time;
  final String level; // I / W / E
  final String tag;
  final String message;

  LogEntry(this.time, this.level, this.tag, this.message);

  static String _two(int n) => n.toString().padLeft(2, '0');

  String get stamp {
    final d = time;
    return '${d.year}-${_two(d.month)}-${_two(d.day)} '
        '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}.'
        '${d.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  String toString() => '$stamp [$level] $tag — $message';
}

/// 运行日志 —— 内存环形缓冲 + 多密钥精准脱敏 + 一键导出。
class RuntimeLog {
  RuntimeLog._();

  static const int maxEntries = 2000;
  static const int maxMessageChars = 600;

  static final List<LogEntry> _buf = <LogEntry>[];

  static bool enabled = false;
  static bool verbose = false;

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static int get count => _buf.length;

  static final List<RegExp> _secretPatterns = <RegExp>[
    RegExp(
      r'\b(bearer|authorization|api[-_]?key|x-api-key)\b\s*[:=]?\s*\S+',
      caseSensitive: false,
    ),
    RegExp(
      r'[?&](key|api[-_]?key|token|access[-_]?token)=[^&\s]+',
      caseSensitive: false,
    ),
    RegExp(r'\b(?:sk|gsk|hf|pk|rk)[-_][A-Za-z0-9_\-]{12,}'),
    RegExp(r'\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}'),
  ];

  static String? _primarySecret;
  static final Set<String> _knownSecrets = <String>{};

  /// 兼容旧读写：当前主密钥，同时自动纳入多密钥脱敏池。
  static String? get configuredApiKey => _primarySecret;
  static set configuredApiKey(String? value) {
    _primarySecret = value;
    registerSecret(value);
  }

  /// 注册任意服务商/档案/辅助模型 API Key 进入脱敏池，杜绝跨厂商日志泄露。
  static void registerSecret(String? value) {
    final trimmed = value?.trim();
    if (trimmed != null && trimmed.length >= 4) {
      _knownSecrets.add(trimmed);
    }
  }

  static void clearSecrets() {
    _primarySecret = null;
    _knownSecrets.clear();
  }

  static String redact(String s) {
    var out = s;
    for (final secret in _knownSecrets) {
      if (secret.length >= 4) {
        out = out.replaceAll(secret, '[已脱敏]');
      }
    }
    final primary = _primarySecret?.trim();
    if (primary != null && primary.length >= 4) {
      out = out.replaceAll(primary, '[已脱敏]');
    }
    for (final p in _secretPatterns) {
      out = out.replaceAll(p, '[已脱敏]');
    }
    return out;
  }

  static void log(
    String level,
    String tag,
    String message, {
    bool detail = false,
  }) {
    if (!enabled) return;
    if (detail && !verbose) return;

    var msg = redact(message).replaceAll('\n', ' ⏎ ');
    if (msg.length > maxMessageChars) {
      msg =
          '${msg.substring(0, maxMessageChars)}…(+${msg.length - maxMessageChars})';
    }
    _buf.add(LogEntry(DateTime.now(), level, tag, msg));
    if (_buf.length > maxEntries) {
      _buf.removeRange(0, _buf.length - maxEntries);
    }
    revision.value++;
  }

  static void i(String tag, String message, {bool detail = false}) =>
      log('I', tag, message, detail: detail);

  static void w(String tag, String message, {bool detail = false}) =>
      log('W', tag, message, detail: detail);

  static void e(String tag, String message, {bool detail = false}) =>
      log('E', tag, message, detail: detail);

  static List<LogEntry> entries() => List<LogEntry>.from(_buf);

  static void clear() {
    _buf.clear();
    revision.value++;
  }

  static String dump() {
    final sb = StringBuffer()
      ..writeln('# 拟境 · 运行日志')
      ..writeln('# 导出时间：${DateTime.now().toIso8601String()}')
      ..writeln('# 条目数：${_buf.length}  详细模式：${verbose ? '开' : '关'}')
      ..writeln('# 平台：${defaultTargetPlatform.name}')
      ..writeln('-' * 60);
    for (final e in _buf) {
      sb.writeln(e.toString());
    }
    return sb.toString();
  }
}
