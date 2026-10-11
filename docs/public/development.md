# 开发与测试

最低系统为 macOS 14，发布架构为 ARM64。使用 Swift 6 / Xcode 16 或更新工具链，Swift 语言模式为5。

## 结构

- `HuantaiCore`：会话索引、增量扫描、账户额度、原生链接、状态持久化及导航。
- `HuantaiApp`：AppKit 菜单栏与浮窗，SwiftUI 列表、设置和 Toast。
- `HuantaiWeb`：仅监听本机的 HTTP 服务与详情界面。
- `ht`：共享 Core 的命令行入口。

不依赖第三方 Swift 包。SQLite 通过系统模块链接，App 使用系统的 AppKit、SwiftUI、Carbon 和 ServiceManagement。

DeepSeek Harness 的 Zstandard 记录通过已有 Node.js 24+ 的内置解码器、本机官方桌面客户端的 Electron 运行时或已安装的 zstd 只读解压，不启动 Harness 服务，也不触发会话迁移。普通 JSONL 不需要解码运行时；压缩解码缺失或失败会显示具体来源不可读状态。

可选任务 Hook 由 `TaskHookManager` 管理：默认关闭，实际安装范围为音效总开关与 `StoreConfiguration` 中启用来源的交集。来源更新先同步 Hook，再刷新索引，索引读取失败不会阻止停用 Hook；忙碌期间的来源更新串行执行，不丢弃。Codex 按命令精确合并/移除 `UserPromptSubmit`、`Stop`、`Interrupt`，保留其他配置；回调只提交转录路径，不保存提示或回复。独立 `CodexTaskMonitor` 增量监听生命周期，避免历史补播与同轮重复提醒。当前 Codex 0.160.1 的失败任务会持久化为带 `error` 的 `task_complete`，必须检查该字段；不能只按事件名播放完成音效，也不能用工具非零退出或手动中断冒充任务失败。

DeepSeek Harness 使用官方 `session/event` 的 `turn/start`、`turn/end`，通过机器级 `cordis.patch.yml` 插入随 App 分发的 `HuantaiDSHHook.mjs`，支持共享该数据目录的 CLI / 桌面 profiles。插件只写状态、会话/轮次标识、来源目录与时间戳，不读取或保存正文。`completed` 对应完成，`error` / `blocked` / `max-tokens` 对应失败，`aborted` / `interrupted` 静默；子 agent 不单独提醒。启动与重新勾选不补播旧信号，短任务按时间排序，终态去重。移除标记块时保留其他 patch 原文，现有 YAML 用官方运行时的 `!!js` 方言校验，损坏配置不覆盖。来源取消先持久化 gate，已加载的插件与该来源排队音效也立即停用；其他来源保留扫描偏移和播放队列，不丢失进行中任务的终态。清理失败保留路径以重试。

默认音频随 App 放入 `Contents/Resources/CodexSounds`，本地构建与 ARM64 发布脚本均包含这份资源。用户音效在状态目录的 `codex-hooks/sounds` 中平铺为 `started.mp3`、`completed.wav`、`failed.wav`；首次准备后不补回已删除音频，播放前重新解析文件。早期子目录自动迁移，同名自定义文件优先，旧音频另存为 previous 文件。三段来源与上游许可声明随 README 保留。

## 本地构建

```bash
./scripts/build.sh
./scripts/run-demo.sh
./bin/ht --help
```

本地构建产物位于 `build/换台.app`，开发状态在 `.local/state/`；二者均被 Git 忽略。`run-demo.sh` 默认读取真实本机数据，名称不代表启用了演示数据。

## 检查

```bash
./scripts/test.sh
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
bash -n scripts/*.sh bin/ht
```

测试创建独立的合成数据库、JSONL 和偏好域，不需要真实账户或网络。增量扫描测试检查未变化日志的零读取与追加字节边界，不使用机器相关的性能阈值。原生布局检查常规/小视口中的单一滚动区域、固定尺寸和可达末端；状态测试将登录项的系统服务注入，避免注册测试污染系统设置。

合成原生交互检查：

```bash
python3 scripts/make-ui-fixture.py .local/ui-fixture
HUANTAI_TEST_MODE=1 \
HUANTAI_CODEX_HOME="$PWD/.local/ui-fixture/codex" \
HUANTAI_BOTMUX_HOME="$PWD/.local/ui-fixture/botmux" \
HUANTAI_DSH_HOME="$PWD/.local/ui-fixture/dsh" \
HUANTAI_HOME="$PWD/.local/ui-fixture/state" \
./scripts/run-demo.sh --review
```

目标目录必须不存在，脚本不会覆盖已有数据。测试模式禁止真实账户刷新，不保存或复用生产启动目录配置。`--review` 使用与菜单栏浮窗相同的生产组件。

测试模式未明确提供 DeepSeek Harness 目录时采用隔离空目录，避免展示真实会话。

## 数据处理

默认读取 Codex 的 `state_5.sqlite` 元数据及允许目录下的 JSONL。SQLite 只读打开；日志只提取可见 AI 回复时间与最多320字符的最后回复短预览，不保存完整对话。过滤用户、分析和工具内容，软链接不能越过允许路径。

收藏和完成状态保存在换台自己的状态文件中，不删除或归档来源会话。缓存使用文件标识、大小、修改时间和解析版本失效；完整行后的游标支持追加读取，截断或替换回退全量扫描。

额度通过已登录 `codex app-server` 的最小只读请求获取，不读取认证文件、不发起登录、不授予新权限。失败可以保留上次摘要，但须明确标记其状态。

## 公开内容

源码、合成测试、开发/发布脚本及 `docs/public/` 属于公开项目。运行状态、数据库、日志、签名凭据、历史审阅文档和设计记录保留本地，不进入 Git 提交或发布包。公开提交使用 GitHub 的 noreply 地址。

## 远端与单会话 Token

`RemoteCodexReader` 以参数数组启动系统 SSH，将路径作为 Base64 JSON 传入固定 Python 只读程序；不把目录拼入 shell 命令。`RemoteCodexScanner` 合并并发读取、限制同步频率、保留断线缓存，网络请求在 Store 文件锁外执行。远端身份由主机和数据目录的 SHA-256 加原始线程 ID 组成，与显示名称、本机会话隔离。

远端与本机读取遵守相同目录边界：拒绝符号链接索引；日志解析后的真实路径必须仍在配置根目录的 `sessions` 或 `archived_sessions` 下，目录符号链接不能扩大读取范围。

`SessionTokenUsageScanner` 与远端 Python 提取器复用 Codo 的统计语义：最新累计采样、压缩后上下文失效、未知不补零、最多 8 MiB 尾部扫描。测试通过合成 SQLite / JSONL 验证两端一致、目录逃逸、重命名标题、断线缓存及配置隔离，不依赖真实主机或账户。
