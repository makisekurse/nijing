import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/app_error.dart';
import '../models/app_config.dart';
import 'providers.dart';
import 'runtime_log.dart';

/// 流式分块类型：思考通道与正文通道从网络层开始**物理隔离**。
enum LlmChunkKind { thought, content }

/// 大模型流式增量事件。
class LlmChunk {
  final LlmChunkKind kind;
  final String text;

  const LlmChunk.thought(this.text) : kind = LlmChunkKind.thought;
  const LlmChunk.content(this.text) : kind = LlmChunkKind.content;

  bool get isThought => kind == LlmChunkKind.thought;
  bool get isContent => kind == LlmChunkKind.content;
}

/// 轻量级、确定性、零回溯的流式 `<think>` / `<thought>` 通道分流器。
///
/// 仅作用于 `delta.content` 通道，用于兼容少数不提供独立 `reasoning_content` 字段、
/// 而是把 `<think>...</think>` 直接混在 `content` 里吐出的第三方反代或本地模型（Ollama / vLLM）。
///
/// 对于原生提供 `reasoning_content` / `reasoning` 的标准 API，根本不经过此分流器，
/// 从源头杜绝思考草稿泄漏进正文。
class InlineThinkSplitter {
  bool _insideThink = false;
  String _openTagName = '';
  String _tail = '';

  bool get insideThink => _insideThink;

  static final RegExp _openTag = RegExp(
    r'[<＜《]\s*(think|thought)\s*[>＞》]',
    caseSensitive: false,
  );

  static final RegExp _partialTail = RegExp(r'[<＜《][/a-zA-Z\s]{0,12}$');

  /// 输入一段 `content` 增量，产出已物理分流的 [LlmChunk] 列表。
  List<LlmChunk> feed(String incoming) {
    if (incoming.isEmpty) return const <LlmChunk>[];
    final out = <LlmChunk>[];
    var data = _tail + incoming;
    _tail = '';

    while (data.isNotEmpty) {
      if (!_insideThink) {
        final m = _openTag.firstMatch(data);
        if (m != null) {
          final before = data.substring(0, m.start);
          if (before.isNotEmpty) out.add(LlmChunk.content(before));
          _insideThink = true;
          _openTagName = (m.group(1) ?? 'think').toLowerCase();
          data = data.substring(m.end);
          continue;
        }
        // 保留尾部可能被跨帧截断的半截开标签（如 "<thi"）
        final p = _partialTail.firstMatch(data);
        if (p != null) {
          final safe = data.substring(0, p.start);
          if (safe.isNotEmpty) out.add(LlmChunk.content(safe));
          _tail = data.substring(p.start);
        } else {
          out.add(LlmChunk.content(data));
        }
        break;
      } else {
        final closePattern = RegExp(
          r'[<＜《]\s*/\s*' + RegExp.escape(_openTagName) + r'\s*[>＞》]',
          caseSensitive: false,
        );
        final m = closePattern.firstMatch(data);
        if (m != null) {
          final inside = data.substring(0, m.start);
          if (inside.isNotEmpty) out.add(LlmChunk.thought(inside));
          _insideThink = false;
          _openTagName = '';
          data = data.substring(m.end);
          continue;
        }
        // 保留尾部可能被跨帧截断的半截闭标签（如 "</thi"）
        final p = _partialTail.firstMatch(data);
        if (p != null) {
          final safe = data.substring(0, p.start);
          if (safe.isNotEmpty) out.add(LlmChunk.thought(safe));
          _tail = data.substring(p.start);
        } else {
          out.add(LlmChunk.thought(data));
        }
        break;
      }
    }

    return out;
  }

  /// 流结束时冲刷残留缓冲。
  List<LlmChunk> flush() {
    if (_tail.isEmpty) return const <LlmChunk>[];
    final rem = _tail;
    _tail = '';
    return <LlmChunk>[
      _insideThink ? LlmChunk.thought(rem) : LlmChunk.content(rem),
    ];
  }
}

