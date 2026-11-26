import 'dart:convert';

import 'model_profile.dart';

/// 全局配置（v2.0 升级：支持 2026 模型方言、主辅双模型分工、多配置档案与书卷排版）。
///
/// ⚠️ `apiKey` **不参与 JSON 序列化** —— 它单独存进系统加密存储
/// （`flutter_secure_storage`），落盘的是密文而不是明文。
class AppConfig {
  /// 'bailian' | 'deepseek' | 'custom'
  String apiProvider;

  /// 自定义端点（provider 为 custom 时必填；其余留空走默认端点）
  String baseUrl;

  /// 阿里云百炼业务空间 ID（仅 bailian 可选填；统一收口到配置中，避免测试连接与实际推演分裂）
  String workspaceId;

  /// 当前选用的主力模型代码
  String modelName;

  /// 推理协议方言：'auto' | 'qwen' | 'deepseek_v4' | 'openai' | 'none'
  String reasoningDialect;

  /// 推理力度：'low' | 'medium' | 'high' | 'max'（DeepSeek V4 / OpenAI 推理协议使用）
  String reasoningEffort;

  double temperature;

  /// 单幕目标字数，提示词里会带上。
  int maxWords;

  /// 是否启用后台静默异步提取（状态 / 人物 / 词条解耦，解放主模型文笔与速度）。
  bool enableBackgroundExtract;

  /// 是否为后台状态/编年史单独指定轻量快速辅助模型（如 qwen3.8-flash / deepseek-flash）。
  /// 关闭时自动复用主模型并按方言强制关闭思考，零配置开箱即用。
  bool enableAuxModel;

  /// 辅助模型服务商（为空时沿用主服务商）
  String auxApiProvider;

  /// 辅助模型自定义 Base URL（为空时沿用主端点）
  String auxBaseUrl;

  /// 辅助模型业务空间 ID
  String auxWorkspaceId;

  /// 辅助模型代码（如 qwen3.8-flash / deepseek-flash / gemini-3.8-flash）
  String auxModelName;

  /// 已保存的多套模型配置档案，供设置页与阅读页一键切换。
  List<ModelProfile> savedProfiles;

  /// 当前激活的模型档案 ID（空串表示手动服务商槽位配置，未绑定特定档案）。
  String activeProfileId;

  /// 'mirage'（拟境，默认）| 'vintage' | 'dark' | 'parchment'
  String themeMode;

  /// 'sm' | 'md' | 'lg'
  String fontSize;

  double lineHeight;

  /// 段首缩进格数（0 / 1 / 2）。
  int paragraphIndent;

  /// 段间距：'tight' | 'normal' | 'loose'
  String paragraphSpacing;

  /// 正文使用书卷衬线风格字体排版。
  bool serifReading;

  /// 打开推演时自动跳到最新一幕。
  bool autoScrollToLatest;

  /// 顶栏自动隐藏（保留配置兼容；v2.0 阅读器改为克制顶栏不乱闪）
  bool autoHideHeader;

  /// 阅读防熄屏（保持屏幕常亮）
  bool keepScreenOn;

  /// 主宰模式（玩家最高权限 / 绝对意志）
  bool godMode;

  /// 模型深度思考模式（Thinking / Reasoning 模式）
  bool enableThinking;

  /// 思考预算（0 为不设限/自由顶格，或 1024 / 2048 / 4096 / 8192）
  int thinkingBudget;

  /// 运行日志（排障用）。默认关闭 —— 不开就是零开销。
  bool logEnabled;

  /// 详细日志：额外记录 SSE 原始行与模型原文片段，量很大。
  bool verboseLog;

  AppConfig({
    this.apiProvider = 'bailian',
    this.baseUrl = '',
    this.workspaceId = '',
    this.modelName = 'qwen4-max',
    this.reasoningDialect = 'auto',
    this.reasoningEffort = 'high',
    this.temperature = 0.85,
    int maxWords = 800,
    this.enableBackgroundExtract = true,
    this.enableAuxModel = false,
    this.auxApiProvider = '',
    this.auxBaseUrl = '',
    this.auxWorkspaceId = '',
    this.auxModelName = '',
    List<ModelProfile>? savedProfiles,
    this.activeProfileId = '',
    this.themeMode = 'mirage',
    this.fontSize = 'md',
    this.lineHeight = 1.9,
    this.paragraphIndent = 2,
    this.paragraphSpacing = 'normal',
    this.serifReading = false,
    this.autoScrollToLatest = true,
    this.autoHideHeader = false,
    this.keepScreenOn = true,
    this.godMode = false,
    this.enableThinking = true,
    this.thinkingBudget = 0,
    this.logEnabled = false,
    this.verboseLog = false,
  })  : maxWords = maxWords.clamp(200, 3000),
        savedProfiles = savedProfiles ?? <ModelProfile>[];

