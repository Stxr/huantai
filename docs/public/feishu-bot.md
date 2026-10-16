# 飞书机器人看板

换台可以绑定一个飞书企业自建应用机器人。在机器人私聊中发送 `/status`，收到额度和会话列表卡片；`/status 关键词` 搜索标题或目录，`/settings` 显示可调整筛选的看板。

卡片顶部显示周剩余、以官方重置时刻为起点的今日参考及重置卡；下方按 AI 回复时间列出会话。支持近1/3/7日或所有日期、收藏和完成状态筛选、每页3/5/10项及上一页/下一页。按钮直接更新原卡片。筛选保存为该机器人的默认值，分页与搜索保留在各自卡片内；机器人筛选与 Mac 列表筛选分别保存。

标题使用已有来源链接：飞书话题可在飞书打开；Codex/DeepSeek Harness 本机协议需要电脑安装对应客户端，手机不支持此类本机跳转。没有经过验证的来源链接时，标题按钮禁用，不猜测链接，也不远程执行本机打开命令。

## 设置中绑定

1. 打开换台设置 → 飞书机器人。已有应用时填写 App ID 和 App Secret；没有应用时点击“创建应用机器人”，进入[飞书开放平台](https://open.feishu.cn/app)创建企业自建应用并开启机器人能力。
2. 为应用启用 `im:message.p2p_msg:readonly`（读取发给机器人的单聊消息）、`im:message:send_as_bot`（以机器人身份发消息）权限。
3. 点击绑定。换台验证应用凭据并建立长连接。进入应用“事件与回调”，将**事件配置和回调配置**均设为长连接；添加事件 `im.message.receive_v1`、回调 `card.action.trigger`，发布应用并确保可用范围包含自己。
4. 点击“打开机器人聊天”，私聊发送设置里展示的 `/bind 配对码`。配对码10分钟有效，过期可点“重新配对”。配对成功即收到第一张看板。

仅配对账号在配对的私聊中可以查看和操作看板，群聊和其他用户的请求不返回会话数据。每次重新配对都会使旧卡片的交互失效。App Secret 保存在本机状态目录的 `feishu-bot/binding.json`，目录权限0700、文件权限0600；状态查询不显示密钥。

“解绑机器人”会移除本机凭据、配对和待发送消息，并断开长连接；不会删除飞书应用或撤回已发卡片。创建应用、授权和发布仍在官方开发者后台完成，换台不会替你申请额外权限。

## CLI

```bash
ht bot create
ht bot bind cli_your_app_id --secret-stdin
# 在终端输入密钥，输入不回显；不要把密钥直接作为命令行参数。
ht bot status
ht bot pair
ht bot set days 3
ht bot set favorites on
ht bot set completed off
ht bot set page-size 5
ht bot preview  # 只输出卡片 JSON，不发送
ht bot run     # 前台监听，Ctrl-C 停止
ht bot unbind
```

App 与 CLI 使用同一 `HUANTAI_HOME`/默认状态目录。运行 App 时自动监听，无需另开 `ht bot run`；同一目录只有一个进程获得监听锁。CLI 单独运行时每5秒更新会话，每5分钟刷新额度。Mac 休眠、退出或离线期间机器人不能即时响应；恢复联网后自动重连。

消息入站先落入本机待发队列再确认，使用固定消息 UUID 去重；临时失败自动重试，待发送消息最多保留30分钟。卡片交互使用本机缓存快照响应，避免网络读取超过飞书的3秒回调期限；刷新按钮展示最新已完成的扫描结果。

## 实现与验证入口

- `HuantaiFeishu`：受限配置、飞书 REST API、长连接帧、事件路由和卡片生成。App/CLI 共用，无需 Node/Python 服务或公网回调地址。
- [飞书长连接事件说明](https://open.feishu.cn/document/server-docs/event-subscription-guide/event-subscription-configure-/request-url-configuration-case)
- [卡片回传交互](https://open.feishu.cn/document/feishu-cards/card-callback-communication)
- [JSON 2.0 按钮](https://open.feishu.cn/document/feishu-cards/card-json-v2-components/interactive-components/button)
- [官方 SDK 的 WebSocket 帧定义](https://github.com/larksuite/oapi-sdk-go/blob/v3_main/ws/pbbp2.pb.go)

本地测试覆盖配对过期、账号/私聊隔离、解绑与换绑、持久化去重、筛选和分页、长连接分片及异常帧、消息认证过期重试。不会在测试中连接真实机器人或发送真实消息。
