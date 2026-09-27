# 拟境 · 全量技术交接与架构文档（2026-09-27 · v1.3.8）

> **更新时间**：2026-09-27  
> **开源仓库**：https://github.com/makisekurse/nijing （公开仓库）  
> **法定工作区路径**：`D:\Gemini\06_代码工程\nijing\`  
> **交接目标**：帮助接手的开发者/智能体全面掌握引擎架构、数据模型、核心不变量、历史踩坑经验与发版规范，无需摸索即可秒级定位、修改代码、运行单测并完成出包。

---

## 一、项目定位与基本信息

**拟境**（英文名 `nijing`，由 `history-sim` 演进而来）是一个**世界书驱动的沉浸式情境推演引擎**。

它不是数值游戏，没有血条、金币和等级面板；全屏呈现长篇小说的阅读质感，每一幕剧情由用户自配的 LLM 实时生成，文末给出可选行动分支，亦支持玩家输入任意自由行动。

- **应用零内置剧本**：时代背景、主角身份、关键人物、文风规则全部由外部「世界书」定义；
- **包名**：`io.github.makisekurse.nijing`
- **开发者署名**：`makisekurisu`（遵循用户严格要求，仅署此名）
- **当前版本**：`v1.3.8+1`
- **基线单测**：**172 项单元测试 100% 全绿（运行耗时 ~1 秒）**

---

## 二、架构全景与目录结构

```
lib/
├── main.dart                          # 应用入口：配置加载、主题注入、生命周期落盘兜底
├── core/
│   ├── app_info.dart                  # 应用常量（名称/构建期注入的版本/仓库地址）
│   └── app_error.dart                 # 错误分类体系（含 400 服务端错误明细透出）
├── models/
│   ├── world_book.dart                # 世界书元数据与核心设定（12 个核心维度）
│   ├── world_line.dart                # ★ 世界线模型：history + chronicle + worldState + 分岔关系
│   ├── save_slot.dart                 # ★ 存档槽：一本世界书 + 若干条世界线
│   ├── chapter_node.dart              # 单幕节点（内嵌每幕状态快照，用于分岔自愈）
│   ├── world_state.dart               # 结构化世界状态（时间、地点、事实、关系、事件）
│   ├── annotation.dart                # 词条 / 人物志 / 关系条目
│   └── app_config.dart                # 全局配置（字体/排版/主题/主宰模式/思考模式/单幕字数）
├── data/
│   ├── prefs_store.dart               # SharedPreferences 封装（离散即刻落盘 + 生命周期 flush）
│   ├── secure_store.dart              # API Key 系统安全加密存储
│   └── world_book_repository.dart     # 世界书持久化仓库
├── services/
│   ├── generation_controller.dart     # ★ 长生命周期推演控制器：按槽隔离状态机、流式缓冲、自动落盘
│   ├── game_session.dart              # ★ 纯业务状态机：分岔、切换、快照自愈、重卷、选项恢复
│   ├── world_state_service.dart       # ★ 状态解析、合并、字段校验、Prompt 渲染
│   ├── response_parser.dart           # ★ 模型输出五步流水线、未闭合 think 断崖探测、思维防外泄
│   ├── text_layout.dart               # 正文分段、排版清洗与缩进布局
│   ├── prompt_builder.dart            # 提示词三层装配（含天道敕令注入与单幕字数下限约束）
│   ├── llm_client.dart                # 流式 SSE 客户端（原生 reasoning 捕获、顶格 Token 预算分配）
│   ├── providers.dart                 # 模型商端点解析、模型名智能归一化自愈、思考模式判定
│   ├── fallback_service.dart          # 截断与异常三级兜底（restart 通知隔离、400 阻断防虚假章节）
│   ├── file_export_service.dart       # Android FileProvider 真实物理文件系统分享
│   ├── runtime_log.dart               # 运行日志（环形缓冲、内存批量淘汰、配置密钥绝对脱敏）
│   ├── chronicle_service.dart         # 编年史增量压缩
│   ├── save_service.dart              # 存档槽序列化与写盘
│   ├── world_builder_service.dart     # AI 扩写生成世界书
│   └── update_service.dart            # GitHub Release 自动检查更新
└── ui/
    ├── themes/app_theme.dart          # 四套经典皮肤 + ReadingPalette 沉浸阅读色板
    ├── screens/
    │   ├── home_shell.dart            # 首页底栏入口（世界 / 继续 / 我的）与槽位控制器清理
    │   ├── reader_screen.dart         # ★ 沉浸阅读主界面（视口停泊、手势冲突防互殴、控制器订阅）
    │   ├── worlds_tab.dart            # 世界书列表与管理
    │   ├── continue_tab.dart          # 继续推演聚合页
    │   ├── profile_tab.dart           # 个人与设置聚合
    │   ├── settings_screen.dart       # 开发者选项（3000 字上限、思考开关、运行日志）
    │   └── worldbook_editor_screen.dart # 世界书编辑器
    └── widgets/
        ├── live_thought_view.dart     # ★ 流式思考常驻面板（独立翻阅感知、展开状态托管）
        ├── world_line_tree.dart       # ★ 世界线时空树弹层（严格外框对齐、转角分支、防文本穿透）
        ├── choice_pill.dart           # 行动分支选择胶囊
        ├── free_input_bar.dart        # 自由行动输入框（金色主宰模式光标、草稿焦点防丢失）
        └── thought_sheet.dart         # 历史各幕思维链回溯弹层
