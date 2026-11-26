import 'dart:convert';

/// 统一错误分类。
///
/// 所有网络、协议、解析异常都先归类为 [AppError]，
/// 保留服务端真实响应体作为排障依据，同时给出可读中文提示。
enum AppErrorKind {
  /// 连不上 / DNS 失败 / 连接或流式超时 / 断流
  network,

  /// 401 / 403：Key 错、Key 被停用、无该模型权限
  auth,

  /// 400 / 404 / 422：请求参数不合法、模型名不存在、端点路径错误
  badRequest,

  /// 429 或额度耗尽
  rateLimit,

  /// 5xx 服务端异常
  server,

  /// 模型拒答（内容审核拦截，返回空或只有致歉语）
  refused,

  /// 输出被截断（没有出现 `<choices>` 结构块或正文不完整）
  truncated,

  /// 返回体解析失败
  parse,

  /// 用户主动中止
  cancelled,

  unknown,
}

class AppError implements Exception {
  final AppErrorKind kind;

  /// 面向用户的中文说明，可直接显示。
  final String message;

  /// 原始信息（HTTP 状态码 / 真实响应体），用于日志排障。
  final String? detail;

  final int? statusCode;

  const AppError(this.kind, this.message, {this.detail, this.statusCode});

  /// 是否值得自动重试（纯网络波动、限流、5xx 服务端故障）。
  bool get retryable =>
      kind == AppErrorKind.network ||
      kind == AppErrorKind.server ||
      kind == AppErrorKind.rateLimit;

  /// 是否属于配置/凭证类硬错误（严禁盲目重试或降级覆盖存档）。
  bool get isConfigError =>
      kind == AppErrorKind.auth || kind == AppErrorKind.badRequest;

  /// 是否属于内容契约违背（拒答 / 缺分支）。
  bool get isContractFailure =>
      kind == AppErrorKind.refused || kind == AppErrorKind.truncated;

  /// 提取服务端 JSON 响应体中的真实错误描述。
  static String extractServerMessage(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) return '';
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] != null) {
          return err['message'].toString().trim();
        }
        if (err is String && err.trim().isNotEmpty) {
          return err.trim();
        }
        for (final key in const <String>['message', 'msg', 'detail']) {
          final v = decoded[key];
          if (v != null && v.toString().trim().isNotEmpty) {
            return v.toString().trim();
          }
        }
      }
    } catch (_) {
      // 非 JSON 响应体时保留简短原文
    }
    return '';
  }

  factory AppError.fromStatus(int statusCode, String body) {
    final brief = body.length > 400 ? '${body.substring(0, 400)}…' : body;
    final serverMsg = extractServerMessage(body);
    final suffix = serverMsg.isNotEmpty ? '：$serverMsg' : '';

    if (statusCode == 401 || statusCode == 403) {
      return AppError(
        AppErrorKind.auth,
        'API Key 无效或无权调用该模型（$statusCode）$suffix',
        detail: 'HTTP $statusCode · $brief',
        statusCode: statusCode,
      );
    }
    if (statusCode == 404) {
      return AppError(
        AppErrorKind.badRequest,
        '接口地址或模型不存在（404）$suffix。请检查 Base URL 与模型代码。',
        detail: 'HTTP 404 · $brief',
        statusCode: statusCode,
      );
    }
    if (statusCode == 400 || statusCode == 422) {
      final msg = serverMsg.isNotEmpty
          ? '请求参数被拒绝（$statusCode）：$serverMsg'
          : '请求被拒绝（$statusCode）：多为模型名不存在、参数不兼容或额度/上下文超限，请核对配置。';
      return AppError(
        AppErrorKind.badRequest,
        msg,
        detail: 'HTTP $statusCode · $brief',
        statusCode: statusCode,
      );
    }
    if (statusCode == 429) {
      return AppError(
        AppErrorKind.rateLimit,
        '请求过于频繁或账户额度已耗尽（429）$suffix，请稍后再试。',
        detail: 'HTTP 429 · $brief',
        statusCode: statusCode,
      );
    }
    if (statusCode >= 500) {
      return AppError(
        AppErrorKind.server,
        '模型服务端暂时不可用（$statusCode）$suffix。',
        detail: 'HTTP $statusCode · $brief',
        statusCode: statusCode,
      );
    }
    return AppError(
      AppErrorKind.unknown,
      '接口返回异常状态 $statusCode$suffix。',
      detail: 'HTTP $statusCode · $brief',
      statusCode: statusCode,
    );
  }

  @override
  String toString() => 'AppError(${kind.name}): $message';
}
