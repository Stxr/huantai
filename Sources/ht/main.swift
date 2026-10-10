import AppKit
import Foundation
import HuantaiCore

let help = """
    换台 ht — 本地只读会话索引

      ht list [--favorites] [--completed|--include-completed] [--json] [--cached]
      ht query <标题或目录关键词> [--favorites] [--completed|--include-completed] [--json] [--cached]
      ht refresh [--json]
      ht benchmark [次数，默认10] [--json]
      ht open <会话 ID 或唯一前缀> [--dry-run]
      ht favorite <ID> [on|off|toggle]
      ht complete <ID>
      ht reopen <ID>
      ht usage [--json]
      ht usage refresh [--json]
      ht usage import <官方 JSON 快照文件>
      ht config
      ht config map <ID> <已支持的 Codex、飞书链接或 dsh://open>
      ht config remote-add <名称> <user@host> [会话根目录]
      ht config remote-remove <名称>
      ht config remote-sync

    收藏、完成状态与索引保存在 HUANTAI_HOME 或 ~/Library/Application Support/huantai。
    默认只展示未完成会话；--completed 查看已完成，--include-completed 查看全部。
    来源默认全部本机会话；按 AI 最后一条可见回复（含进度）倒序，无回复排末尾。
    远端通过明确配置的 SSH 主机只读同步；需要免交互登录与 python3。来源链接使用已核验的原生协议。
    """

