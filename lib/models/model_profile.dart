/// 保存的模型配置档案（对标 Cherry Studio / Kelivo 多配置一键切换）。
///
/// 敏感 API Key 本身不落明文 JSON；可关联独立加密 Key 槽位或复用全局主 Key。
class ModelProfile {
  final String id;
  final String name;
  final String apiProvider;
  final String baseUrl;
  final String workspaceId;
  final String modelName;
  final String reasoningDialect;
  final bool enableThinking;
  final int thinkingBudget;
  final String reasoningEffort;

  const ModelProfile({
    required this.id,
    required this.name,
    required this.apiProvider,
    this.baseUrl = '',
    this.workspaceId = '',
    required this.modelName,
    this.reasoningDialect = 'auto',
    this.enableThinking = true,
    this.thinkingBudget = 0,
    this.reasoningEffort = 'high',
  });

  static String newId() =>
      'prof_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'apiProvider': apiProvider,
        'baseUrl': baseUrl,
        'workspaceId': workspaceId,
        'modelName': modelName,
        'reasoningDialect': reasoningDialect,
        'enableThinking': enableThinking,
        'thinkingBudget': thinkingBudget,
        'reasoningEffort': reasoningEffort,
      };

  factory ModelProfile.fromJson(Map<String, dynamic> json) => ModelProfile(
        id: (json['id'] ?? '').toString().isNotEmpty
            ? json['id'].toString()
            : newId(),
        name: (json['name'] ?? '未命名配置').toString(),
        apiProvider: (json['apiProvider'] ?? 'bailian').toString(),
        baseUrl: (json['baseUrl'] ?? '').toString(),
        workspaceId: (json['workspaceId'] ?? '').toString(),
        modelName: (json['modelName'] ?? '').toString(),
        reasoningDialect: (json['reasoningDialect'] ?? 'auto').toString(),
        enableThinking: json['enableThinking'] != false,
        thinkingBudget: (json['thinkingBudget'] as num?)?.toInt() ?? 0,
        reasoningEffort: (json['reasoningEffort'] ?? 'high').toString(),
      );

  ModelProfile copyWith({
    String? name,
    String? apiProvider,
    String? baseUrl,
    String? workspaceId,
    String? modelName,
    String? reasoningDialect,
    bool? enableThinking,
    int? thinkingBudget,
    String? reasoningEffort,
  }) =>
      ModelProfile(
        id: id,
        name: name ?? this.name,
        apiProvider: apiProvider ?? this.apiProvider,
        baseUrl: baseUrl ?? this.baseUrl,
        workspaceId: workspaceId ?? this.workspaceId,
        modelName: modelName ?? this.modelName,
        reasoningDialect: reasoningDialect ?? this.reasoningDialect,
        enableThinking: enableThinking ?? this.enableThinking,
        thinkingBudget: thinkingBudget ?? this.thinkingBudget,
        reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      );
}
