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

/// 运行日志 —— 内存环形缓冲 + 一键导出，用于开发排障。
///
/// 只记**诊断信息**（请求参数、SSE 分块、解析判定、重试链路、错误详情），
/// 不记 API Key。开关与详细级别由 [enabled] / [verbose] 控制，
/// 默认关闭 —— 不开启时 [log] 直接返回，零开销。
class RuntimeLog {
  RuntimeLog._();

  /// 上限：约 2000 条 / 2MB，超出丢最旧。
  static const int maxEntries = 2000;
  static const int maxMessageChars = 600;

  static final List<LogEntry> _buf = <LogEntry>[];

  /// 总开关（设置页可切）。
  static bool enabled = false;

  /// 详细模式：额外记录模型原文片段与逐条 SSE 行。
  static bool verbose = false;

  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static int get count => _buf.length;

  /// 密钥脱敏兜底 —— **最后一道防线**。
  ///
  /// 调用方约定「不传 key」，但网络异常 message / 服务端回显 / 代理响应
  /// 都可能夹带凭证。与其在每个调用点打补丁，不如在这里统一过滤一次。
  /// 宁可把正常字符误伤成 `***`，也不能让 key 落进可导出的日志里。
  static final List<RegExp> _secretPatterns = <RegExp>[
    // Bearer xxx / Authorization: xxx
    // 注意：Dart 的 RegExp 不支持 `(?i)` 内联标志，大小写不敏感要用 caseSensitive:false
    RegExp(
      r'\b(bearer|authorization|api[-_]?key|x-api-key)\b\s*[:=]?\s*\S+',
      caseSensitive: false,
    ),
    // ?key=xxx / &api_key=xxx
    RegExp(
      r'[?&](key|api[-_]?key|token|access[-_]?token)=[^&\s]+',
      caseSensitive: false,
    ),
    // sk-xxx / sk_xxx / gsk_xxx / hf_xxx 这类已知前缀
    RegExp(r'\b(?:sk|gsk|hf|pk|rk)[-_][A-Za-z0-9_\-]{12,}'),
    // JWT：三段式 eyJ...
    RegExp(r'\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}'),
  ];

  static String redact(String s) {
    var out = s;
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
      msg = '${msg.substring(0, maxMessageChars)}…(+${msg.length - maxMessageChars})';
    }
    _buf.add(LogEntry(DateTime.now(), level, tag, msg));
    while (_buf.length > maxEntries) {
      _buf.removeAt(0);
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

  /// 导出为可读文本（表头带环境信息，方便对号入座）。
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
