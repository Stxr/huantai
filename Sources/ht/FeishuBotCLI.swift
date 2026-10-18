import AppKit
import Darwin
import Foundation
import HuantaiCore
import HuantaiFeishu

let botHelp = """
    飞书机器人：
      ht bot create [--name 名称] [--json] [--no-open]
                                          扫码创建并绑定机器人，中断后再次运行可继续
      ht bot bind <AppID> --secret-stdin   从标准输入安全读取App Secret并绑定
      ht bot status [--json]              查看绑定及连接状态，不输出密钥
      ht bot pair                         生成10分钟有效的配对指令
      ht bot unbind                       解绑并删除本机凭据
      ht bot set days <0|1|3|7>            默认日期范围（0为所有）
      ht bot set favorites <on|off>       收藏筛选
      ht bot set completed <on|off>       完成状态筛选
      ht bot set page-size <3|5|10>       每页会话数
      ht bot preview                     输出卡片JSON，不发送消息
      ht bot run                         前台监听（App已运行时无需重复启动）
    机器人需启用单聊接收消息/发送消息权限、长连接事件im.message.receive_v1及回调card.action.trigger。
    绑定后私聊机器人发送配对指令，再发送/status。仅配对账号可访问。
    """

func runFeishuBotCLI(_ args: [String]) throws {
    let store = feishuCLIStore()
    let config = FeishuBotConfiguration(dataDirectory: store.dataDirectory)
    guard let command = args.first else {
        print(botHelp)
        return
    }
    let rest = Array(args.dropFirst())
    switch command {
    case "help", "--help": print(botHelp)
    case "create":
        try runBotCreation(rest, store: store, configuration: config)
    case "bind":
        guard rest.count == 2, rest[1] == "--secret-stdin" else { throw FeishuBotError.message(botHelp) }
        let secret = try readBotSecret()
        try waitForBotTask { try await FeishuBotSetup.validate(appID: rest[0], secret: secret) }
        let binding = try config.bind(appID: rest[0], secret: secret)
        print("机器人已绑定。保持换台运行，或执行 ht bot run。")
        print("10分钟内私聊机器人发送：/bind \(binding.pairingCode!)")
    case "status":
        guard rest.isEmpty || rest == ["--json"] else { throw FeishuBotError.message(botHelp) }
        let status = try config.status()
        if rest == ["--json"] {
            try writeJSON(status)
        } else {
            print("\(status.appID ?? "未绑定") · \(status.paired ? "已配对" : "未配对") · \(status.connection)")
        }
    case "pair":
        guard rest.isEmpty else { throw FeishuBotError.message(botHelp) }
        let binding = try config.renewPairing()
        print("10分钟内私聊机器人发送：/bind \(binding.pairingCode!)")
    case "unbind":
        guard rest.isEmpty else { throw FeishuBotError.message(botHelp) }
        try config.unbind()
        print("已解绑机器人并删除本机凭据。")
    case "set":
        guard rest.count == 2, var filter = try config.binding()?.filter else {
            throw FeishuBotError.message(botHelp)
        }
        switch rest[0] {
        case "days": filter.days = Int(rest[1]) ?? -1
        case "page-size": filter.pageSize = Int(rest[1]) ?? -1
        case "favorites", "completed":
            guard ["on", "off"].contains(rest[1]) else { throw FeishuBotError.message(botHelp) }
            if rest[0] == "favorites" {
                filter.favoritesOnly = rest[1] == "on"
            } else {
                filter.completedOnly = rest[1] == "on"
            }
        default: throw FeishuBotError.message(botHelp)
        }
        try config.setFilter(filter)
        print("已保存机器人默认筛选。重新发送 /status 生效。")
    case "preview":
        guard rest.isEmpty, let binding = try config.binding() else {
            throw FeishuBotError.message("请先绑定机器人。")
        }
        print(
            String(
                decoding: try FeishuDashboardCard.json(snapshot: store.snapshot(), binding: binding),
                as: UTF8.self))
    case "run":
        guard rest.isEmpty, try config.binding() != nil else { throw FeishuBotError.message("请先绑定机器人。") }
        print("正在监听飞书机器人；Ctrl-C 停止。")
        try waitForBotTask { try await FeishuBotService(store: store, refreshSessions: true).run() }
    default: throw FeishuBotError.message(botHelp)
    }
}

private func readBotSecret() throws -> String {
    var previous = termios()
    let terminal = isatty(STDIN_FILENO) == 1 && tcgetattr(STDIN_FILENO, &previous) == 0
    if terminal {
        var hidden = previous
        hidden.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &hidden)
        FileHandle.standardError.write(Data("App Secret（输入不回显）：".utf8))
    }
    defer {
        if terminal {
            tcsetattr(STDIN_FILENO, TCSANOW, &previous)
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
    guard let secret = readLine(), !secret.isEmpty else { throw FeishuBotError.message("标准输入中没有App Secret。") }
    return secret
}

func waitForBotTask(_ action: @escaping @Sendable () async throws -> Void) throws {
    let done = DispatchSemaphore(value: 0)
    final class ResultBox: @unchecked Sendable { var error: Error? }
    let result = ResultBox()
    Task.detached {
        do { try await action() } catch { result.error = error }
        done.signal()
    }
    done.wait()
    if let error = result.error { throw error }
}