/// 统一的流式 / 非流式大模型客户端。
///
/// 核心保障：
/// 1. **原生双轨分流** —— `reasoning_content` 与 `content` 物理隔离为 [LlmChunk.thought] / [LlmChunk.content]；
/// 2. **400 参数自愈** —— 若服务端拒绝 `enable_thinking` / `thinking_budget` 或 `max_tokens` 超限，自动降级参数重试一次；
/// 3. **真报文透出** —— 识别 HTTP 非 200 与 SSE 流内嵌 `{"error": ...}`，绝不静默吞错；
/// 4. **超时与可中止** —— 30s 连接超时 + 60s 流式静默超时 + `cancel()` 立即断连。
class LlmClient {
  LlmClient({
    this.connectTimeout = const Duration(seconds: 30),
    this.idleTimeout = const Duration(seconds: 60),
  });

  final Duration connectTimeout;
  final Duration idleTimeout;
  static const int _maxNetworkRetries = 1;

  http.Client? _client;
  bool _cancelled = false;
  bool _yieldedAny = false;

  bool get isCancelled => _cancelled;

  /// 立刻中止当前请求。
  void cancel() {
    _cancelled = true;
    _client?.close();
    _client = null;
  }

  void reset() {
    _cancelled = false;
    _yieldedAny = false;
  }

  /// 是否允许空 Key（例如本地 Ollama / LM Studio / 局域网自建网关）。
  static bool _allowsEmptyKey(AppConfig config, String url) {
    if (config.apiProvider != 'custom') return false;
    final lower = url.toLowerCase();
    return lower.contains('://localhost') ||
        lower.contains('://127.0.0.1') ||
        lower.contains('://10.') ||
        lower.contains('://192.168.') ||
        lower.contains('://[::1]');
  }

  /// 根据单幕目标字数与思考模式计算充裕的 `max_tokens`。
  ///
  /// 彻底解除旧版将 `qwen-plus` 锁死 2000、`deepseek` 锁死 4096 导致的半路断章缺陷。
  static int calculateMaxTokens(
    int maxWords, {
    String? modelName,
    String? provider,
    bool enableThinking = false,
    int thinkingBudget = 0,
  }) {
    final normalized = Providers.normalizeModelName(modelName ?? '');
    final model = normalized.toLowerCase().trim();
    final isReasoning = enableThinking || Providers.isReasoningModel(model);

    if (isReasoning) {
      if (thinkingBudget > 0) {
        final withBody = thinkingBudget + math.max(3072, maxWords * 3);
        return withBody.clamp(8192, 32768).toInt();
      }
      if (model.contains('reasoner') || model.contains('-r1')) {
        return math.max(16384, maxWords * 4).clamp(16384, 32768).toInt();
      }
      return math.max(12288, maxWords * 4).clamp(12288, 16384).toInt();
    }

    // 普通模式：确保 3000 字长幕 + 结构块绝不因 token 不足被腰斩
    final base = math.max(4096, maxWords * 3);
    return base.clamp(4096, 12288).toInt();
  }

