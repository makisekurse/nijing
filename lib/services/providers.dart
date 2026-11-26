import 'package:dio/dio.dart';

import '../core/app_error.dart';
import '../models/app_config.dart';

/// 一家算力提供商的预设。
class ProviderOption {
  final String id;
  final String label;
  final String shortLabel;
  final String defaultBaseUrl;
  final String defaultModel;
  final String recommendedAuxModel;
  final String hint;

  const ProviderOption({
    required this.id,
    required this.label,
    required this.shortLabel,
    required this.defaultBaseUrl,
    required this.defaultModel,
    this.recommendedAuxModel = '',
    this.hint = '',
  });
}

/// 通过 `GET /models` 动态拉取到的远端模型条目。
class RemoteModelInfo {
  final String id;
  final String ownedBy;

  const RemoteModelInfo({required this.id, this.ownedBy = ''});
}

class Providers {
  Providers._();

  static const List<ProviderOption> options = <ProviderOption>[
    ProviderOption(
      id: 'bailian',
      label: '阿里云百炼（DashScope OpenAI 兼容）',
      shortLabel: '阿里云百炼',
      defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      defaultModel: 'qwen4-max',
      recommendedAuxModel: 'qwen-flash',
      hint: 'Key 形如 sk-xxxx。推荐主力用 qwen4-max（1M 上下文），后台档案官用 qwen-flash；支持一键拉取最新模型列表。',
    ),
    ProviderOption(
      id: 'deepseek',
      label: 'DeepSeek 官方 API（V4 系列）',
      shortLabel: 'DeepSeek',
      defaultBaseUrl: 'https://api.deepseek.com/v1',
      defaultModel: 'deepseek-flash',
      recommendedAuxModel: 'deepseek-flash',
      hint: '官方已全面切换至 V4 系列：deepseek-flash（极速全能，可开关思考）与 deepseek-v4-pro（旗舰深度推理）；旧版 deepseek-chat / reasoner 已退役。',
    ),
    ProviderOption(
      id: 'custom',
      label: '自定义 OpenAI 兼容（中转 / 反代 / 本地）',
      shortLabel: '自定义接口',
      defaultBaseUrl: '',
      defaultModel: '',
      recommendedAuxModel: '',
      hint: '填完整 Base URL（如 https://api.example.com/v1），点「拉取模型」直接读取该端点全部可用模型，兼容 OpenRouter / OneAPI / Gemini / Claude / GPT / Ollama。',
    ),
  ];

  /// 阿里云百炼 2026 常用快捷模型（支持下方一键动态拉取最新完整列表）。
  static const List<String> bailianModels = <String>[
    'qwen4-max',
    'qwen3.5-plus',
    'qwen-max',
    'qwen-plus',
    'qwen-flash',
    'qwen-turbo',
  ];

  /// DeepSeek 官方 2026 V4 系列模型。
  static const List<String> deepseekModels = <String>[
    'deepseek-flash',
    'deepseek-v4-pro',
  ];

  /// 自定义端点 2026 快捷参考（仅作快速填入参考，推荐直接用「拉取模型」动态同步）。
  static const List<String> customSampleModels = <String>[
    'qwen4-max',
    'deepseek-v4-pro',
    'deepseek-flash',
    'gemini-4-neon',
    'gemini-4-hydrogen',
    'gemini-3.8-flash',
    'claude-sonnet-5.5',
    'claude-opus-5.5',
    'gpt-6.2-sol',
    'gpt-6.2-astra',
  ];

  /// 已退役的旧模型名映射提示（不强制覆写用户自定义输入，仅做温和提示与兼容识别）。
  static bool isRetiredDeepSeekModel(String model) {
    final norm = normalizeModelName(model).toLowerCase().trim();
    return norm == 'deepseek-chat' || norm == 'deepseek-reasoner';
  }

  static ProviderOption byId(String id) => options.firstWhere(
        (e) => e.id == id,
        orElse: () => options.first,
      );

  /// 实际解析本次请求的模型名。
  static String resolveModelName(AppConfig config) {
    final raw = config.modelName.trim().isEmpty
        ? byId(config.apiProvider).defaultModel
        : config.modelName.trim();
    return normalizeModelName(raw);
  }

