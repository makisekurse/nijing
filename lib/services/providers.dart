import '../models/app_config.dart';

/// 一家算力提供商的预设。
class ProviderOption {
  final String id;
  final String label;
  final String defaultBaseUrl;
  final String defaultModel;
  final String hint;

  const ProviderOption({
    required this.id,
    required this.label,
    required this.defaultBaseUrl,
    required this.defaultModel,
    this.hint = '',
  });
}

class Providers {
  Providers._();

  static const List<ProviderOption> options = <ProviderOption>[
    ProviderOption(
      id: 'bailian',
      label: '阿里云百炼（DashScope OpenAI 兼容）',
      defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      defaultModel: 'qwen-plus',
      hint: 'Key 形如 sk-xxxx。若填了华北2（北京）业务空间 ID，将自动走专属加速域名。',
    ),
    ProviderOption(
      id: 'deepseek',
      label: 'DeepSeek 官方 API',
      defaultBaseUrl: 'https://api.deepseek.com/v1',
      defaultModel: 'deepseek-chat',
      hint: 'Key 形如 sk-xxxx。deepseek-chat 适合快速叙事，deepseek-reasoner 为原生深度思考模型。',
    ),
    ProviderOption(
      id: 'custom',
      label: '自定义 OpenAI 兼容接口（中转 / 反代 / 本地）',
      defaultBaseUrl: '',
      defaultModel: '',
      hint: '填完整 Base URL（如 https://api.example.com/v1），兼容 OpenRouter / OneAPI / Gemini / Claude / GPT / Ollama 等。',
    ),
  ];

  /// 百炼常用快捷模型（仍可手填任意最新模型名）。
  static const List<String> bailianModels = <String>[
    'qwen-plus',
    'qwen-max',
    'qwen-turbo',
    'qwen3-235b-a22b',
    'qwen3-32b',
    'qwq-plus',
  ];

  static const List<String> deepseekModels = <String>[
    'deepseek-chat',
    'deepseek-reasoner',
  ];

  /// 自定义端点常见快捷参考（仅作快速填入参考，可任意修改）。
  static const List<String> customSampleModels = <String>[
    'deepseek-chat',
    'deepseek-reasoner',
    'gemini-2.5-pro',
    'claude-sonnet-4-5',
    'gpt-4.1',
  ];

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

  /// 该模型本身是否为原生推理 / 深度思考模型。
  static bool isReasoningModel(String model) {
    final norm = normalizeModelName(model).toLowerCase().trim();
    return norm.contains('reasoner') ||
        norm.contains('thinking') ||
        norm.startsWith('qwq') ||
        norm.startsWith('qwen3') ||
        norm.contains('-r1') ||
        norm.endsWith('r1') ||
        RegExp(r'^o[134](?:-|$)').hasMatch(norm);
  }

  /// 百炼上支持 `enable_thinking` 开关的模型判断。
  ///
  /// 支持 Qwen3 全系、Qwen-Plus / Turbo / Flash 思考版、QwQ 系列等。
  /// 即使百炼部分旧快照不认该字段，LlmClient 也有 400 自动剥离重试兜底。
  static bool supportsThinkingSwitch(String model) {
    final norm = normalizeModelName(model).toLowerCase().trim();
    if (norm.startsWith('qwen3') ||
        norm.startsWith('qwq') ||
        norm.startsWith('qwen-plus') ||
        norm.startsWith('qwen-turbo') ||
        norm.startsWith('qwen-flash')) {
      return true;
    }
    return false;
  }

  /// 是否应当向请求体注入百炼风格的 `enable_thinking` / `thinking_budget` 参数：
  /// 1. 自定义 OpenAI 兼容端点不默认注入私有字段（防第三方网关报 400），
  ///    除非用户填了明显的 `qwen3` / `qwq` 模型且直连百炼；
  /// 2. DeepSeek 官方通过 `deepseek-reasoner` 模型名区分思考，不传 `enable_thinking`；
  /// 3. 阿里云百炼对支持思考开关的 Qwen 系列注入 `enable_thinking` 与可选 `thinking_budget`。
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
      case 'qwenmax':
        return 'qwen-max';
      case 'qwqplus':
        return 'qwq-plus';
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
