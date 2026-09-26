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
      defaultModel: 'qwen3.8-flash',
      hint: 'Key 形如 sk-xxxx。华北2（北京）若填了业务空间 ID，会自动改用专属域名。',
    ),
    ProviderOption(
      id: 'deepseek',
      label: 'DeepSeek 官方 API',
      defaultBaseUrl: 'https://api.deepseek.com/v1',
      defaultModel: 'deepseek-chat',
      hint: 'Key 形如 sk-xxxx。',
    ),
    ProviderOption(
      id: 'custom',
      label: '自定义 OpenAI 兼容接口',
      defaultBaseUrl: '',
      defaultModel: '',
      hint: '填完整的 Base URL，例如 https://api.example.com/v1',
    ),
  ];

  /// 百炼上常用的模型，做成快捷选项（仍可手填任意模型名）。
  static const List<String> bailianModels = <String>[
    'qwen3.8-flash',
    'qwen3.8-max',
    'qwen3.7-plus',
    'qwen3.7-flash',
    'qwen-plus',
  ];

  static const List<String> deepseekModels = <String>[
    'deepseek-chat',
    'deepseek-reasoner',
  ];

  static ProviderOption byId(String id) => options.firstWhere(
        (e) => e.id == id,
        orElse: () => options.first,
      );

  /// 解析出实际要请求的 Base URL。
  ///
  /// 百炼支持业务空间专属域名：`https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`，
  /// 稳定性更好，所以填了 WorkspaceId 就优先用它。
  static String resolveBaseUrl(AppConfig config, {String workspaceId = ''}) {
    final custom = config.baseUrl.trim();
    if (config.apiProvider == 'custom') return custom;

    final ws = workspaceId.trim();
    if (config.apiProvider == 'bailian' && ws.isNotEmpty) {
      return 'https://$ws.cn-beijing.maas.aliyuncs.com/compatible-mode/v1';
    }
    if (custom.isNotEmpty) return custom;
    return byId(config.apiProvider).defaultBaseUrl;
  }

  /// 拼成 `/chat/completions` 完整地址。
  static String chatCompletionsUrl(AppConfig config, {String workspaceId = ''}) {
    var base = resolveBaseUrl(config, workspaceId: workspaceId);
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    if (base.endsWith('/chat/completions')) return base;
    return '$base/chat/completions';
  }

  /// 只有支持思考模式的特定推理模型（如 qwen3.8 系列、qwen3、qwq 等）才支持 enable_thinking 参数。
  /// 普通模型（如 qwen-plus、qwen-turbo、qwen-max 等）绝不传 enable_thinking 以免百炼抛 400。
  static bool supportsThinkingSwitch(String model) {
    final norm = normalizeModelName(model).toLowerCase().trim();
    if (norm.startsWith('qwen3.8') ||
        norm.startsWith('qwen3-') ||
        norm.startsWith('qwen3_') ||
        norm == 'qwen3' ||
        norm.startsWith('qwq')) {
      return true;
    }
    return false;
  }

  /// 是否应当向请求体注入 enable_thinking 参数：
  /// 1. 自定义 OpenAI 兼容端点绝不注入（防止反代/第三方网关报错 400）；
  /// 2. DeepSeek 等通用端点绝不注入；
  /// 3. 仅限百炼且模型本身属于真正支持思考开关的推理模型（如 qwen3.8 系列、qwq）。
  static bool supportsThinkingParameter({
    required String apiProvider,
    required String modelName,
  }) {
    if (apiProvider == 'custom') return false;
    if (apiProvider == 'deepseek') return false;
    return supportsThinkingSwitch(normalizeModelName(modelName));
  }

  /// 模型名称智能归一化与拼写自愈。
  /// 兼容用户手填时漏写连字符（如 `qwen3.8flash` -> `qwen3.8-flash`、`qwen3.8max` -> `qwen3.8-max`），
  /// 以及大小写（如 `Qwen3.8-Flash` -> `qwen3.8-flash`）或下划线变体，
  /// 避免因官方模型代码大小写或连字符不匹配直接被服务端报 400 拒绝。
  static String normalizeModelName(String raw) {
    final m = raw.trim();
    if (m.isEmpty) return m;
    final lower = m.toLowerCase();

    // 常见标准模型的连字符/下划线拼写变体与大小写自愈
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
      case 'deepseekchat':
        return 'deepseek-chat';
      case 'deepseekreasoner':
        return 'deepseek-reasoner';
    }

    if (stripped.startsWith('qwq32b')) {
      return 'qwq-32b-preview';
    }

    return m;
  }
}
