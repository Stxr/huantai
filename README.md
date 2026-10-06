# 换台 · Huantai

macOS 菜单栏会话管理工具，提供 Swift 原生 App、`ht` CLI 和本机 Web 详情页，帮助你在 Codex 和 Botmux 会话之间切换。

支持 **Apple Silicon（ARM64）、macOS 14 及以上**。

## 下载与运行

从 [GitHub Releases](https://github.com/Stxr/huantai/releases) 下载 macOS ARM64 安装包，打开 DMG，将「换台.app」拖入 Applications 后运行。App 常驻菜单栏，点击额度圆环打开会话列表。

命令行工具单独提供 ARM64 压缩包，解压后运行 `ht --help`。本版使用临时签名，尚未进行 Apple Developer ID 签名和公证。

会话读取需要本机 Codex 数据；额度读取需要已安装且已登录的 `codex` CLI。Botmux 关联和飞书跳转需要对应的本机数据与客户端。未连接的来源会显示具体状态，不生成演示数据冒充真实数据。

## 功能

- 按 AI 最后可见回复时间排序，支持搜索、收藏、完成状态和原生会话跳转。
- 菜单栏可选择每日建议剩余圆环、每周剩余圆环或原 Logo。数字保留系统文字色，每日比例允许超过100%；圆环超过100%为蓝、10%至100%为绿、低于10%为红。
- 周额度圆环标示当日建议位置，并用红色表示超过当日参考的消耗；浮窗展示周重置时间及可用重置卡期限。
- 设置包含登录启动、系统/浅色/深色主题、菜单栏图标和可自定义的全局快捷键，使用一个连续滚动页面。
- 会话切换后显示不抢焦点的 Toast；15秒内可通过完成快捷键标记完成并切换下一项。
- `ht` 与 App 共享收藏、完成状态和索引；Web 详情随 App 运行，只监听 `127.0.0.1:18784`。

| 默认快捷键 | 动作 |
| --- | --- |
| `⌘⌥,` | 打开 / 关闭浮窗 |
| `⌘⇧↑` / `⌘⇧↓` | 上一个 / 下一个会话 |
| `⌘⇧\` | 第一个会话 |
| `⌘⇧←` / `⌘⇧→` | 打开历史的后退 / 前进 |
| `⌘⇧D` | 最近成功打开会话后的15秒内，完成并切换下一项 |

点击标题打开来源；收藏与鼠标完成按钮只修改状态。默认隐藏已完成会话，可通过状态筛选查看和恢复。

## 数据与额度口径

会话扫描每5秒执行，额度每5分钟更新。读取本机 Codex 元数据及最后一条可见 AI 回复的短预览，预览最多320字符；不读取认证文件，不保存完整对话。未变化日志复用缓存，追加日志增量读取。

额度接口提供百分比，不提供绝对 Token 数。每日建议是按照周窗口和自然日计算的参考节奏，支持未用额度结转；它不是官方日限额或当日实测消耗。

默认状态目录为 `~/Library/Application Support/huantai`，可通过 `HUANTAI_HOME` 覆盖。开发启动脚本使用工程 `.local/state/`，`bin/ht` 与它共享目录；App 会记住明确指定的目录，以便登录启动继续使用同一份状态。

## 从源码构建

需要 macOS ARM64、Swift 6 / Xcode 16 或更新工具链。没有第三方 Swift 包依赖，SQLite 使用系统库。

```bash
./scripts/build.sh
./scripts/run-demo.sh
./bin/ht list
```

```bash
./scripts/test.sh
xcrun swift-format lint --strict --recursive Package.swift Sources Tests
./scripts/release.sh v0.1.0
```

发布脚本只构建 ARM64，输出 App 安装包、CLI 压缩包和 SHA-256 校验文件到 `dist/`。本地数据、构建缓存、运行日志及内部审阅记录不进入仓库或发布包。

- [使用说明](docs/public/usage.md)
- [开发与测试](docs/public/development.md)
- [发布流程](docs/public/releasing.md)

本仓库暂未添加开源许可证。
