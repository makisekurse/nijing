import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import '../core/app_error.dart';
import '../models/app_config.dart';
import 'providers.dart';
import 'runtime_log.dart';

/// 统一的流式大模型客户端。
///
/// 相比旧版补齐了三件事：
/// 1. **超时** —— 旧版没有超时，SSE 卡住会永久挂起，只能杀进程
/// 2. **可中止** —— [cancel] 立刻断开
/// 3. **错误分类 + 自动重试** —— 不再把异常整个吞掉
class LlmClient {
  LlmClient({this.connectTimeout = const Duration(seconds: 30)});

  final Duration connectTimeout;
  static const int _maxRetries = 2;

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

  /// 流式生成一幕。逐段 yield 文本增量。
  ///
  /// 抛出的异常一律是 [AppError]，UI 直接读 `message` 即可显示。
  Stream<String> streamChat({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String workspaceId = '',
  }) async* {
    reset();
    var attempt = 0;

    while (true) {
      try {
        yield* _singleRequest(
          config: config,
          apiKey: apiKey,
          messages: messages,
          workspaceId: workspaceId,
        );
        return;
      } on AppError catch (e) {
        final canRetry = e.retryable &&
            !_yieldedAny &&
            !_cancelled &&
            attempt < _maxRetries;
        if (!canRetry) rethrow;
        attempt++;
        // 指数退避：0.8s → 2.0s
        await Future<void>.delayed(Duration(milliseconds: 800 * attempt * attempt));
      }
    }
  }

  /// 根据单幕目标字数计算具备充足缓冲的 max_tokens。
  ///
  /// - 针对特定硬限模型（如百炼 `qwen-plus` 官方硬限 [1, 2000]），严格将安全上限截断在 2000；
  /// - 针对 DeepSeek 官方端点常见上限 4096；
  /// - 深度思考模式（enableThinking == true）：
  ///   由于 max_tokens 包含思考链与正文总和，为防止长思考耗尽预算导致服务端切断连接，
  ///   顶格提供充裕空间：保底 12288，上限 16384。
  /// - 普通无思考模式：默认按字数约 3 倍比例配置，保底 2048，上限 16384。
  static int calculateMaxTokens(
    int maxWords, {
    String? modelName,
    String? provider,
    bool enableThinking = false,
  }) {
    final normalized = Providers.normalizeModelName(modelName ?? '');
    final model = normalized.toLowerCase().trim();
    // 阿里云百炼普通模型官方规定严格的 max_tokens 区间：
    // qwen-turbo: [1, 1500]
    // qwen-plus, qwen-max: [1, 2000]
    if (model == 'qwen-turbo' || model.startsWith('qwen-turbo')) {
      return (maxWords * 3).clamp(1, 1500);
    }
    if (model == 'qwen-plus' ||
        model.startsWith('qwen-plus') ||
        model == 'qwen-max' ||
        model.startsWith('qwen-max')) {
      return (maxWords * 3).clamp(1, 2000);
    }
    // DeepSeek 官方 API 补全上限为 4096
    if (provider == 'deepseek' || model.startsWith('deepseek')) {
      return (maxWords * 3).clamp(1024, 4096);
    }

    if (enableThinking) {
      // 深度思考模式：思考过程 + 正文双重空间保障，彻底避免交接处撞墙超时切断
      final calculated = math.max(12288, maxWords * 5);
      return calculated.clamp(12288, 16384);
    }

    return (maxWords * 3).clamp(2048, 16384);
  }

