# 使用换台

## 会话列表

启动后点击菜单栏图标打开浮窗，点击标题在已安装的 Codex 或飞书客户端中打开对应会话；DeepSeek Harness 会话直接唤起官方应用。搜索支持标题和目录；星标筛选收藏项，完成状态筛选查看已完成项。收藏和鼠标完成不会自动打开下一会话。

默认同时读取 Codex 与 [官方 DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness/blob/master/README.zh.md)。设置 → 连接与数据可分别开关来源、选择数据主目录或恢复默认目录。Codex 默认 `~/.codex`，DeepSeek Harness 默认 `~/.dsh`；配置保存后立即刷新，重启继续沿用。关闭来源不会清除收藏或完成状态；更换目录不会继承旧目录的缓存记录。

DeepSeek Harness 从 `sessions/<项目>/<会话>/session[.vN].jsonl[.zstd]` 读取标题、目录及真实可见 AI 回复，按回复事件的毫秒时间排序，与 Codex 共用列表、收藏和完成状态。压缩读取可使用 Node.js 24+、本机官方桌面客户端的运行时或已安装的 zstd。当前核验的格式为 v0 至 v4，未知代际和不可读记录会提示，不以旧代际冒充当前记录。打开或切换 DeepSeek Harness 会话时，换台直接唤起官方应用；撤回完成也会返回应用。具体会话需在应用内选择，Toast 显示“已打开 DeepSeek Harness”。应用打开成功后可以使用15秒内的完成快捷键，完成/撤回针对换台中选中的会话记录。

列表按最后一条可见 AI 回复倒序，包含进度与最终回复。没有可见回复的会话排在末尾；文件修改时间、用户输入或任务派发不代替 AI 回复时间。

会话通过换台成功打开后的15秒内，`⌘⇧D` 标记当前项完成并打开下一条。屏幕角落的 Toast 展示本次跳转；失效或来源打开失败时不建立新的完成窗口。快捷键可在设置中修改、关闭或恢复默认。

`⌘⇧Z` 撤回本次运行中最近一次由原生快捷键或鼠标完成的会话，将其恢复为未完成并返回该会话；连续按可依次撤回，不受15秒限制，当前搜索或收藏筛选不会阻止返回。撤回记录仅在本次运行中保留，重启后清空；CLI/Web 的完成动作不加入原生撤回记录。

## 远端 Codex 与会话用量

设置 → 连接与数据 → 远端 Codex 中填写名称、SSH 主机（配置别名或 `user@host`）和远端 Codex 数据目录，然后添加。已有目标支持编辑和移除；`~/.codex` 中的 `~` 在远端展开，也可以填写绝对路径。远端配置不依赖本机 Codex 开关或数据目录，不会自动发现主机。

连接使用系统 SSH 配置，需预先完成主机指纹确认并能免交互登录；远端需安装 Python 3。App 每 30 秒后台只读同步，单次读取最多等待 20 秒，不阻塞本机会话刷新。断线时保留上次缓存并显示状态；移除目标后，其会话从列表移除。相同会话 ID 在不同主机或数据目录中独立保存收藏、完成状态。

远端 Botmux 会话读取远端 Botmux 数据目录（默认 `~/.botmux/data`，可在同一设置中修改），通过 `cliSessionId` 关联并标记为 Botmux。点击标题按聊天/话题元数据打开飞书；兼容 SQLite 会话库及旧 JSON 存储，同一存储优先 SQLite。缺少有效 ID 或关联多个不同目标时提示配置来源链接，不从标题猜测，也不把缺失话题链接降级为群聊。

其他远端会话默认不生成本机 Codex 跳转链接；请在 Codex 对应主机中打开，或登录远端执行 `codex resume <原始会话 ID>`。也可右键设置已核验的来源链接。

本机和远端 Codex 会话显示累计 Token 与上下文/窗口，沿用 Codo 的统计口径：取最新 `token_count` 的 `total_token_usage.total_tokens`，不累加历史采样；上下文取 `last_token_usage.input_tokens`，包含缓存输入。占用达到 65% / 85% 时分别显示橙色/红色。上下文压缩后显示 `↻`，直到新采样到达；缺失数据显示 `—`，不当作零。悬停可查看采样时间和说明。

用量最多读取日志末尾 8 MiB，本机未变化文件复用缓存；远端回复预览也限于这段尾部。窗口内没有相应事件时保持未知，不回传完整对话或认证文件。账户额度仍由本机已登录 Codex 提供，不与单会话 Token 混算。

