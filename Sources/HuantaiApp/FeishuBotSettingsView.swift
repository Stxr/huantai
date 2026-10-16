import HuantaiFeishu
import SwiftUI

struct FeishuBotSettingsView: View {
    @ObservedObject var manager: FeishuBotManager
    @State private var appID = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("飞书机器人").font(.system(size: 15, weight: .semibold))
            Text("在飞书发送 /status，查看额度与会话，并筛选、翻页或打开会话。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label(manager.status, systemImage: "bubble.left.and.bubble.right")
                    .font(.system(size: 11)).textSelection(.enabled)
                if let binding = manager.binding {
                    Text(binding.appID).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Link(
                        "打开机器人聊天 ↗",
                        destination: URL(
                            string: "https://applink.feishu.cn/client/bot/open?appId=\(binding.appID)")!)
                    if let code = binding.pairingCode {
                        Text("给机器人私聊发送以下指令，完成账号配对：").font(.caption)
                        Text("/bind \(code)").font(.system(size: 12, design: .monospaced)).textSelection(
                            .enabled)
                        Text("配对码有效期10分钟。仅配对账号可以查看看板。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("已配对，可以发送 /status 或 /status 关键词", systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.green)
                    }
                    HStack {
                        Button("重新配对") { manager.renewPairing() }
                        Spacer()
                        Button("解绑机器人", role: .destructive) {
                            manager.unbind()
                            secret = ""
                        }
                    }
                    Divider()
                    Picker("默认消息范围", selection: filterBinding(\.days)) {
                        Text("所有").tag(0)
                        Text("近1日").tag(1)
                        Text("近3日").tag(3)
                        Text("近7日").tag(7)
                    }
                    Picker("每页会话", selection: filterBinding(\.pageSize)) {
                        Text("3项").tag(3)
                        Text("5项").tag(5)
                        Text("10项").tag(10)
                    }
                    Toggle("只看收藏", isOn: filterBinding(\.favoritesOnly))
                    Toggle("查看已完成", isOn: filterBinding(\.completedOnly))
                } else {
                    TextField("App ID", text: $appID).textFieldStyle(.roundedBorder)
                    SecureField("App Secret", text: $secret).textFieldStyle(.roundedBorder)
                    HStack {
                        Button(manager.busy ? "正在验证…" : "绑定机器人") {
                            manager.bind(appID: appID, secret: secret)
                            secret = ""
                        }
                        .disabled(manager.busy || appID.isEmpty || secret.isEmpty)
                        Spacer()
                        Link("创建应用机器人 ↗", destination: FeishuBotConfiguration.createURL)
                    }
                }
                if let error = manager.error { Text(error).font(.caption).foregroundStyle(.red) }
                DisclosureGroup("机器人接入步骤") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. 在飞书开放平台创建企业自建应用，启用机器人，填写 App ID 和 App Secret。")
                        Text("2. 开通读取机器人单聊消息和以机器人身份发消息权限。")
                        Text("3. 绑定后，在开放平台将事件与回调都设为长连接；订阅 im.message.receive_v1 与 card.action.trigger，并发布应用。")
                        Text("4. 私聊机器人发送配对指令，然后发送 /status。")
                        Text("换台需保持运行并联网，也可使用 ht bot run。解绑会停止连接并移除本机凭据；已发出的卡片仍保留在聊天里。")
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private func filterBinding<Value>(_ key: WritableKeyPath<FeishuDashboardFilter, Value>) -> Binding<Value>
    {
        Binding(
            get: { (manager.binding?.filter ?? .init())[keyPath: key] },
            set: { value in
                var filter = manager.binding?.filter ?? .init()
                filter[keyPath: key] = value
                manager.setFilter(filter)
            })
    }
}