```

---

## 三、七大核心架构与技术演进

### 1. 核心不变量：三位一体状态快照 (Snapshot Invariants)
> **铁律：`history` · `chronicle` · `worldState` 三者必须永远处于同一个时间点。**

- 实现载体：`ChapterNode` 上的 `chronicleAfter` 与 `worldStateAfter` 快照；
- 作用机制：分岔（`branchFrom`）、重新生成本幕（`reroll`）和编年史压缩时，绝不仅在存档顶层修改，必须严格基于那一幕的历史快照展开，确保回退或分岔时不会丢失前文局势或跨越时空污染；
- 快照自愈：`GameSession` 构造时自动调用 `ensureSnapshots()`，缺失快照自动沿用前一幕，开篇第一幕赋精准空状态，自愈仅发生于内存，等用户保存时静默回写。

### 2. 推演控制器生命周期解耦 (GenerationController)
- **旧痛点**：旧版推演强绑定于 `ReaderScreen`，退出页面时其 `dispose()` 会粗暴调用 `_client.cancel()` 掐断请求，导致正在生成的长篇故事前功尽弃；
- **新架构**：
  - 引入 `GenerationController`，按 `slotId` 单例持久化托管；
  - 拥有独立状态机（`idle` / `generating` / `streaming` / `completed` / `failed`）；
  - `ReaderScreen` 作为纯粹的观察者（Subscriber），进入时 `attach` 恢复当前流式现场与思考面板展开状态；离开时仅 `detach` 取消 UI 监听，后台依然继续生成；
  - 推演完成后，控制器在后台直接调用 `SaveService.upsert` 完成无感自动存档。

### 3. 深度思考模式 (Thinking / Reasoning Stream)
- **常驻展示**：废除正文出现即卸载思考面板的限制，推演中只要产生思考，`LiveThoughtView` 常驻正文上方；
- **原生分流**：`LlmClient` 实时监听阿里云百炼原生 `reasoning_content`，SSE chunk 不做破坏性正则清洗，通过 `ResponseParser.splitLive` 统一做 Markdown 规范化并严格保留段落空行；
- **未闭合 think 断崖探测**：针对部分模型偶尔缺失 `</think>` 标签的问题，构建了五层智能断崖防护（元思维引导词前缀排除、指令性短语排除、小说标准引号对话识别、自然叙事短句识别、思维词统计），确保小说正文绝不被误吞入思考面板。

### 4. 思考过程防泄露 (Thinking Leakage Guard)
- **问题**：旧版 `_looksLikeNarrativeBody` 误将思考中引用的玩家行动（如 `思考：主角决定：“……”，需要把这一事实融入`）因含有引号误切分为小说正文，造成上半截卡在思考框、下半截外泄污染正文；
- **重构**：`_looksLikeNarrativeBody` 设立严格守卫：
  1. 命中 `思考：`、`推演：`、`分析：` 等前缀一律禁止切出；
  2. 包含 `不要反转`、`需要把`、`决定：“`、`天道敕令` 等指令语言一律禁止切出；
  3. 只有以引号开头的标准角色小说对话、或不含任何元思维关键词的自然文学描写才判定为正文。

### 5. 双层滚动脱困与视口停泊 (Scroll Decoupling)
- **问题**：流式生成时外部页面强制跟随滚底，而思考面板内部也每字强制 `jumpTo`，导致用户手指在屏幕上翻看时被疯狂拽回底部；
- **脱困机制**：
  1. `LiveThoughtView` 增加内部 `_userScrolledUp` 状态：当检测到距离底端超过 28px 时，立即锁定自动滚动，把翻阅权完整归还给用户；划回底端自动恢复；
  2. `ReaderScreen` 将跟随阈值精简至 48px，并挂载 `Listener` 追踪原始触摸（`_activePointer`），**在用户手指按在屏幕上或向上翻阅期间，绝对禁止触发任何 `animateTo` 动画**；
  3. 视口向上停泊时，右下角优雅浮现「↓ 有新内容流出」气泡胶囊，点击平滑回滚至最新行。

### 6. 单幕 3000 字与顶格 Token 扩容 (16384 Token Budget)
- **单幕字数支持**：`AppConfig.maxWords` 开放 200..3000 字区间，提示词 `PromptKernel.build` 动态按 85% 注入强力字数下限约束（3000 字时约束 2550 字以上），彻底解决大模型草率收束；
- **Token 顶格预算**：在开启深度思考时，针对模型长篇思索动辄消耗 3000+ tokens 的特点，`calculateMaxTokens` 公式重构为 `math.max(12288, maxWords * 5).clamp(4096, 16384)`，默认赋予 **12288 ~ 16384 tokens** 的充裕空间，彻底根除百炼服务端因 Token 撞墙而掐断连接（`Connection closed while receiving data`）。

### 7. 运行日志与真实物理文件分享 (Export & Logging)
- **物理文件导出**：通过 Android FileProvider 原生通道，故事（.md / .txt）与运行日志（.txt）直接导出至公共存储并唤起系统分享面板，告别巨型纯文本粘贴导致的手机卡死；
- **双重精准脱敏**：`RuntimeLog` 既对标准前缀（`sk-`、Bearer 等）进行通用模糊，又与 `SecureStore` 绑定的真实 `configuredApiKey` 进行全值精准脱敏，保证导出日志绝对安全。

---

## 四、模型输出契约与标签体系

推演生成严格遵循结构化契约，正文之外的结构全部封装在标签内（用户阅读区只展示纯净正文）：

| 标签 | 内容 | 处理方式 |
|---|---|---|
| `<think>` | 思维链推理过程 | 实时剥离至 `LiveThoughtView`，不污染正文 |
| `<date>` | 故事当下剧中日期 | 提取并更新当前幕的展示日期 |
| `<choices>` | 2~3 个可选行动 | 渲染为底部的选项卡，支持重卷与恢复 |
| `<glossary>` | 词条\|释义 | 增量合并入词条字典，点选可看释义 |
| `<cast>` | 姓名\|身份\|立场 | 增量合并入人物志 |
| `<state>` | 时间、地点、事实、关系、事件 | 结构化合并更新为下一幕的 `worldState` |

---

## 五、工程铁律与踩坑经验（★ 必读准则）

### 铁律 1：真实报文证据先行，严禁盲猜打补丁 (Evidence-First Debugging)
- **百炼 400 惨痛教训**：前期在排查百炼报 400 时，盲目猜测是“参数冲突”、“模型名变体”或“max_tokens 越界”，打了一堆防御补丁却未触及真实原因。直到用户拿出真机运行日志，上面清晰记载：`HTTP 400 · {"error":{"message":"Workspace endpoint is invalid."}}`，才瞬间找到真凶；
- **准则**：遇到任何 API 报错、网络异常或系统故障，**必须以服务端返回的真实响应体（Response Body）、实际拼装的完整请求 URL/Query/Headers 及真实日志为第一事实依据**。信息不足时第一动作是打印/透出错误报文，严禁在未见真实报错前凭空瞎猜。

### 铁律 2：跨层参数语义严格隔离，严禁李代桃僵 (Semantic Parameter Isolation)
- **教训**：在调用层误将本地存档槽位 `slotId: "hmm680l2yg"` 偷换概念传给了百炼的 `workspaceId: slotId`，导致 Base URL 被篡改为专属租户域名 `https://hmm680l2yg.cn-beijing.maas.aliyuncs.com/...`，直接被网关拦截；
- **准则**：严禁将业务层内部 ID 随意代入底层协议参数；非百炼专属企业工作空间场景，`workspaceId` 必须显式留空。