## 菜单栏与额度

设置 → 外观 → 菜单栏图标提供三种显示：

- 每日建议剩余：按照自然日的建议量归一化，未用额度可结转，数字可超过100%。圆环最多画满一圈；超过100%蓝色，10%至100%绿色，低于10%红色。
- 每周剩余：绿色表示周剩余，红色表示超过当日参考的已消耗额度，外侧参考点标示截至当日结束建议保留的周额度。
- 原 Logo：使用系统原生模板图标。

数字保持菜单栏的原生文字颜色；空间足够时居中，否则放在圆环旁边。悬停查看更准确的数值和来源。未知数据显示问号，周期过期等待刷新，不伪造零剩余。

账户额度通过现有登录的 Codex app-server 只读获取，每5分钟刷新，设置中也可手动刷新。没有新增登录、授权或重置卡消费行为。卡片期限的缺失、未知、不过期与明细不完整分别显示。

## 设置与登录启动

通过齿轮或换台激活时的 `⌘,` 进入设置。设置和列表共用当前浮窗，返回按钮或 Esc 回到列表；录入快捷键时，Esc 先取消录入。

设置 → 通用 → 开机运行，点击整行注册或取消 macOS 登录启动。登录 Mac 后 App 仅驻菜单栏。待系统允许时，设置会显示对应提示和「打开登录项设置」入口；系统中的实际状态是开关依据。

设置 → 任务音效 → 启用任务 Hook，默认关闭。开启后，换台运行时为本机 Codex 和 DeepSeek Harness 的任务开始、完成和失败播放提示音，两个来源共用同一个音效文件夹。支持范围跟随“连接与数据”的勾选：勾选来源会安装对应 Hook，取消勾选会移除它并停止对应提醒；切换数据目录也会迁移 Hook。音效总开关关闭时，勾选来源仍可读取会话，不会安装 Hook。

已有的其他 Hook 和 DeepSeek Harness 用户设置会保留，关闭时只移除换台条目。Codex 新会话会加载 Hook，如提示需要信任，可在 `/hooks` 中审阅。DeepSeek Harness 使用官方 CLI / 桌面客户端共享的数据主目录；插件随配置热加载，启动时加载配置的 profile 在下次启动时生效。手动中断、历史中断修复和普通工具报错不播放失败音效。

点击「打开音效文件夹」即可替换音乐，目录里直接放 `started.mp3`（Building）、`completed.wav`（Construction Complete）、`failed.wav`（Unit Lost）。保留 `started`、`completed`、`failed` 文件名，扩展名可改为 wav、mp3、aiff、aif、m4a 或 caf；每种状态只保留一个音频，无需重启。删除对应文件即可静音该状态。默认音频来自 [RA2 EVA Commander](https://github.com/zenvor/openpeon-ra2-eva-commander)，来源与上游声明的 CC-BY-NC-4.0 信息随文件夹一起提供。

## CLI

```bash
ht config remote-add build-box user@example '~/.codex'
ht config remote-sync             # 等待远端同步并显示状态
ht config remote-remove build-box
ht list
ht list --favorites --json
ht query 关键词
ht open <会话ID或唯一前缀> --dry-run
ht favorite <会话ID> on
ht complete <会话ID>
ht list --completed
ht reopen <会话ID>
ht usage refresh --json
```

已编译的 CLI 默认使用 `~/Library/Application Support/huantai`。`HUANTAI_HOME`、`HUANTAI_CODEX_HOME` 和 `HUANTAI_BOTMUX_HOME` 分别覆盖状态、Codex 和 Botmux 目录。源码中的 `bin/ht` 是开发启动包装，默认状态为工程 `.local/state/`；使用开发 App 时，两者共享这份数据。

`HUANTAI_DSH_HOME` 覆盖 DeepSeek Harness 数据主目录，未指定时读取 `DSH_HOME` 或 `~/.dsh`。设置中保存的目录优先于环境默认；App、CLI、Web 共用来源开关与目录配置。

Web 详情位于 `http://127.0.0.1:18784/`，随 App 运行，提供筛选、详情和状态操作。远端目标通过设置或 CLI 显式配置，不自动发现 SSH 主机。

## 当前边界

会话索引与原生链接依赖本机客户端的数据和协议。Codex 路由为 `codex://threads/<UUID>`；Botmux 话题需要有效的聊天和话题 ID，缺少时保留具体失败原因。账户接口只提供额度比例，因此每日建议不能解释成官方日限额，也没有绝对 Token 剩余数。
