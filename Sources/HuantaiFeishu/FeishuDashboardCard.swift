import Foundation
import HuantaiCore

public enum FeishuDashboardCard {
    public static func json(
        snapshot: IndexSnapshot, binding: FeishuBotBinding, filter: FeishuDashboardFilter? = nil,
        page: Int = 0, now: Date = .now
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: card(
                snapshot: snapshot, binding: binding, filter: filter ?? binding.filter, page: page, now: now),
            options: [.sortedKeys])
    }

    static func card(
        snapshot: IndexSnapshot, binding: FeishuBotBinding, filter: FeishuDashboardFilter, page: Int,
        now: Date
    ) -> [String: Any] {
        let sessions = snapshot.filteredSessions(
            query: filter.query, favoritesOnly: filter.favoritesOnly, includeCompleted: filter.completedOnly
        ).filter {
            (!filter.completedOnly || $0.isCompleted)
                && (filter.days == 0
                    || ($0.lastAIReplyAt ?? .distantPast)
                        >= now.addingTimeInterval(-Double(filter.days) * 86400))
        }
        let size = min(10, max(3, filter.pageSize))
        let pages = max(1, (sessions.count + size - 1) / size)
        let page = min(pages - 1, max(0, page))
        let state: [String: Any] = [
            "binding": binding.id, "days": filter.days, "favorites": filter.favoritesOnly,
            "completed": filter.completedOnly, "size": size, "query": filter.query, "page": page,
        ]
        var elements = quotaElements(snapshot.usage, now: now)
        elements.append(["tag": "hr"])
        elements.append(
            columns([
                selector(
                    options: [("0", "所有日期"), ("1", "近1日"), ("3", "近3日"), ("7", "近7日")],
                    selected: String(filter.days), action: "days", state: state),
                button(filter.favoritesOnly ? "★ 只看收藏" : "☆ 全部会话", action: "favorites", state: state),
                button(filter.completedOnly ? "✓ 已完成" : "○ 未完成", action: "completed", state: state),
            ]))
        if !filter.query.isEmpty { elements.append(markdown("搜索：" + escape(filter.query))) }
        if sessions.isEmpty { elements.append(markdown("当前筛选下没有会话。可调整日期、收藏或完成状态。")) }
        for session in sessions.dropFirst(page * size).prefix(size) {
            var title: [String: Any] = [
                "tag": "button", "type": "primary_text", "width": "fill",
                "text": plain((session.isFavorite ? "★ " : "") + String(session.title.prefix(100))),
            ]
            if let url = session.openURL.flatMap(SessionStore.validatedOpenURL) {
                title["behaviors"] = [
                    [
                        "type": "open_url", "default_url": mobileURL(url), "pc_url": url,
                        "ios_url": mobileURL(url), "android_url": mobileURL(url),
                    ]
                ]
            } else {
                title["disabled"] = true
                title["disabled_tips"] = plain(session.openUnavailableReason ?? "尚无会话跳转链接")
                title["behaviors"] = [
                    ["type": "callback", "value": state.merging(["action": "refresh"]) { _, new in new }]
                ]
            }
            elements.append(title)
            let reply = session.lastAIReplyAt.map { UsageDate.referenceEndText(endsAt: $0) } ?? "暂无 AI 回复"
            elements.append(
                markdown(
                    "<font color='grey'>\(escape(session.source)) · \(escape(session.machine)) · \(reply)</font>"
                ))
            if let usage = session.tokenUsage {
                elements.append(
                    markdown(
                        "<font color='grey'>累计 Token：\(usage.compactTotal) · 上下文 \(usage.compactContext)</font>"
                    ))
            }
            elements.append(["tag": "hr"])
        }
        elements.append(
            columns([
                button("上一页", action: "previous", state: state, disabled: page == 0),
                button("刷新", action: "refresh", state: state),
                button("下一页", action: "next", state: state, disabled: page == pages - 1),
            ]))
        elements.append(
            columns([
                markdown("第 \(page + 1) / \(pages) 页 · \(sessions.count) 个会话"),
                selector(
                    options: [("3", "每页3项"), ("5", "每页5项"), ("10", "每页10项")], selected: String(size),
                    action: "size", state: state),
            ]))
        elements.append(
            markdown(
                "<font color='grey'>更新于 \(UsageDate.referenceEndText(endsAt: snapshot.updatedAt)) · /status 关键词 可搜索\n本机来源需在安装对应客户端的电脑上打开。</font>"
            ))
        return [
            "schema": "2.0", "config": ["update_multi": true],
            "header": ["title": plain("换台 · 会话看板"), "template": "blue"],
            "body": [
                "direction": "vertical", "padding": "12px", "vertical_spacing": "8px", "elements": elements,
            ],
        ]
    }

    private static func quotaElements(_ usage: UsageSummary, now: Date) -> [[String: Any]] {
        guard let weekly = usage.weekly, weekly.usedPercent.isFinite else {
            return [markdown("**周额度 · 未连接**"), markdown(escape(usage.status))]
        }
        let remaining = min(100, max(0, 100 - weekly.usedPercent))
        let filled = Int((remaining / 5).rounded())
        let projection = UsageProjection.calculate(window: weekly, now: now)
        let color = (projection.todayReferenceRemainingPercent ?? 0) < 0 ? "red" : "green"
        var elements = [
            markdown("**周额度　剩余 \(String(format: "%.0f", remaining))%**"),
            markdown(
                "<font color='\(color)'>" + String(repeating: "▰", count: filled)
                    + String(repeating: "▱", count: 20 - filled) + "</font>"),
        ]
        if let today = projection.todayReferenceRemainingPercent {
            elements.append(
                markdown(
                    "<font color='\(color)'>\(today < 0 ? "今日超出" : "今日参考剩余") \(String(format: "%.1f", abs(today)))%</font>　\(UsageDate.resetText(resetsAt: weekly.resetsAt))"
                ))
            elements.append(
                markdown(
                    "<font color='grey'>本日截止 \(UsageDate.referenceEndText(endsAt: projection.todayReferenceEndsAt))，以周额度为100%</font>"
                ))
        } else {
            elements.append(markdown("今日参考待更新 · " + UsageDate.resetText(resetsAt: weekly.resetsAt)))
        }
        if let count = usage.resetCount {
            let expiry = (usage.resetCredits ?? []).prefix(max(0, count)).filter { $0.expirationKnown }
                .compactMap(\.expiresAt).filter { $0 > now }.min()
            let urgent = expiry.map { $0 <= now.addingTimeInterval(3 * 86400) } ?? false
            let expiryText = expiry.map { " · 最近到期 " + UsageDate.referenceEndText(endsAt: $0) } ?? ""
            elements.append(
                markdown("<font color='\(urgent ? "red" : "green")'>重置卡 \(count) 张\(expiryText)</font>"))
        }
        return elements
    }

    private static func mobileURL(_ value: String) -> String {
        guard let url = URL(string: value) else { return "lark://msgcard/unsupported_action" }
        if url.scheme == "https" { return value }
        if url.scheme == "lark", url.host == "applink.feishu.cn" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.scheme = "https"
            return components.string!
        }
        return "lark://msgcard/unsupported_action"
    }

    static func plain(_ text: String) -> [String: Any] { ["tag": "plain_text", "content": text] }
    static func markdown(_ text: String) -> [String: Any] { ["tag": "markdown", "content": text] }
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
    private static func columns(_ elements: [[String: Any]]) -> [String: Any] {
        [
            "tag": "column_set", "flex_mode": "flow", "horizontal_spacing": "8px",
            "columns": elements.map {
                ["tag": "column", "width": "weighted", "weight": 1, "elements": [$0]] as [String: Any]
            },
        ]
    }
    private static func button(_ text: String, action: String, state: [String: Any], disabled: Bool = false)
        -> [String: Any]
    {
        [
            "tag": "button", "text": plain(text), "type": "default", "disabled": disabled,
            "behaviors": [
                ["type": "callback", "value": state.merging(["action": action]) { _, new in new }]
            ],
        ]
    }
    private static func selector(
        options: [(String, String)], selected: String, action: String, state: [String: Any]
    ) -> [String: Any] {
        [
            "tag": "select_static", "initial_option": selected, "width": "fill",
            "options": options.map { ["value": $0.0, "text": plain($0.1)] },
            "behaviors": [
                ["type": "callback", "value": state.merging(["action": action]) { _, new in new }]
            ],
        ]
    }
}
