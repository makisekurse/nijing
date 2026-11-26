# 拟境 · nijing

> 世界书驱动的沉浸式情境推演引擎（v2.0 全面换代）

把自己放进一个世界，做一个行动，看这个世界如何回应。

不是数值游戏 —— 没有血条、金币和属性面板。屏幕上是出版物级别的长篇小说阅读质感，
每一幕由你自己配置的大模型实时推演，结尾给出可选决断，也可以在底部输入舱随时写下你自己的意志。

**应用自带示例世界书体验入口，真正决定时代、人物与文风的始终是你自己的「世界书」。**
历史正剧、架空江湖、近未来都市 —— 同一套引擎，换一本书就是另一个世界。

---

## 下载

最新安装包在 [Releases](https://github.com/makisekurse/nijing/releases/latest) 页面，
选 `nijing-*-arm64.apk` 下载后直接安装（仓库公开，无需登录）。

- 仅支持 **arm64-v8a**（2018 年以后的手机都是）
- 签名固定，新版本可直接覆盖安装旧版本

---

## v2.0 核心特性

| 特性 | 说明 |
|---|---|
| **`forui` 文学纸墨界面** | 基于 `forui` 触控组件骨架 + HCT 五级容器明度阶梯 + `lucide_icons_flutter` 打造，彻底告别原生裸框质感；书架自动绘制程序化出版物书封 |
| **零清屏流式与原地续写** | 死守 `if (yielded) rethrow` 铁律：仅在首帧到达前自动重连，一旦吐出正文绝不抹屏重跑；断流或暂停时原地保留全部文字，支持一键「继续生成」「直接落幕」或「重试」，彻底根除「写一半重头来」与台词误杀 |
| **主辅双模型后台档案官** | 主模型卸载 `<state>` / `<cast>` / `<glossary>` 维护负担、专注沉浸小说写作；辅助模型（如 `qwen3.8-flash` / `deepseek-flash`）于后台静默增量抽取世界状态、人物与词条并标注变更徽标，省钱提速零阻塞 |
| **2026 模型与方言引擎** | 全面跟进 2026 主流模型（`qwen4-max` / `qwen3.8-max` / `qwen3.8-flash`、`deepseek-flash`（对应 V4.1-Flash 官方路由 ID）/ `deepseek-v4-pro` 等），内置 `GET /models` 在线检索拉取与统一推理方言适配（百炼 `enable_thinking` + 预算、DeepSeek V4 `thinking.type` + `reasoning_effort`、OpenAI `reasoning_effort`） |
| **多服务商分槽加密存储** | 按 `providerId` / `profileId` / `aux_model` 分槽加密保存 API Key（兼容迁移旧默认 Key），跨厂商主辅混搭与多档案一键热切换绝不串 Key |
| **现代阅读器与排版浮层** | 固定现代顶底栏不闪烁，`SuperSliverList` 零估算精准跳幕；内置页内实时排版浮层（字号 / 行距 / 缩进 / 书卷衬线 / 四套皮肤即点即变）、文学富文本（电报引用块 `>`、加粗/斜体不露裸星号）与呼吸感思考胶囊 |
| **单抽屉全景收纳** | 阅读页右侧统一抽屉聚合「此刻状态 · 全书目录 · 世界线分岔树 · 导出工具」，彻底告别堆叠弹窗 |
| **本地文件导入与状态收口** | 支持原生系统文件选择器直接导入 `.json` / `.txt` / `.md` 世界书，也可一键导入内置示例《决胜西南1949》开局；全应用由 `ConfigProvider` / `LibraryProvider` 清晰管理状态 |
| **世界线时空分岔树** | 从任意历史幕分岔出全新世界线重新抉择，原世界线完整保留、随时切换、重命名或删除，各线状态与编年史严格时间点隔离 |
| **主宰模式** | 全局或自由输入舱单次开启最高权限（金色高亮），将玩家意志作为不可撼动的既成事实写入剧情与世界状态，严禁强行反转 |
| **分槽原子存档与导出** | 每局推演独立保存为 `slot_<id>.json`（`.tmp` 原子替换防损坏），坏档隔离不连坐；支持故事 `.md`/`.txt`、世界书、存档与脱敏日志原生分享 |
| **一切只在本机** | 世界书、存档与分槽 API Key 全留本地；Key 走系统加密存储，运行日志默认关闭并执行全池多密钥自动脱敏 |

---

## 主题与排版

四套皮肤均采用「低饱和、书卷纸墨」HCT 容器阶梯设计 —— 换一本书不用换皮肤：

| 名称 | 定位 |
|---|---|
| **拟境**（默认） | 冷调深墨 + 雾蓝微光，长时间沉浸阅读不累眼 |
| **纸墨** | 象牙暖纸 + 暖炭墨 + 赤陶书卷，杂志印刷质感 |
| **墨石** | 橄榄暖炭黑 + 暖象牙墨 + 琥珀柔光，夜间护眼 |
| **宣纸** | 温润宣白 + 古墨 + 赭石褐，典雅白描 |

在阅读页右上角点 **Aa** 即可呼出实时排版浮层，无需离开正文即可调节字号、行距、段首缩进、书卷衬线开关与四套主题皮肤。

---

## 快速开始

1. 装好 App，首次打开会引导配置模型接口（也可先跳过直接浏览）
2. 进入「我的 → 模型与接口」，选择服务商并填入 API Key（各服务商独立加密保存，互不覆盖），点击「拉取模型」或手动选用模型并「测试连接」
   - **阿里云百炼**：默认 `qwen4-max`，快捷支持 `qwen3.8-max` / `qwen3.8-flash` / `qwen3.5-plus` / `qwen-plus` / `qwen-turbo`，支持思考预算与华北 2 业务空间 ID
   - **DeepSeek 官方**：支持 `deepseek-flash`（对应 V4.1-Flash 稳定路由 ID）与 `deepseek-v4-pro`（自动适配 V4 `thinking.type` 与 `reasoning_effort`）
   - **自定义 OpenAI 兼容**：填完整 Base URL（如 `https://api.example.com/v1`），支持 `GET /models` 在线拉取与多套「模型档案」保存切换
   - **主辅双模型（推荐）**：可在「后台档案与辅模型」折叠区绑定任意厂商的轻量高速模型（如 `qwen3.8-flash` / `deepseek-flash`）负责状态与编年史抽取，主模型专注写故事
3. 「**世界**」标签 → 一键导入示例《决胜西南1949》、选择本地 `.json`/`.txt` 文件、或由 AI 一句话扩写创建世界
4. 「**继续**」标签 → 进入正在推演的书卷，随时切换多条世界线或继续阅读

---

## 自己构建与 CI

```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```

> ⚠️ 必须显式指定 `--target-platform android-arm64`，避免 Gradle 将多套 ABI 一并打入包内导致体积翻倍。

GitHub Actions（`.github/workflows/android.yml`）分两级流水线：

| 触发方式 | 行为 |
|---|---|
| 推 `main` / 手动触发 | 执行静态分析、全量单元测试、编译 arm64 APK 并上传 Artifact |
| 推 `v*` 标签 | 全量验证与编译，并自动发布 GitHub Release 附带固定签名 APK |

---

## 测试

```bash
flutter analyze
flutter test
```

当前共 **204 项自动化单元测试与组件测试**（[`test/nijing_test.dart`](test/nijing_test.dart) + [`test/rescue_architecture_test.dart`](test/rescue_architecture_test.dart) + [`test/v2_architecture_test.dart`](test/v2_architecture_test.dart)），秒级全绿，覆盖：

- **零清屏流式与原地续写**：首帧前退避重试、已吐正文断流发 `interrupted` 绝不清屏、`continueGeneration()` 无缝续写、`commitInterruptedAsChapter()` 直接落幕、角色台词零误杀
- **2026 模型与方言引擎**：百炼 `enable_thinking` + 预算、DeepSeek V4 `thinking.type` + `reasoning_effort`、OpenAI `reasoning_effort`、远端 `/models` 多格式解析与旧模型退役检测
- **多服务商分槽加密存储**：百炼 / DeepSeek / 自定义 / 档案 / 辅模型槽位严格隔离、旧版单 Key 向后兼容、运行日志全池多密钥自动脱敏
- **主辅双模型后台抽取与编年史**：`SceneExtractorService` 容错 JSON 解析与变更摘要、`GameSession` 快照一致性、CAS 防串写保护与非阻塞增量编年史
- **原生双轨流与原子存档**：跨帧 `<think>` 零泄漏、`slot_<id>.json` 原子写入与坏档隔离、旧存档无缝迁移
- **文学富文本与 `forui` UI 组件**：行内加粗/斜体不露裸星号、`>` 引用块、HCT 五级容器、`ThinkingCapsule` / `ReaderComposer` / `WorldBookCover` / `ReaderScreen` 视口停泊组件渲染测试

---

## 架构

```text
lib/
├── core/        应用常量 · 统一错误分类（AppError）
├── models/      世界书 · 世界线 · 幕节点 · 世界状态 · 模型档案 · 存档槽 · 配置
├── data/        本地防抖存储 · 多槽加密存储（SecureStore）· 世界书仓库
├── state/       ConfigProvider（配置/多档案/多槽 Key）· LibraryProvider（世界书/存档）
├── services/    双轨流式客户端（LlmClient）· 推理方言引擎（ReasoningDialectResolver）
│                厂商预设与远端拉取（Providers）· 双轨解析（ResponseParser）
│                轻解耦提示词内核 · 零清屏兜底与续写（FallbackService）
│                后台档案官（SceneExtractorService）· 增量编年史 · 推演控制器
│                分槽原子存档（SaveService）· 会话状态机（GameSession）· 导出与日志
└── ui/
    ├── themes/  forui FThemeData · Claude 纸墨四套皮肤 · HCT 五级 SurfaceLadder
    ├── screens/ 引导页 · 主壳 · 继续 / 世界 / 我的 · 现代阅读器 · 编辑器 · 设置
    └── widgets/ 书封 · 文学段落 · 思考胶囊 · 章节卡片 · 贴底交互舱 · 排版浮层 · 统一抽屉
```

---

## 隐私与许可

- 世界书、分槽存档与加密 API Key 全部只保存在设备本地，应用无任何中转服务器
- 个人项目，未附许可协议。如需使用请先联系作者

**开发者**：[makisekurisu](https://github.com/makisekurse)
