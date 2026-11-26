import '../models/app_config.dart';
import 'providers.dart';

/// 统一的推理协议方言（吸收 Kelivo `reasoning_dialects.dart` 设计范式，自主干净实现）。
///
/// 彻底告别在客户端四处散落 `if (model.startsWith(...))` 的补丁式逻辑：
/// - [qwenEnableThinking]：阿里云百炼（`enable_thinking` + 可选 `thinking_budget`）
/// - [deepseekV4Thinking]：DeepSeek V4（`thinking: {type: enabled|disabled}` + 可选 `reasoning_effort`）
/// - [openaiReasoningEffort]：OpenAI / 兼容 `reasoning_effort` 端点
/// - [none]：非破坏性透明模式，不注入厂商私有字段（仍自动解析流式 `reasoning_content` / `<think>`）
enum ReasoningDialect {
  qwenEnableThinking,
  deepseekV4Thinking,
  openaiReasoningEffort,
  none,
}

/// 采样参数兼容策略（如纯推理模型拒收 `temperature`）。
enum SamplingPolicy {
  always,
  onlyWhenReasoningOff,
  never,
}

class ReasoningDialectResolver {
  ReasoningDialectResolver._();

  /// 将配置中的手动方言覆写或自动探测结果解析为具体 [ReasoningDialect]。
  static ReasoningDialect resolve({
    required AppConfig config,
    required String modelName,
  }) {
    switch (config.reasoningDialect.trim().toLowerCase()) {
      case 'qwen':
      case 'qwen_enable_thinking':
        return ReasoningDialect.qwenEnableThinking;
      case 'deepseek_v4':
      case 'deepseek':
        return ReasoningDialect.deepseekV4Thinking;
      case 'openai':
      case 'openai_effort':
        return ReasoningDialect.openaiReasoningEffort;
      case 'none':
        return ReasoningDialect.none;
      case 'auto':
      default:
        break;
    }

    final norm = Providers.normalizeModelName(modelName).toLowerCase().trim();
    if (config.apiProvider == 'bailian') {
      if (Providers.supportsThinkingSwitch(norm)) {
        return ReasoningDialect.qwenEnableThinking;
      }
      return ReasoningDialect.none;
    }

    if (config.apiProvider == 'deepseek') {
      // DeepSeek V4 官方（deepseek-flash / deepseek-v4-pro）走 thinking.type 开关；
      // 兼容旧版未迁移的 deepseek-reasoner（不发 thinking 字段避免老网关 400）
      if (norm.contains('deepseek-flash') ||
          norm.contains('deepseek-v4') ||
          norm.startsWith('deepseek-v4')) {
        return ReasoningDialect.deepseekV4Thinking;
      }
      return ReasoningDialect.none;
    }

    // 自定义端点：默认非破坏性，绝不盲塞私有字段引发第三方中转 400；
    // 仅对标准 OpenAI o1/o3/o4 推理系使用标准 reasoning_effort。
    if (RegExp(r'^o[134](?:-|$)').hasMatch(norm)) {
      return ReasoningDialect.openaiReasoningEffort;
    }
    return ReasoningDialect.none;
  }

  /// 采样参数（temperature 等）的发送策略。
  static SamplingPolicy samplingPolicy(String modelName) {
    final norm = Providers.normalizeModelName(modelName).toLowerCase().trim();
    if (RegExp(r'^o[134](?:-|$)').hasMatch(norm)) {
      return SamplingPolicy.never;
    }
    if (norm == 'deepseek-reasoner') {
      return SamplingPolicy.never;
    }
    return SamplingPolicy.always;
  }

  /// 是否允许为该模型在请求体中附带 `temperature`。
  static bool allowsTemperature({
    required String modelName,
    required bool thinkingEnabled,
  }) {
    switch (samplingPolicy(modelName)) {
      case SamplingPolicy.always:
        return true;
      case SamplingPolicy.never:
        return false;
      case SamplingPolicy.onlyWhenReasoningOff:
        return !thinkingEnabled;
    }
  }

  /// 某些纯思考版模型（如 `qwq-plus` / `qwq-32b`）在百炼上不允许显式传 `enable_thinking: false`。
  static bool canDisableThinking(String modelName) {
    final norm = Providers.normalizeModelName(modelName).toLowerCase().trim();
    if (norm.startsWith('qwq')) return false;
    return true;
  }

  /// 将思考模式与预算参数精准写入请求体（流式主推演使用）。
  static void applyStreamingThinking(
    Map<String, dynamic> body, {
    required AppConfig config,
    required String modelName,
    required bool stripThinkingParams,
  }) {
    if (stripThinkingParams) return;
    final dialect = resolve(config: config, modelName: modelName);

    switch (dialect) {
      case ReasoningDialect.qwenEnableThinking:
        if (!config.enableThinking && !canDisableThinking(modelName)) {
          return;
        }
        body['enable_thinking'] = config.enableThinking;
        if (config.enableThinking && config.thinkingBudget > 0) {
          body['thinking_budget'] = config.thinkingBudget;
        }
        break;
      case ReasoningDialect.deepseekV4Thinking:
        body['thinking'] = <String, dynamic>{
          'type': config.enableThinking ? 'enabled' : 'disabled',
        };
        if (config.enableThinking) {
          final effort = _normalizeDeepSeekEffort(config.reasoningEffort);
          if (effort.isNotEmpty) {
            body['reasoning_effort'] = effort;
          }
        }
        break;
      case ReasoningDialect.openaiReasoningEffort:
        if (config.enableThinking) {
          final effort = _normalizeOpenAiEffort(config.reasoningEffort);
          if (effort.isNotEmpty) {
            body['reasoning_effort'] = effort;
          }
        }
        break;
      case ReasoningDialect.none:
        break;
    }
  }

  /// 为非流式结构化后台任务（编年史 / 状态抽取 / 世界书扩写 / 连接测试）安全关闭思考。
  static void applyDisableThinking(
    Map<String, dynamic> body, {
    required AppConfig config,
    required String modelName,
    required bool stripThinkingParams,
  }) {
    if (stripThinkingParams) return;
    final dialect = resolve(config: config, modelName: modelName);

    switch (dialect) {
      case ReasoningDialect.qwenEnableThinking:
        if (canDisableThinking(modelName)) {
          body['enable_thinking'] = false;
        }
        break;
      case ReasoningDialect.deepseekV4Thinking:
        body['thinking'] = <String, dynamic>{'type': 'disabled'};
        break;
      case ReasoningDialect.openaiReasoningEffort:
      case ReasoningDialect.none:
        break;
    }
  }

  static String _normalizeDeepSeekEffort(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'low':
        return 'low';
      case 'max':
        return 'max';
      case 'medium':
      case 'high':
      default:
        return 'high';
    }
  }

  static String _normalizeOpenAiEffort(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'low':
        return 'low';
      case 'medium':
        return 'medium';
      case 'max':
      case 'high':
      default:
        return 'high';
    }
  }
}