### 铁律 3：双层滚动与高频流式的触摸抑制
- 在有流式输出和自动滚底的界面中，一旦用户手指按在屏幕上（`_activePointer != null`）或有主动向上划动倾向，**必须无条件暂停一切程序化的自动滚动动画**，绝不能与用户手势在同一帧内互殴。

### 铁律 4：段首缩进必须用 WidgetSpan，绝不能用空白字符
- 中文字符 `\u3000` 在 Flutter 两端对齐排版时会被文本 Shaper 当作挂起空白折叠吃掉；必须使用 `WidgetSpan(child: SizedBox(width: n * fontSize))` 实体盒子实现物理占位。

### 铁律 5：Windows 上时间戳分辨率不足会撞 ID
- `DateTime.now()` 在 Windows 上精度仅约 1ms，高频分岔时会生成相同 ID 导致状态串线；所有新 ID 必须拼接进程级自增序号（`newId()`）。

---

## 六、开发、测试与出包指南

### 1. 运行测试
统一采用现代化 PowerShell 7+ (`pwsh`) 执行测试：
```powershell
flutter test test/nijing_test.dart
```
> **全绿指标**：164/164 项测试秒级通过，新增任何特性必须编写单测，确保 0 回归。

### 2. 本地构建 Release APK
```powershell
flutter build apk --release --target-platform android-arm64
```
产物位于 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`（约 19.1 MB）。

### 3. GitHub Actions 自动发版
仓库通过 `.github/workflows/android.yml` 自动化出包：
1. 更新 `pubspec.yaml` 版本号（如 `1.3.8+1`）；
2. 更新 `README.md` 与本文档；
3. 提交并推送到 GitHub 主干：
   ```powershell
   git add .
   git commit -m "feat: 你的改动说明 (v1.3.8)"
   git push origin main
   ```
4. 打标签并推送触发发版：
   ```powershell
   git tag -a v1.3.8 -m "v1.3.8 详细改动"
   git push origin v1.3.8
   ```
5. GitHub Actions 自动构建并在 Releases 页面生成对应的发布产物。

---

## 七、关键代码文件索引

| 模块 | 核心文件 | 关键职责 |
|---|---|---|
| **推演控制** | `lib/services/generation_controller.dart` | 独立生命周期控制器、状态机、后台落盘、残文抢救 |
| **状态演算** | `lib/services/game_session.dart` | 分岔逻辑、世界线切换、快照自愈、重卷、选项恢复 |
| **输出解析** | `lib/services/response_parser.dart` | 结构化标签提取、未闭合 think 零泄漏与智能截断、思维防外泄 |
| **网络调用** | `lib/services/llm_client.dart` | SSE 头部补全、心跳检测（20s 超时）、浮点清洗、thinking_budget 透传 |
| **模型调度** | `lib/services/providers.dart` | 服务商 Base URL 解析、模型名智能自愈、参数隔离 |
| **阅读界面** | `lib/ui/screens/reader_screen.dart` | 沉浸阅读视口、触摸手势防打架、视口停泊 |
| **思考面板** | `lib/ui/widgets/live_thought_view.dart` | 常驻思考展示、折叠保持、独立划动感知 |
| **世界线树** | `lib/ui/widgets/world_line_tree.dart` | 时空树可视化、卡片严密对齐、文本防溢出 |
| **单测套件** | `test/nijing_test.dart` | 172 项全量测试集 |