  /// 解析给后台档案官 / 编年史压缩使用的有效配置。
  ///
  /// 若用户开启并填写了辅助模型，走辅助配置；否则无缝复用主配置。
  /// 无论哪种情况，后台结构化任务都会强制关闭深度思考。
  AppConfig resolveAuxConfig() {
    if (!enableAuxModel || auxModelName.trim().isEmpty) {
      return copyWith(
        workspaceId: apiProvider == 'bailian' ? workspaceId : '',
        enableThinking: false,
      );
    }
    final effProvider =
        auxApiProvider.trim().isEmpty ? apiProvider : auxApiProvider.trim();
    final sameProvider = effProvider == apiProvider;
    final effWorkspaceId = effProvider == 'bailian'
        ? (auxWorkspaceId.trim().isNotEmpty
            ? auxWorkspaceId.trim()
            : (sameProvider ? workspaceId : ''))
        : '';
    return copyWith(
      apiProvider: effProvider,
      baseUrl: auxBaseUrl.trim().isNotEmpty
          ? auxBaseUrl.trim()
          : (sameProvider ? baseUrl : ''),
      workspaceId: effWorkspaceId,
      modelName: auxModelName.trim(),
      reasoningDialect: 'auto',
      enableThinking: false,
      thinkingBudget: 0,
    );
  }

  /// 一键将指定 [ModelProfile] 应用到当前主力模型配置。
  AppConfig applyProfile(ModelProfile profile) => copyWith(
        apiProvider: profile.apiProvider,
        baseUrl: profile.baseUrl,
        workspaceId: profile.workspaceId,
        modelName: profile.modelName,
        reasoningDialect: profile.reasoningDialect,
        enableThinking: profile.enableThinking,
        thinkingBudget: profile.thinkingBudget,
        reasoningEffort: profile.reasoningEffort,
        activeProfileId: profile.id,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'apiProvider': apiProvider,
        'baseUrl': baseUrl,
        'workspaceId': workspaceId,
        'modelName': modelName,
        'reasoningDialect': reasoningDialect,
        'reasoningEffort': reasoningEffort,
        'temperature': temperature,
        'maxWords': maxWords,
        'enableBackgroundExtract': enableBackgroundExtract,
        'enableAuxModel': enableAuxModel,
        'auxApiProvider': auxApiProvider,
        'auxBaseUrl': auxBaseUrl,
        'auxWorkspaceId': auxWorkspaceId,
        'auxModelName': auxModelName,
        'savedProfiles': savedProfiles.map((p) => p.toJson()).toList(),
        'activeProfileId': activeProfileId,
        'themeMode': themeMode,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'paragraphIndent': paragraphIndent,
        'paragraphSpacing': paragraphSpacing,
        'serifReading': serifReading,
        'autoScrollToLatest': autoScrollToLatest,
        'autoHideHeader': autoHideHeader,
        'keepScreenOn': keepScreenOn,
        'godMode': godMode,
        'enableThinking': enableThinking,
        'thinkingBudget': thinkingBudget,
        'logEnabled': logEnabled,
        'verboseLog': verboseLog,
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        apiProvider: (json['apiProvider'] ?? 'bailian').toString(),
        baseUrl: (json['baseUrl'] ?? '').toString(),
        workspaceId: (json['workspaceId'] ?? '').toString(),
        modelName: (json['modelName'] ?? 'qwen4-max').toString(),
        reasoningDialect: (json['reasoningDialect'] ?? 'auto').toString(),
        reasoningEffort: (json['reasoningEffort'] ?? 'high').toString(),
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.85,
        maxWords: ((json['maxWords'] as num?)?.toInt() ?? 800).clamp(200, 3000),
        enableBackgroundExtract: json['enableBackgroundExtract'] != false,
        enableAuxModel: json['enableAuxModel'] == true,
        auxApiProvider: (json['auxApiProvider'] ?? '').toString(),
        auxBaseUrl: (json['auxBaseUrl'] ?? '').toString(),
        auxWorkspaceId: (json['auxWorkspaceId'] ?? '').toString(),
        auxModelName: (json['auxModelName'] ?? '').toString(),
        savedProfiles: (json['savedProfiles'] as List<dynamic>?)
                ?.whereType<Map>()
                .map(
                  (e) => ModelProfile.fromJson(Map<String, dynamic>.from(e)),
                )
                .toList() ??
            <ModelProfile>[],
        activeProfileId: (json['activeProfileId'] ?? '').toString(),
        themeMode: (json['themeMode'] ?? 'mirage').toString(),
        fontSize: (json['fontSize'] ?? 'md').toString(),
        lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.9,
        paragraphIndent: (json['paragraphIndent'] as num?)?.toInt() ??
            (json['indentFirstLine'] == false ? 0 : 2),
        paragraphSpacing: (json['paragraphSpacing'] ?? 'normal').toString(),
        serifReading: json['serifReading'] == true,
        autoScrollToLatest: json['autoScrollToLatest'] != false,
        autoHideHeader: json['autoHideHeader'] == true,
        keepScreenOn: json['keepScreenOn'] != false,
        godMode: json['godMode'] == true,
        enableThinking: json['enableThinking'] != false,
        thinkingBudget: (json['thinkingBudget'] as num?)?.toInt() ?? 0,
        logEnabled: json['logEnabled'] == true,
        verboseLog: json['verboseLog'] == true,
      );