  /// 原生双轨流式生成：逐块 yield [LlmChunk]（思考与正文物理隔离）。
  Stream<LlmChunk> streamChunks({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
  }) async* {
    reset();
    final url = Providers.chatCompletionsUrl(config, workspaceId: workspaceId);
    if (url.isEmpty) {
      throw const AppError(
        AppErrorKind.badRequest,
        '尚未配置接口地址（Base URL），请前往「模型设置」填写。',
      );
    }
    if (apiKey.trim().isEmpty && !_allowsEmptyKey(config, url)) {
      throw const AppError(
        AppErrorKind.auth,
        '尚未配置 API Key，请前往「模型设置」填写后再试。',
      );
    }

    var attempt = 0;
    var stripThinkingParams = false;
    int? overrideMaxTokens;

    while (true) {
      try {
        yield* _singleStreamRequest(
          url: url,
          config: config,
          apiKey: apiKey,
          messages: messages,
          stripThinkingParams: stripThinkingParams,
          overrideMaxTokens: overrideMaxTokens,
        );
        return;
      } on AppError catch (e) {
        if (_cancelled) rethrow;

        // 智能 400 参数自愈：服务端拒绝思考扩展参数或 max_tokens 超限时，降级重试一次
        if (e.kind == AppErrorKind.badRequest && !_yieldedAny) {
          final detail = '${e.message} ${e.detail ?? ''}'.toLowerCase();
          if (!stripThinkingParams && _isThinkingParamError(detail)) {
            stripThinkingParams = true;
            RuntimeLog.w('LLM', '服务端不支持思考扩展参数，自动移除后重试：${e.message}');
            continue;
          }
          if (overrideMaxTokens == null && _isMaxTokensError(detail)) {
            overrideMaxTokens = _extractAllowedMaxTokens(detail) ?? 4096;
            RuntimeLog.w('LLM', 'max_tokens 超出模型限制，自动降级至 $overrideMaxTokens 重试');
            continue;
          }
        }

        final canRetry = e.retryable && !_yieldedAny && attempt < _maxNetworkRetries;
        if (!canRetry) rethrow;
        attempt++;
        RuntimeLog.w('LLM', '首帧前遇到可重试错误（${e.kind.name}），退避重试第 $attempt 次');
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt));
      }
    }
  }

  /// 向后兼容的字符串流接口（新逻辑请直接用 [streamChunks]）。
  Stream<String> streamChat({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String workspaceId = '',
  }) async* {
    var inThought = false;
    await for (final chunk in streamChunks(
      config: config,
      apiKey: apiKey,
      messages: messages,
      workspaceId: workspaceId.isEmpty ? null : workspaceId,
    )) {
      if (chunk.isThought) {
        if (!inThought) {
          inThought = true;
          yield '<think>';
        }
        yield chunk.text;
      } else {
        if (inThought) {
          inThought = false;
          yield '</think>\n\n';
        }
        yield chunk.text;
      }
    }
    if (inThought) {
      yield '</think>\n\n';
    }
  }

  Stream<LlmChunk> _singleStreamRequest({
    required String url,
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    required bool stripThinkingParams,
    required int? overrideMaxTokens,
  }) async* {
    final model = Providers.resolveModelName(config);
    if (model.isEmpty) {
      throw const AppError(
        AppErrorKind.badRequest,
        '尚未填写模型代码，请前往「模型设置」选择或输入模型名。',
      );
    }

    final cleanTemperature =
        double.parse(config.temperature.toStringAsFixed(2));
    final maxTokens = overrideMaxTokens ??
        calculateMaxTokens(
          config.maxWords,
          modelName: model,
          provider: config.apiProvider,
          enableThinking: config.enableThinking,
          thinkingBudget: config.thinkingBudget,
        );

    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      'max_tokens': maxTokens,
    };

    // o1 / o3 / o4 等推理模型在部分端点不允许传 temperature
    if (!RegExp(r'^o[134](?:-|$)').hasMatch(model.toLowerCase())) {
      body['temperature'] = cleanTemperature;
    }

    if (!stripThinkingParams &&
        Providers.supportsThinkingParameter(
          apiProvider: config.apiProvider,
          modelName: model,
        )) {
      body['enable_thinking'] = config.enableThinking;
      if (config.enableThinking && config.thinkingBudget > 0) {
        body['thinking_budget'] = config.thinkingBudget;
      }
    }

    final totalInputChars =
        messages.fold<int>(0, (a, m) => a + (m['content']?.length ?? 0));
    RuntimeLog.i(
      'LLM',
      'POST $url · model=$model · thinking=${body['enable_thinking'] ?? '默认'}'
      '${body.containsKey('thinking_budget') ? '(budget=${body['thinking_budget']})' : ''} · '
      'max_tokens=$maxTokens · msgs=${messages.length}/$totalInputChars字',
    );

    final request = http.Request('POST', Uri.parse(url));
    if (apiKey.trim().isNotEmpty) {
      request.headers['Authorization'] = 'Bearer ${apiKey.trim()}';
    }
    request.headers['Content-Type'] = 'application/json';
    request.headers['Accept'] = 'text/event-stream';
    request.headers['Cache-Control'] = 'no-cache';
    request.headers['Connection'] = 'keep-alive';
    request.headers['Accept-Encoding'] = 'identity';
    request.body = jsonEncode(body);

    final client = http.Client();
    _client = client;

    http.StreamedResponse response;
    try {
      response = await client.send(request).timeout(connectTimeout);
    } on TimeoutException {
      client.close();
      throw AppError(
        AppErrorKind.network,
        '连接模型服务超时（${connectTimeout.inSeconds} 秒无响应），请检查网络或代理。',
      );
    } catch (e) {
      client.close();
      if (_cancelled) {
        throw const AppError(AppErrorKind.cancelled, '已中止。');
      }
      throw AppError(
        AppErrorKind.network,
        '无法连接到模型服务，请检查网络连通性与 Base URL。',
        detail: e.toString(),
      );
    }

    if (response.statusCode != 200) {
      var text = '';
      try {
        text = await response.stream.bytesToString().timeout(connectTimeout);
      } catch (_) {}
      client.close();
      RuntimeLog.e('LLM', 'HTTP ${response.statusCode} · $text');
      throw AppError.fromStatus(response.statusCode, text);
    }

    final lines = response.stream
        .timeout(
          idleTimeout,
          onTimeout: (sink) {
            sink.addError(
              AppError(
                AppErrorKind.network,
                '流式数据接收超时（超过 ${idleTimeout.inSeconds} 秒无数据帧），网络连接可能已中断。',
              ),
            );
            sink.close();
          },
        )
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    final splitter = InlineThinkSplitter();
    var rawLines = 0;
    String? finishReason;

    try {
      await for (final line in lines) {
        if (_cancelled) {
          client.close();
          throw const AppError(AppErrorKind.cancelled, '已中止。');
        }
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        // 兼容部分中转站直接返回裸 JSON 错误体（非 SSE 包装，但 HTTP 200）
        if (trimmed.startsWith('{') && trimmed.contains('"error"')) {
          final msg = AppError.extractServerMessage(trimmed);
          if (msg.isNotEmpty) {
            throw AppError(
              AppErrorKind.server,
              '模型服务返回错误：$msg',
              detail: trimmed,
            );
          }
        }

        if (!trimmed.startsWith('data:')) continue;
        final payload = trimmed.substring(5).trim();
        if (payload.isEmpty || payload == '[DONE]') {
          if (payload == '[DONE]') break;
          continue;
        }

        rawLines++;
        RuntimeLog.i('LLM', 'SSE #$rawLines: $payload', detail: true);

        dynamic decoded;
        try {
          decoded = jsonDecode(payload);
        } catch (_) {
          continue;
        }
        if (decoded is! Map) continue;

        // 检测 SSE 内嵌 error 对象
        if (decoded['error'] != null) {
          final msg = AppError.extractServerMessage(payload);
          throw AppError(
            AppErrorKind.server,
            msg.isNotEmpty ? '模型流返回错误：$msg' : '模型流返回异常错误。',
            detail: payload,
          );
        }

        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final first = choices.first;
        if (first is! Map) continue;

        if (first['finish_reason'] is String) {
          finishReason = first['finish_reason'] as String;
        }

        final delta = first['delta'];
        if (delta is! Map) continue;

        final reasoning =
            delta['reasoning_content'] ?? delta['reasoning'] ?? delta['thought'];
        if (reasoning is String && reasoning.isNotEmpty) {
          _yieldedAny = true;
          yield LlmChunk.thought(reasoning);
        }

        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          for (final chunk in splitter.feed(content)) {
            _yieldedAny = true;
            yield chunk;
          }
        }
      }

      for (final tailChunk in splitter.flush()) {
        _yieldedAny = true;
        yield tailChunk;
      }

      RuntimeLog.i(
        'LLM',
        '流结束：SSE $rawLines 行 · finish_reason=${finishReason ?? 'none'} · '
            '${_yieldedAny ? '有内容' : '无内容'}',
      );
    } on AppError {
      rethrow;
    } on TimeoutException {
      if (_cancelled) {
        throw const AppError(AppErrorKind.cancelled, '已中止。');
      }
      throw AppError(
        AppErrorKind.network,
        '流式数据接收超时（超过 ${idleTimeout.inSeconds} 秒无数据帧），网络连接可能已中断。',
      );
    } catch (e) {
      if (_cancelled) {
        throw const AppError(AppErrorKind.cancelled, '已中止。');
      }
      throw AppError(
        AppErrorKind.network,
        '流式读取中断，网络可能不稳定。',
        detail: e.toString(),
      );
    } finally {
      client.close();
      if (identical(_client, client)) _client = null;
    }
  }

  /// 「测试连接」：发一个最小请求验证 Key / 端点 / 模型名是否可用。
  /// 返回 null 表示成功，否则返回可读的错误原因。
  Future<String?> testConnection({
    required AppConfig config,
    required String apiKey,
    String? workspaceId,
  }) async {
    final url = Providers.chatCompletionsUrl(config, workspaceId: workspaceId);
    if (url.isEmpty) return '请先填写 Base URL。';
    if (apiKey.trim().isEmpty && !_allowsEmptyKey(config, url)) {
      return '还没有填 API Key。';
    }
    final model = Providers.resolveModelName(config);
    if (model.isEmpty) return '请先填写模型代码。';

    var stripThinking = false;
    for (var attempt = 0; attempt < 2; attempt++) {
      final body = <String, dynamic>{
        'model': model,
        'messages': <Map<String, String>>[
          <String, String>{'role': 'user', 'content': '回复两个字：就绪'},
        ],
        'stream': false,
        'max_tokens': 32,
      };
      if (!stripThinking &&
          Providers.supportsThinkingParameter(
            apiProvider: config.apiProvider,
            modelName: model,
          )) {
        body['enable_thinking'] = false;
      }

      final client = http.Client();
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
        };
        if (apiKey.trim().isNotEmpty) {
          headers['Authorization'] = 'Bearer ${apiKey.trim()}';
        }
        final resp = await client
            .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 25));

        if (resp.statusCode == 200) return null;

        final respBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
        if (resp.statusCode == 400 &&
            !stripThinking &&
            _isThinkingParamError(respBody.toLowerCase())) {
          stripThinking = true;
          continue;
        }
        return AppError.fromStatus(resp.statusCode, respBody).message;
      } on TimeoutException {
        return '连接超时（25 秒），请检查网络或代理。';
      } catch (e) {
        return '连接失败：$e';
      } finally {
        client.close();
      }
    }
    return '连接失败，请检查接口配置。';
  }

  /// 非流式补全（用于编年史压缩、AI 一句话创建世界书等结构化场景）。
  ///
  /// 自动关闭百炼思考开关，并剥离任何模型可能夹带的 `<think>...</think>`，
  /// 确保返回纯净文本/JSON。
  Future<String> complete({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String? workspaceId,
    int maxTokens = 4096,
    double temperature = 0.5,
  }) async {
    final url = Providers.chatCompletionsUrl(config, workspaceId: workspaceId);
    if (url.isEmpty) {
      throw const AppError(AppErrorKind.badRequest, '尚未配置接口 Base URL。');
    }
    if (apiKey.trim().isEmpty && !_allowsEmptyKey(config, url)) {
      throw const AppError(AppErrorKind.auth, '尚未配置 API Key。');
    }
    final model = Providers.resolveModelName(config);
    if (model.isEmpty) {
      throw const AppError(AppErrorKind.badRequest, '尚未填写模型代码。');
    }

    var stripThinking = false;
    var effectiveMaxTokens = maxTokens;

    for (var attempt = 0; attempt < 2; attempt++) {
      final body = <String, dynamic>{
        'model': model,
        'messages': messages,
        'stream': false,
        'max_tokens': effectiveMaxTokens,
      };
      if (!RegExp(r'^o[134](?:-|$)').hasMatch(model.toLowerCase())) {
        body['temperature'] = temperature;
      }
      if (!stripThinking &&
          Providers.supportsThinkingParameter(
            apiProvider: config.apiProvider,
            modelName: model,
          )) {
        body['enable_thinking'] = false;
      }

      final client = http.Client();
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
        };
        if (apiKey.trim().isNotEmpty) {
          headers['Authorization'] = 'Bearer ${apiKey.trim()}';
        }
        final resp = await client
            .post(Uri.parse(url), headers: headers, body: jsonEncode(body))
            .timeout(const Duration(seconds: 90));

        final respBody = utf8.decode(resp.bodyBytes, allowMalformed: true);
        if (resp.statusCode != 200) {
          final lower = respBody.toLowerCase();
          if (resp.statusCode == 400 && attempt == 0) {
            if (!stripThinking && _isThinkingParamError(lower)) {
              stripThinking = true;
              continue;
            }
            if (_isMaxTokensError(lower)) {
              effectiveMaxTokens = _extractAllowedMaxTokens(lower) ?? 2000;
              continue;
            }
          }
          throw AppError.fromStatus(resp.statusCode, respBody);
        }

        final decoded = jsonDecode(respBody);
        if (decoded is Map) {
          if (decoded['error'] != null) {
            throw AppError(
              AppErrorKind.server,
              AppError.extractServerMessage(respBody),
              detail: respBody,
            );
          }
          final choices = decoded['choices'];
          if (choices is List && choices.isNotEmpty) {
            final first = choices.first;
            if (first is Map) {
              final msg = first['message'];
              if (msg is Map && msg['content'] is String) {
                return stripInlineThinkTags(msg['content'] as String);
              }
            }
          }
        }
        throw const AppError(AppErrorKind.parse, '模型返回体中找不到正文内容。');
      } on TimeoutException {
        throw const AppError(
          AppErrorKind.network,
          '请求超时（90 秒），请稍后再试。',
        );
      } finally {
        client.close();
      }
    }
    throw const AppError(AppErrorKind.unknown, '请求未能完成。');
  }

  /// 清理非流式输出里可能内嵌的 `<think>...</think>` 思考块。
  static String stripInlineThinkTags(String text) {
    return text
        .replaceAll(
          RegExp(
            r'[<＜《]\s*(think|thought)\s*[>＞》][\s\S]*?[<＜《]\s*/\s*\1\s*[>＞》]',
            caseSensitive: false,
          ),
          '',
        )
        .trim();
  }

  static bool _isThinkingParamError(String lower) =>
      lower.contains('enable_thinking') ||
      lower.contains('thinking_budget') ||
      lower.contains('extra_forbidden') ||
      lower.contains('unrecognized request argument');

  static bool _isMaxTokensError(String lower) =>
      lower.contains('max_tokens') &&
      (lower.contains('range') ||
          lower.contains('limit') ||
          lower.contains('maximum') ||
          lower.contains('invalid') ||
          lower.contains('exceed'));

  static int? _extractAllowedMaxTokens(String lower) {
    // 匹配形如 "[1, 8192]"、"<= 4096"、"maximum is 4096"
    final rangeMatch = RegExp(r'\[\s*\d+\s*,\s*(\d+)\s*\]').firstMatch(lower);
    if (rangeMatch != null) {
      return int.tryParse(rangeMatch.group(1) ?? '');
    }
    final maxMatch =
        RegExp(r'(?:max(?:imum)?|<=)\s*(?:is|of)?\s*(\d{3,5})').firstMatch(lower);
    if (maxMatch != null) {
      return int.tryParse(maxMatch.group(1) ?? '');
    }
    return null;
  }
}