func writeJSON<T: Encodable>(_ value: T) throws {
    let encoder = HuantaiJSON.encoder()
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func chooseSession(_ id: String, from snapshot: IndexSnapshot) throws -> SessionRecord {
    if let exact = snapshot.sessions.first(where: { $0.id == id }) { return exact }
    let matches = snapshot.sessions.filter { $0.id.hasPrefix(id) }
    guard matches.count == 1, let match = matches.first else {
        throw HuantaiError.invalidConfiguration(matches.isEmpty ? "未找到会话 ID。" : "ID 前缀不唯一，请使用更长 ID。")
    }
    return match
}

func printSessions(_ sessions: [SessionRecord]) {
    if sessions.isEmpty {
        print("没有匹配会话。")
        return
    }
    let formatter = ISO8601DateFormatter()
    for session in sessions {
        let date = session.lastAIReplyAt.map(formatter.string(from:)) ?? "暂无 AI 回复"
        print("\(session.isFavorite ? "★" : "☆") \(session.id)  \(date)")
        print("  \(session.title)")
        print(
            "  \(session.isCompleted ? "已完成" : "未完成") · \(session.source) · \(session.machine) · \(session.cwd)"
        )
    }
}

func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty, args[0] != "help", args[0] != "--help", args[0] != "-h" else {
        print(help)
        return
    }
    let command = args.removeFirst()
    let json = args.contains("--json")
    let favoritesOnly = args.contains("--favorites")
    let cached = args.contains("--cached")
    let completedOnly = args.contains("--completed")
    let includeCompleted = args.contains("--include-completed")
    let flags = args.filter { $0.hasPrefix("--") }
    let allowedFlags: Set<String> =
        command == "open"
        ? ["--dry-run"]
        : (command == "list" || command == "query"
            ? ["--json", "--favorites", "--cached", "--completed", "--include-completed"] : ["--json"])
    guard flags.allSatisfy({ allowedFlags.contains($0) }) else {
        throw HuantaiError.invalidConfiguration("未知参数。使用 ht --help 查看命令。")
    }
    args.removeAll { $0.hasPrefix("--") }
    guard !completedOnly || !includeCompleted else {
        throw HuantaiError.invalidConfiguration("--completed 与 --include-completed 请选择其中一个。")
    }
    let store = SessionStore()
    switch command {
    case "benchmark":
        let count = args.first.flatMap(Int.init) ?? 10
        guard args.count <= 1, args.isEmpty || Int(args[0]) != nil, (2...50).contains(count) else {
            throw HuantaiError.invalidConfiguration("用法：ht benchmark [2到50次] [--json]")
        }
        struct Sample: Encodable {
            var durationMilliseconds: Double
            var sessionCount: Int
            var scan: ScanDiagnostics?
        }
        struct Report: Encodable {
            var samples: [Sample]
            var warmMedianMilliseconds: Double
            var warmP95Milliseconds: Double
        }
        var samples: [Sample] = []
        for _ in 0..<count {
            let start = ProcessInfo.processInfo.systemUptime
            let value = try store.refresh()
            samples.append(
                Sample(
                    durationMilliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
                    sessionCount: value.sessions.count, scan: value.scan))
        }
        let warm = samples.dropFirst().map(\.durationMilliseconds).sorted()
        let report = Report(
            samples: samples, warmMedianMilliseconds: warm[warm.count / 2],
            warmP95Milliseconds: warm[min(warm.count - 1, Int(ceil(Double(warm.count) * 0.95)) - 1)])
        if json {
            try writeJSON(report)
        } else {
            print(
                String(
                    format: "首次 %.1f ms；后续中位数 %.1f ms，P95 %.1f ms；%d 个会话。",
                    samples[0].durationMilliseconds, report.warmMedianMilliseconds,
                    report.warmP95Milliseconds, samples[0].sessionCount))
        }
    case "list", "query":
        guard command != "query" || !args.isEmpty else {
            throw HuantaiError.invalidConfiguration("用法：ht query <关键词>")
        }
        guard command != "list" || args.isEmpty else {
            throw HuantaiError.invalidConfiguration("用法：ht list [--favorites] [--json]")
        }
        let snapshot = try cached ? store.snapshot() : store.refresh()
        let sessions = snapshot.filteredSessions(
            query: args.joined(separator: " "), favoritesOnly: favoritesOnly,
            includeCompleted: completedOnly || includeCompleted
        )
        .filter { !completedOnly || $0.isCompleted }
        if json {
            try writeJSON(sessions)
        } else {
            printSessions(sessions)
            if snapshot.sessions.isEmpty {
                for source in snapshot.sources { print("\(source.name)：\(source.status)") }
            }
        }
    case "refresh":
        guard args.isEmpty else { throw HuantaiError.invalidConfiguration("用法：ht refresh [--json]") }
        let snapshot = try store.refreshRemotes()
        if json {
            try writeJSON(snapshot)
        } else {
            print("已刷新 \(snapshot.sessions.count) 个会话，按 AI 最后回复倒序。")
            for source in snapshot.sources { print("\(source.name)：\(source.status)") }
        }
    case "complete", "reopen":
        guard args.count == 1 else { throw HuantaiError.invalidConfiguration("用法：ht \(command) <ID>") }
        let session = try chooseSession(args[0], from: store.snapshot())
        try store.setCompleted(id: session.id, value: command == "complete")
        print("\(command == "complete" ? "已完成" : "已恢复为未完成") \(session.id)")
    case "favorite":
        guard args.count == 1 || args.count == 2 else {
            throw HuantaiError.invalidConfiguration("用法：ht favorite <ID> [on|off|toggle]")
        }
        let session = try chooseSession(args[0], from: store.snapshot())
        let action = args.count == 2 ? args[1] : "toggle"
        guard ["on", "off", "toggle"].contains(action) else {
            throw HuantaiError.invalidConfiguration("收藏动作需为 on、off 或 toggle。")
        }
        let favorite = action == "toggle" ? !session.isFavorite : action == "on"
        try store.setFavorite(id: session.id, value: favorite)
        print("\(favorite ? "已收藏" : "已取消收藏") \(session.id)")
    case "open":
        guard args.count == 1 else { throw HuantaiError.invalidConfiguration("用法：ht open <ID> [--dry-run]") }
        let session = try chooseSession(args[0], from: store.snapshot())
        guard let link = session.openURL, let validated = SessionStore.validatedOpenURL(link),
            let url = URL(string: validated)
        else {
            throw HuantaiError.invalidConfiguration(
                session.openUnavailableReason ?? "该会话尚无已支持的来源链接。可用 ht config map 配置。")
        }
        if flags.contains("--dry-run") {
            print(validated)
            return
        }
        var finished = false
        var openingError: Error?
        SourceOpening.open(url) { error in
            openingError = error
            finished = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !finished, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard finished else { throw HuantaiError.sourceUnavailable("来源应用打开超时。") }
        if let openingError { throw openingError }
        print("已请求打开 \(session.id)")
    case "usage":
        if args.first == "refresh" {
            guard args.count == 1 else {
                throw HuantaiError.invalidConfiguration("用法：ht usage refresh [--json]")
            }
            let usage = try store.refreshUsage()
            if json { try writeJSON(usage) } else { print(usage.status) }
        } else if args.first == "import" {
            guard args.count == 2 else {
                throw HuantaiError.invalidConfiguration("用法：ht usage import <官方 JSON 快照文件>")
            }
            let summary = try store.importUsageSnapshot(
                from: URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath))
            if json { try writeJSON(summary) } else { print("已导入官方格式离线快照；非实时账户连接。") }
        } else {
            guard args.isEmpty else { throw HuantaiError.invalidConfiguration("用法：ht usage [--json]") }
            let usage = try store.snapshot().usage
            if json {
                try writeJSON(usage)
            } else {
                print(usage.status)
                if let window = usage.weekly {
                    print(
                        "周窗口已用 \(String(format: "%.1f", window.usedPercent))%；\(UsageDate.resetText(resetsAt: window.resetsAt))"
                    )
                    let projection = UsageProjection.calculate(window: window)
                    if let budget = projection.referenceBudgetPercent {
                        print("用户参考节奏 \(String(format: "%.1f", budget))%（不是官方日限额）")
                    }
                    if let today = projection.todayReferenceRemainingPercent {
                        let label = today < 0 ? "今日超出" : "今日参考剩余"
                        print("\(label) \(String(format: "%.1f", abs(today)))%（未用参考可累计，以全周额度为100%）")
                    }
                }
                print(usage.resetCount.map { "重置卡 \($0) 张" } ?? "重置卡未连接")
                if let count = usage.resetCount, count > 0 {
                    let credits = Array((usage.resetCredits ?? []).prefix(count))
                    for (index, credit) in credits.enumerated() {
                        print("第\(index + 1)张 · \(UsageDate.creditExpiryText(credit))")
                    }
                    if credits.count < count { print("另有 \(count - credits.count) 张，明细暂未返回") }
                }
            }
        }
    case "config":
        if args.isEmpty {
            if json {
                try writeJSON(store.configuration())
            } else {
                print("数据目录：\(store.dataDirectory.path)")
                print("本地只读来源：\(store.codexDirectory.path)")
                let targets = try store.configuration().remoteTargets
                if targets.isEmpty { print("远端目标未配置。") }
                for target in targets { print("\(target.name)：\(target.host) · \(target.sessionRoot)") }
            }
        } else if args.first == "map" {
            guard args.count == 3 else {
                throw HuantaiError.invalidConfiguration("用法：ht config map <ID> <已核验 URL>")
            }
            let session = try chooseSession(args[1], from: store.snapshot())
            try store.setOpenMapping(id: session.id, url: args[2])
            print("已保存打开映射 \(session.id)")
        } else if args.first == "remote-sync", args.count == 1 {
            let snapshot = try store.refreshRemotes()
            if json {
                try writeJSON(snapshot)
            } else {
                for source in snapshot.sources { print("\(source.name)：\(source.status)") }
            }
        } else if args.first == "remote-remove", args.count == 2 {
            let targets = try store.configuration().remoteTargets.filter {
                $0.name == args[1] || $0.id == args[1]
            }
            guard targets.count == 1, let target = targets.first else {
                throw HuantaiError.invalidConfiguration("远端名称不唯一或不存在，请指定配置 ID。")
            }
            try store.removeRemoteTarget(id: target.id)
            print("已移除远端目标。")
        } else if args.first == "remote-add" {
            guard args.count == 3 || args.count == 4 else {
                throw HuantaiError.invalidConfiguration("用法：ht config remote-add <名称> <user@host> [根目录]")
            }
            let target = RemoteTarget(
                id: "ssh-" + args[1], name: args[1], host: args[2],
                sessionRoot: args.count == 4 ? args[3] : "~/.codex")
            try store.setRemoteTarget(target)
            print("已保存远端目标；App 将后台同步，可运行 ht config remote-sync 立即同步。")
        } else {
            throw HuantaiError.invalidConfiguration("未知配置命令。使用 ht --help 查看命令。")
        }
    default: throw HuantaiError.invalidConfiguration("未知命令。使用 ht --help 查看命令。")
    }
}

do { try run() } catch {
    let message = "ht：\(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
