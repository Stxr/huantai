# 开发与测试

最低系统为 macOS 14，发布架构为 ARM64。使用 Swift 6 / Xcode 16 或更新工具链，Swift 语言模式为5。

## 结构

- `HuantaiCore`：会话索引、增量扫描、账户额度、原生链接、状态持久化及导航。
- `HuantaiApp`：AppKit 菜单栏与浮窗，SwiftUI 列表、设置和 Toast。
- `HuantaiWeb`：仅监听本机的 HTTP 服务与详情界面。
- `ht`：共享 Core 的命令行入口。

不依赖第三方 Swift 包。SQLite 通过系统模块链接，App 使用系统的 AppKit、SwiftUI、Carbon 和 ServiceManagement。

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
HUANTAI_HOME="$PWD/.local/ui-fixture/state" \
./scripts/run-demo.sh --review
```

目标目录必须不存在，脚本不会覆盖已有数据。测试模式禁止真实账户刷新，不保存或复用生产启动目录配置。`--review` 使用与菜单栏浮窗相同的生产组件。

## 数据处理

默认读取 Codex 的 `state_5.sqlite` 元数据及允许目录下的 JSONL。SQLite 只读打开；日志只提取可见 AI 回复时间与最多320字符的最后回复短预览，不保存完整对话。过滤用户、分析和工具内容，软链接不能越过允许路径。

收藏和完成状态保存在换台自己的状态文件中，不删除或归档来源会话。缓存使用文件标识、大小、修改时间和解析版本失效；完整行后的游标支持追加读取，截断或替换回退全量扫描。

额度通过已登录 `codex app-server` 的最小只读请求获取，不读取认证文件、不发起登录、不授予新权限。失败可以保留上次摘要，但须明确标记其状态。

## 公开内容

源码、合成测试、开发/发布脚本及 `docs/public/` 属于公开项目。运行状态、数据库、日志、签名凭据、历史审阅文档和设计记录保留本地，不进入 Git 提交或发布包。公开提交使用 GitHub 的 noreply 地址。