  Stream<String> _singleRequest({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    required String workspaceId,
  }) async* {
    final url = Providers.chatCompletionsUrl(config, workspaceId: workspaceId);
    final rawModel = config.modelName.trim().isEmpty
        ? Providers.byId(config.apiProvider).defaultModel
        : config.modelName.trim();
    final model = Providers.normalizeModelName(rawModel);

    final cleanTemperature =
        double.parse(config.temperature.toStringAsFixed(2));
    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': true,
      'temperature': cleanTemperature,
      'max_tokens': calculateMaxTokens(
        config.maxWords,
        modelName: model,
        provider: config.apiProvider,
        enableThinking: config.enableThinking,
      ),
    };
    // 思考模式控制：严格按服务商与特定模型隔离注入。
    // 仅在百炼且属于真正支持思考参数的推理模型（如 qwen3.8 系列/qwq）上注入；
    // 自定义端点、DeepSeek 及普通模型（如 qwen-plus）绝不注入非法字段，防止 400 报错。
    if (Providers.supportsThinkingParameter(
      apiProvider: config.apiProvider,
      modelName: model,
    )) {
      body['enable_thinking'] = config.enableThinking;
      if (config.enableThinking && config.thinkingBudget > 0) {
        body['thinking_budget'] = config.thinkingBudget;
      }
    }

    RuntimeLog.i(
      'LLM',
      '请求 ${body['model']} · thinking=${body['enable_thinking'] ?? '默认'}'
      '${body.containsKey('thinking_budget') ? ' (budget=${body['thinking_budget']})' : ''} · '
      'temperature=$cleanTemperature · max_tokens=${body['max_tokens']} · '
      '消息 ${messages.length} 条 / ${messages.fold<int>(0, (a, m) => a + (m['content']?.length ?? 0))} 字',
    );

    final request = http.Request('POST', Uri.parse(url));
    request.headers['Authorization'] = 'Bearer ${apiKey.trim()}';
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
      throw const AppError(
        AppErrorKind.network,
        '连接模型服务超时（30 秒无响应），请检查网络或代理。',
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
      String text = '';
      try {
        text = await response.stream.bytesToString().timeout(connectTimeout);
      } catch (_) {
        text = '';
      }
      client.close();
      throw AppError.fromStatus(response.statusCode, text);
    }

    final lines = response.stream
        .timeout(
          const Duration(seconds: 20),
          onTimeout: (sink) {
            sink.addError(
              const AppError(
                AppErrorKind.network,
                '流式数据接收超时（超过 20 秒无数据帧），网络连接可能已中断。',
              ),
            );
            sink.close();
          },
        )
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    var insideReasoning = false;
    var rawLines = 0;

    try {
      await for (final line in lines) {
        if (_cancelled) {
          client.close();
          throw const AppError(AppErrorKind.cancelled, '已中止。');
        }
        final trimmed = line.trim();
        if (trimmed.isEmpty || !trimmed.startsWith('data:')) continue;

        final payload = trimmed.substring(5).trim();
        if (payload == '[DONE]') break;
        rawLines++;
        RuntimeLog.i('LLM', 'SSE #$rawLines: $payload', detail: true);

        String? chunk;
        try {
          final map = jsonDecode(payload);
          if (map is Map) {
            final choices = map['choices'];
            if (choices is List && choices.isNotEmpty) {
              final first = choices.first;
              if (first is Map) {
                final delta = first['delta'];
                if (delta is Map) {
                  final reasoning =
                      delta['reasoning_content'] ?? delta['reasoning'];
                  final content = delta['content'];
                  final chunkBuf = StringBuffer();

                  if (reasoning is String && reasoning.isNotEmpty) {
                    if (!insideReasoning) {
                      insideReasoning = true;
                      chunkBuf.write('<think>');
                    }
                    chunkBuf.write(reasoning);
                  }

                  if (content is String && content.isNotEmpty) {
                    if (insideReasoning) {
                      insideReasoning = false;
                      chunkBuf.write('</think>\n\n');
                    }
                    chunkBuf.write(content);
                  }

                  if (chunkBuf.isNotEmpty) {
                    chunk = chunkBuf.toString();
                  }
                }
              }
            }
          }
        } catch (_) {
          // 忽略非 JSON 行（有些实现会插入心跳）
        }

        if (chunk != null) {
          _yieldedAny = true;
          yield chunk;
        }
      }

      RuntimeLog.i('LLM', '流结束：SSE $rawLines 行 · '
          '${_yieldedAny ? '有内容' : '无内容'}');
      if (insideReasoning) {
        insideReasoning = false;
        _yieldedAny = true;
        yield '</think>\n\n';
      }
    } on AppError {
      rethrow;
    } on TimeoutException {
      if (_cancelled) {
        throw const AppError(AppErrorKind.cancelled, '已中止。');
      }
      throw const AppError(
        AppErrorKind.network,
        '流式数据接收超时（超过 20 秒无数据帧），网络连接可能已中断。',
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

  /// 「测试连接」按钮：发一个最小请求，只验证 Key / 端点 / 模型名是否可用。
  ///
  /// 返回 null 表示成功，否则返回可读的错误。
  Future<String?> testConnection({
    required AppConfig config,
    required String apiKey,
    String workspaceId = '',
  }) async {
    if (apiKey.trim().isEmpty) return '还没有填 API Key。';

    final url = Providers.chatCompletionsUrl(config, workspaceId: workspaceId);
    final rawModel = config.modelName.trim().isEmpty
        ? Providers.byId(config.apiProvider).defaultModel
        : config.modelName.trim();
    final model = Providers.normalizeModelName(rawModel);
    final body = <String, dynamic>{
      'model': model,
      'messages': <Map<String, String>>[
        <String, String>{'role': 'user', 'content': '回复两个字：就绪'},
      ],
      'stream': false,
      'max_tokens': 16,
    };
    if (Providers.supportsThinkingParameter(
      apiProvider: config.apiProvider,
      modelName: model,
    )) {
      body['enable_thinking'] = false;
    }

    final client = http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse(url),
            headers: <String, String>{
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 25));

      if (resp.statusCode == 200) return null;
      return AppError.fromStatus(resp.statusCode, resp.body).message;
    } on TimeoutException {
      return '连接超时（25 秒），请检查网络。';
    } catch (e) {
      return '连接失败：$e';
    } finally {
      client.close();
    }
  }

