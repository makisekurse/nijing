import 'dart:convert';

/// 全局配置。
///
/// ⚠️ `apiKey` **不参与 JSON 序列化** —— 它单独存进系统加密存储
/// （`flutter_secure_storage`），落盘的是密文而不是明文。
class AppConfig {
  /// 'bailian' | 'deepseek' | 'custom'
  String apiProvider;

  /// 自定义端点（provider 为 custom 时必填；其余留空走默认端点）
  String baseUrl;

  /// 默认用 flash —— 便宜、快，长局推演不容易烧额度。
  String modelName;

  double temperature;

  /// 单幕目标字数，提示词里会带上。
  int maxWords;

  /// 'mirage'（拟境，默认）| 'vintage' | 'dark' | 'parchment'
  String themeMode;

  /// 'sm' | 'md' | 'lg'
  String fontSize;

  double lineHeight;

  /// 段首缩进格数（0 / 1 / 2）。
  ///
  /// 以前是个布尔开关（首行缩进 开/关），但中文排版里"缩几格"才是真正
  /// 要调的参数，所以改成可选的格数。
  int paragraphIndent;

  /// 段间距：'tight' | 'normal' | 'loose'
  String paragraphSpacing;

  /// 打开推演时自动跳到最新一幕。
  ///
  /// 「继续进入」的语义就是**接着上次的进度往下**，
  /// 所以默认开 —— 否则从首页点进来会停在第一幕，得手动往下翻。
  bool autoScrollToLatest;

  /// 顶栏自动隐藏（零 HUD）
  bool autoHideHeader;

  /// 阅读防熄屏（保持屏幕常亮）
  bool keepScreenOn;

  /// 主宰模式（玩家最高权限 / 绝对意志）
  bool godMode;

  /// 模型深度思考模式（Thinking / Reasoning 模式）
  bool enableThinking;

  /// 运行日志（排障用）。默认关闭 —— 不开就是零开销。
  bool logEnabled;

  /// 详细日志：额外记录 SSE 原始行与模型原文片段，量很大。
  bool verboseLog;

  AppConfig({
    this.apiProvider = 'bailian',
    this.baseUrl = '',
    this.modelName = 'qwen3.8-flash',
    this.temperature = 0.85,
    int maxWords = 500,
    this.themeMode = 'mirage',
    this.fontSize = 'md',
    this.lineHeight = 1.9,
    this.paragraphIndent = 2,
    this.paragraphSpacing = 'normal',
    this.autoScrollToLatest = true,
    this.autoHideHeader = true,
    this.keepScreenOn = true,
    this.godMode = false,
    this.enableThinking = true,
    this.logEnabled = false,
    this.verboseLog = false,
  }) : maxWords = maxWords.clamp(200, 3000);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'apiProvider': apiProvider,
        'baseUrl': baseUrl,
        'modelName': modelName,
        'temperature': temperature,
        'maxWords': maxWords,
        'themeMode': themeMode,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'paragraphIndent': paragraphIndent,
        'paragraphSpacing': paragraphSpacing,
        'autoScrollToLatest': autoScrollToLatest,
        'autoHideHeader': autoHideHeader,
        'keepScreenOn': keepScreenOn,
        'godMode': godMode,
        'enableThinking': enableThinking,
        'logEnabled': logEnabled,
        'verboseLog': verboseLog,
      };

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        apiProvider: (json['apiProvider'] ?? 'bailian').toString(),
        baseUrl: (json['baseUrl'] ?? '').toString(),
        modelName: (json['modelName'] ?? 'qwen3.8-flash').toString(),
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.85,
        maxWords: ((json['maxWords'] as num?)?.toInt() ?? 500).clamp(200, 3000),
        themeMode: (json['themeMode'] ?? 'mirage').toString(),
        fontSize: (json['fontSize'] ?? 'md').toString(),
        lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 1.9,
        // 旧配置里是布尔 `indentFirstLine`：开 → 两格，关 → 顶格
        paragraphIndent: (json['paragraphIndent'] as num?)?.toInt() ??
            (json['indentFirstLine'] == false ? 0 : 2),
        paragraphSpacing: (json['paragraphSpacing'] ?? 'normal').toString(),
        autoScrollToLatest: json['autoScrollToLatest'] != false,
        autoHideHeader: json['autoHideHeader'] != false,
        keepScreenOn: json['keepScreenOn'] != false,
        godMode: json['godMode'] == true,
        enableThinking: json['enableThinking'] != false,
        logEnabled: json['logEnabled'] == true,
        verboseLog: json['verboseLog'] == true,
      );

  AppConfig copyWith({
    String? apiProvider,
    String? baseUrl,
    String? modelName,
    double? temperature,
    int? maxWords,
    String? themeMode,
    String? fontSize,
    double? lineHeight,
    int? paragraphIndent,
    String? paragraphSpacing,
    bool? autoScrollToLatest,
    bool? autoHideHeader,
    bool? keepScreenOn,
    bool? godMode,
    bool? enableThinking,
    bool? logEnabled,
    bool? verboseLog,
  }) =>
      AppConfig(
        apiProvider: apiProvider ?? this.apiProvider,
        baseUrl: baseUrl ?? this.baseUrl,
        modelName: modelName ?? this.modelName,
        temperature: temperature ?? this.temperature,
        maxWords: (maxWords ?? this.maxWords).clamp(200, 3000),
        themeMode: themeMode ?? this.themeMode,
        fontSize: fontSize ?? this.fontSize,
        lineHeight: lineHeight ?? this.lineHeight,
        paragraphIndent: paragraphIndent ?? this.paragraphIndent,
        paragraphSpacing: paragraphSpacing ?? this.paragraphSpacing,
        autoScrollToLatest: autoScrollToLatest ?? this.autoScrollToLatest,
        autoHideHeader: autoHideHeader ?? this.autoHideHeader,
        keepScreenOn: keepScreenOn ?? this.keepScreenOn,
        godMode: godMode ?? this.godMode,
        enableThinking: enableThinking ?? this.enableThinking,
        logEnabled: logEnabled ?? this.logEnabled,
        verboseLog: verboseLog ?? this.verboseLog,
      );

  String encode() => jsonEncode(toJson());
}
