import AppKit
import CoreImage
import Darwin
import Foundation
import HuantaiCore
import HuantaiFeishu

/// Bot commands follow the app's retained state directory unless explicitly overridden.
func feishuCLIStore() -> SessionStore {
    if ProcessInfo.processInfo.environment["HUANTAI_HOME"] != nil { return SessionStore() }
    let path = UserDefaults(suiteName: "local.huantai.app")?.string(forKey: "launchDirectory.HUANTAI_HOME")
    return SessionStore(dataDirectory: path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil })
}

func runBotCreation(_ args: [String], store: SessionStore, configuration: FeishuBotConfiguration) throws {
    var name = "换台状态助手"
    var json = false
    var noOpen = false
    var remaining = args[...]
    while let option = remaining.first {
        remaining = remaining.dropFirst()
        switch option {
        case "--json": json = true
        case "--no-open": noOpen = true
        case "--name":
            guard let value = remaining.first, !value.hasPrefix("--") else {
                throw FeishuBotError.message("--name 后需要机器人名称。")
            }
            name = value
            remaining = remaining.dropFirst()
        case "--help", "-h":
            print("ht bot create [--name 名称] [--json] [--no-open]\n扫码确认后自动创建并绑定飞书机器人；中断后重复运行可继续同一次创建。")
            return
        default: throw FeishuBotError.message("未知参数。用法：ht bot create [--name 名称] [--json] [--no-open]")
        }
    }
    let appName = name
    let jsonOutput = json
    let shouldOpen = !noOpen && !json
    try waitForBotTask {
        var binding = try configuration.binding()
        if binding == nil {
            let registration = FeishuAppRegistration(configuration: configuration)
            let progress = try await registration.begin(name: appName)
            let challenge = progress.challenge
            let qr = try? registrationQRCode(challenge.verificationURL, directory: configuration.directory)
            if jsonOutput {
                try emitBotCreation([
                    "event": "authorization_required", "url": challenge.verificationURL.absoluteString,
                    "qrFile": qr?.path ?? "", "resumed": progress.resumed,
                    "expiresAt": ISO8601DateFormatter().string(from: challenge.expiresAt),
                ])
            } else {
                print(progress.resumed ? "继续上次创建，不会新建第二个应用。" : "请用飞书扫描二维码，确认创建换台机器人：")
                if let qr { print(qr.terminal) }
                print(challenge.verificationURL.absoluteString)
                print("确认页仅请求机器人单聊收发、消息事件和卡片回调；无需在后台复制 App Secret。")
                fflush(stdout)
            }
            if shouldOpen { NSWorkspace.shared.open(challenge.verificationURL) }
            binding = try await registration.finish(challenge)
            if jsonOutput {
                try emitBotCreation(["event": "bound", "appID": binding!.appID])
            } else {
                print("机器人已创建并安全绑定，正在检查所需权限与长连接入口…")
                fflush(stdout)
            }
        } else if !jsonOutput {
            print("已存在绑定，检查现有机器人，不会重复创建。")
        }
        guard let binding else { throw FeishuBotError.message("没有取得机器人绑定。") }
        try await FeishuBotSetup.checkDashboard(appID: binding.appID, configuration: configuration)
        let status = try configuration.status()
        let chat = "https://applink.feishu.cn/client/bot/open?appId=" + binding.appID
        let pairCommand = binding.pairingCode.map { "/bind " + $0 } ?? ""
        if jsonOutput {
            try emitBotCreation([
                "event": "ready", "appID": binding.appID, "chatURL": chat,
                "paired": binding.ownerID != nil, "pairCommand": pairCommand,
                "connection": status.connection, "dataDirectory": store.dataDirectory.path,
            ])
        } else {
            print("权限与长连接入口检查通过。")
            print("机器人聊天：" + chat)
            if !pairCommand.isEmpty { print("10分钟内私聊发送：" + pairCommand) }
            print("配对后发送 /status 获取真实状态卡片。保持换台运行；独立使用 CLI 时运行 ht bot run。")
            print("连接状态：" + status.connection)
        }
    }
}

private func emitBotCreation(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(
        withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

private func registrationQRCode(_ url: URL, directory: URL) throws -> (path: String, terminal: String) {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { throw FeishuBotError.message("无法生成二维码。") }
    filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { throw FeishuBotError.message("无法生成二维码。") }
    let context = CIContext()
    guard let pixels = context.createCGImage(image, from: image.extent),
        let scaled = context.createCGImage(
            image.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
            from: image.extent.applying(CGAffineTransform(scaleX: 8, y: 8))),
        let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    else { throw FeishuBotError.message("无法渲染二维码。") }
    let file = directory.appendingPathComponent("create-qr.png")
    try png.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let bitmap = NSBitmapImageRep(cgImage: pixels)
    var rows: [String] = []
    let width = bitmap.pixelsWide
    let height = bitmap.pixelsHigh
    for y in -2..<(height + 2) {
        var row = ""
        for x in -2..<(width + 2) {
            let black =
                x >= 0 && y >= 0 && x < width && y < height
                && (bitmap.colorAt(x: x, y: y)?.redComponent ?? 1) < 0.5
            row += black ? "  " : "██"
        }
        rows.append(row)
    }
    return (file.path, rows.joined(separator: "\n"))
}