  /// 非流式补全。
  ///
  /// 用于需要**完整结构化输出**的场景（例如根据一句描述生成世界书）——
  /// 流式没法保证 JSON 完整，所以这类调用必须走这里。
  Future<String> complete({
    required AppConfig config,
    required String apiKey,
    required List<Map<String, String>> messages,
    String workspaceId = '',
    int maxTokens = 2400,
  }) async {
    final url = Providers.chatCompletionsUrl(config, workspaceId: workspaceId);
    final rawModel = config.modelName.trim().isEmpty
        ? Providers.byId(config.apiProvider).defaultModel
        : config.modelName.trim();
    final model = Providers.normalizeModelName(rawModel);
    int safeMaxTokens = maxTokens;
    if (model == 'qwen-turbo' || model.startsWith('qwen-turbo')) {
      safeMaxTokens = maxTokens.clamp(1, 1500);
    } else if (model == 'qwen-plus' ||
        model.startsWith('qwen-plus') ||
        model == 'qwen-max' ||
        model.startsWith('qwen-max')) {
      safeMaxTokens = maxTokens.clamp(1, 2000);
    } else if (config.apiProvider == 'deepseek' || model.startsWith('deepseek')) {
      safeMaxTokens = maxTokens.clamp(1, 4096);
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': messages,
      'stream': false,
      'temperature': 0.6,
      'max_tokens': safeMaxTokens,
    };
    if (Providers.supportsThinkingParameter(
      apiProvider: config.apiProvider,
      modelName: model,
    )) {
      body['enable_thinking'] = false;
    }

    final client = http.Client();
    try {
      final resp = await client
          .post(
            Uri.parse(url),
            headers: <String, String>{
              'Authorization': 'Bearer ${apiKey.trim()}',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 90));

      if (resp.statusCode != 200) {
        throw AppError.fromStatus(resp.statusCode, resp.body);
      }

      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is Map) {
        final choices = decoded['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map) {
            final msg = first['message'];
            if (msg is Map) {
              final c = msg['content'];
              if (c is String) return c;
            }
          }
        }
      }
      throw const AppError(AppErrorKind.parse, '返回体里找不到内容。');
    } on TimeoutException {
      throw const AppError(
        AppErrorKind.network,
        '生成超时（90 秒），请稍后再试。',
      );
    } finally {
      client.close();
    }
  }
}