  /// 解析出实际要请求的 Base URL。
  ///
  /// 显式传入的 [workspaceId] 优先；未传入时自动读取 `config.workspaceId`。
  static String resolveBaseUrl(AppConfig config, {String? workspaceId}) {
    final custom = config.baseUrl.trim();
    if (config.apiProvider == 'custom') return custom;

    final ws = (workspaceId ?? config.workspaceId).trim();
    if (config.apiProvider == 'bailian' && ws.isNotEmpty) {
      return 'https://$ws.cn-beijing.maas.aliyuncs.com/compatible-mode/v1';
    }
    if (custom.isNotEmpty) return custom;
    return byId(config.apiProvider).defaultBaseUrl;
  }

  /// 拼成 `/chat/completions` 完整地址。
  static String chatCompletionsUrl(AppConfig config, {String? workspaceId}) {
    var base = resolveBaseUrl(config, workspaceId: workspaceId).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isEmpty) return '';
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  /// 拼成 `/models` 动态拉取地址（兼容百炼业务空间与标准 OpenAI `/v1/models`）。
  static String modelsListUrl(AppConfig config, {String? workspaceId}) {
    var base = resolveBaseUrl(config, workspaceId: workspaceId).trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.isEmpty) return '';
    if (base.endsWith('/chat/completions')) {
      base = base.substring(0, base.length - '/chat/completions'.length);
    }
    if (base.endsWith('/models')) return base;
    return '$base/models';
  }

  /// 实时从远端接口拉取可用模型列表（借鉴 Kelivo / Cherry Studio 动态模型目录）。
  ///
  /// 兼容标准 OpenAI `{"data": [{"id": ...}]}`、DashScope `{"output": {"models": ...}}` 及裸数组格式。
  static Future<List<RemoteModelInfo>> fetchRemoteModels({
    required AppConfig config,
    required String apiKey,
    String? workspaceId,
    Dio? dio,
  }) async {
    final urls = <String>[];
    final primaryUrl = modelsListUrl(config, workspaceId: workspaceId);
    if (primaryUrl.isNotEmpty) urls.add(primaryUrl);

    // 阿里云百炼业务空间端点补充原生 /api/v1/models 回退路径
    final ws = (workspaceId ?? config.workspaceId).trim();
    if (config.apiProvider == 'bailian' && ws.isNotEmpty) {
      urls.add('https://$ws.cn-beijing.maas.aliyuncs.com/api/v1/models');
    }

    if (urls.isEmpty) {
      throw const AppError(AppErrorKind.badRequest, '请先填写 Base URL。');
    }

    final client = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (_) => true,
          ),
        );

    final headers = <String, dynamic>{
      'Accept': 'application/json',
      if (apiKey.trim().isNotEmpty) 'Authorization': 'Bearer ${apiKey.trim()}',
    };

    AppError? lastErr;
    for (final url in urls) {
      try {
        final resp = await client.get<dynamic>(
          url,
          options: Options(headers: headers),
        );
        final status = resp.statusCode ?? 0;
        if (status != 200) {
          lastErr = AppError.fromStatus(status, '${resp.data ?? ''}');
          continue;
        }
        final parsed = parseRemoteModelsPayload(resp.data);
        if (parsed.isNotEmpty) return parsed;
        lastErr = const AppError(AppErrorKind.parse, '远端返回成功，但模型列表为空。');
      } on DioException catch (e) {
        lastErr = AppError(
          AppErrorKind.network,
          '拉取模型列表失败：${e.message ?? '网络不可达'}',
          detail: e.toString(),
        );
      } catch (e) {
        lastErr = AppError(AppErrorKind.unknown, '拉取模型列表异常：$e');
      }
    }

    throw lastErr ?? const AppError(AppErrorKind.unknown, '无法拉取模型列表。');
  }

  /// 解析 `/models` 响应体为去重排序后的 [RemoteModelInfo] 列表（纯函数，便于单元测试）。
  static List<RemoteModelInfo> parseRemoteModelsPayload(dynamic data) {
    List<dynamic>? rawList;
    if (data is Map) {
      if (data['data'] is List) {
        rawList = data['data'] as List<dynamic>;
      } else if (data['models'] is List) {
        rawList = data['models'] as List<dynamic>;
      } else if (data['output'] is Map &&
          (data['output'] as Map)['models'] is List) {
        rawList = (data['output'] as Map)['models'] as List<dynamic>;
      }
    } else if (data is List) {
      rawList = data;
    }
    if (rawList == null) return const <RemoteModelInfo>[];

    final seen = <String>{};
    final out = <RemoteModelInfo>[];
    for (final item in rawList) {
      String id = '';
      String owner = '';
      if (item is String) {
        id = item.trim();
      } else if (item is Map) {
        id = (item['id'] ?? item['model'] ?? item['name'] ?? '').toString().trim();
        owner = (item['owned_by'] ?? item['provider'] ?? '').toString().trim();
      }
      if (id.isEmpty || !seen.add(id)) continue;
      out.add(RemoteModelInfo(id: id, ownedBy: owner));
    }

    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// 该模型本身是否为原生推理 / 深度思考模型。
  static bool isReasoningModel(String model) {
    final norm = normalizeModelName(model).toLowerCase().trim();
    return norm.contains('reasoner') ||
        norm.contains('thinking') ||
        norm.startsWith('qwq') ||
        norm.startsWith('qwen4') ||
        norm.startsWith('qwen3') ||
        norm.contains('deepseek-v4') ||
        norm.contains('deepseek-flash') ||
        norm.contains('-r1') ||
        norm.endsWith('r1') ||
        RegExp(r'^o[134](?:-|$)').hasMatch(norm);
  }

  /// 百炼上支持 `enable_thinking` 开关的模型判断。
  ///
  /// 支持 Qwen4 全系、Qwen3.5/Qwen3 全系、Qwen-Max/Plus/Turbo/Flash 思考版、QwQ 系列等。
  static bool supportsThinkingSwitch(String model) {
    final norm = normalizeModelName(model).toLowerCase().trim();
    if (norm.startsWith('qwen4') ||
        norm.startsWith('qwen3') ||
        norm.startsWith('qwq') ||
        norm.startsWith('qwen-plus') ||
        norm.startsWith('qwen-turbo') ||
        norm.startsWith('qwen-flash')) {
      return true;
    }
    return false;
  }

  /// 是否应当向请求体注入百炼风格的 `enable_thinking` / `thinking_budget` 参数（保留向后兼容）。
  static bool supportsThinkingParameter({
    required String apiProvider,
    required String modelName,
  }) {
    if (apiProvider == 'custom') return false;
    if (apiProvider == 'deepseek') return false;
    return supportsThinkingSwitch(normalizeModelName(modelName));
  }

  /// 模型名称智能归一化与拼写自愈（只修明显拼写错误，绝不破坏用户的自定义模型名）。
  static String normalizeModelName(String raw) {
    final m = raw.trim();
    if (m.isEmpty) return m;
    final lower = m.toLowerCase();

    final stripped = lower.replaceAll(RegExp(r'[-_]'), '');
    switch (stripped) {
      case 'qwen4max':
        return 'qwen4-max';
      case 'qwen4plus':
        return 'qwen4-plus';
      case 'qwen4flash':
        return 'qwen4-flash';
      case 'qwen3.5plus':
        return 'qwen3.5-plus';
      case 'qwen3.8flash':
        return 'qwen3.8-flash';
      case 'qwen3.8max':
        return 'qwen3.8-max';
      case 'qwen3.7flash':
        return 'qwen3.7-flash';
      case 'qwen3.7plus':
        return 'qwen3.7-plus';
      case 'qwenplus':
        return 'qwen-plus';
      case 'qwenturbo':
        return 'qwen-turbo';
      case 'qwenflash':
        return 'qwen-flash';
      case 'qwenmax':
        return 'qwen-max';
      case 'qwqplus':
        return 'qwq-plus';
      case 'deepseekflash':
        return 'deepseek-flash';
      case 'deepseekv4pro':
        return 'deepseek-v4-pro';
      case 'deepseekchat':
        return 'deepseek-chat';
      case 'deepseekreasoner':
        return 'deepseek-reasoner';
    }

    if (stripped.startsWith('qwq32b')) {
      return 'qwq-32b';
    }

    return m;
  }
}