  AppConfig copyWith({
    String? apiProvider,
    String? baseUrl,
    String? workspaceId,
    String? modelName,
    String? reasoningDialect,
    String? reasoningEffort,
    double? temperature,
    int? maxWords,
    bool? enableBackgroundExtract,
    bool? enableAuxModel,
    String? auxApiProvider,
    String? auxBaseUrl,
    String? auxWorkspaceId,
    String? auxModelName,
    List<ModelProfile>? savedProfiles,
    String? activeProfileId,
    String? themeMode,
    String? fontSize,
    double? lineHeight,
    int? paragraphIndent,
    String? paragraphSpacing,
    bool? serifReading,
    bool? autoScrollToLatest,
    bool? autoHideHeader,
    bool? keepScreenOn,
    bool? godMode,
    bool? enableThinking,
    int? thinkingBudget,
    bool? logEnabled,
    bool? verboseLog,
  }) =>
      AppConfig(
        apiProvider: apiProvider ?? this.apiProvider,
        baseUrl: baseUrl ?? this.baseUrl,
        workspaceId: workspaceId ?? this.workspaceId,
        modelName: modelName ?? this.modelName,
        reasoningDialect: reasoningDialect ?? this.reasoningDialect,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
        temperature: temperature ?? this.temperature,
        maxWords: (maxWords ?? this.maxWords).clamp(200, 3000),
        enableBackgroundExtract:
            enableBackgroundExtract ?? this.enableBackgroundExtract,
        enableAuxModel: enableAuxModel ?? this.enableAuxModel,
        auxApiProvider: auxApiProvider ?? this.auxApiProvider,
        auxBaseUrl: auxBaseUrl ?? this.auxBaseUrl,
        auxWorkspaceId: auxWorkspaceId ?? this.auxWorkspaceId,
        auxModelName: auxModelName ?? this.auxModelName,
        savedProfiles: savedProfiles ?? List<ModelProfile>.from(this.savedProfiles),
        activeProfileId: activeProfileId ?? this.activeProfileId,
        themeMode: themeMode ?? this.themeMode,
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        paragraphIndent: paragraphIndent ?? this.paragraphIndent,
        paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
        serifReading: serifReading ?? this.serifReading,
        autoScrollToLatest: autoScrollToLatest ?? this.autoScrollToLatest,
        autoHideHeader: autoHideHeader ?? this.autoHideHeader,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        godMode: godMode ?? this.godMode,
        enableThinking: enableThinking ?? this.enableThinking,
        thinkingBudget: thinkingBudget ?? this.thinkingBudget,
        logEnabled: logEnabled ?? this.logEnabled,
        verboseLog: verboseLog ?? this.verboseLog,
      );

  String encode() => jsonEncode(toJson());
}
