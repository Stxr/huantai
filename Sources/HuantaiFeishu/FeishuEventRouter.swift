import CryptoKit
import Foundation
import HuantaiCore

/// All events are authenticated by the app's WebSocket, then restricted to the paired owner/chat.
final class FeishuEventRouter {
    let configuration: FeishuBotConfiguration
    init(configuration: FeishuBotConfiguration) { self.configuration = configuration }

    func handle(_ data: Data, snapshot: IndexSnapshot, bindingID: String, now: Date = .now) throws -> [String:
        Any]?
    {
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let header = envelope["header"] as? [String: Any],
            let binding = try configuration.binding(), binding.id == bindingID,
            header["app_id"] as? String == binding.appID,
            let event = envelope["event"] as? [String: Any]
        else { return nil }
        switch header["event_type"] as? String {
        case "im.message.receive_v1":
            try message(event, snapshot: snapshot, binding: binding, now: now)
            return nil
        case "card.action.trigger": return try callback(event, snapshot: snapshot, binding: binding, now: now)
        default: return nil
        }
    }

    private func message(
        _ event: [String: Any], snapshot: IndexSnapshot, binding: FeishuBotBinding, now: Date
    ) throws {
        guard let sender = event["sender"] as? [String: Any], sender["sender_type"] as? String == "user",
            let senderID = sender["sender_id"] as? [String: Any], let owner = senderID["open_id"] as? String,
            let message = event["message"] as? [String: Any], message["chat_type"] as? String == "p2p",
            message["message_type"] as? String == "text", let chat = message["chat_id"] as? String,
            let id = message["message_id"] as? String, let raw = message["content"] as? String,
            let textData = raw.data(using: .utf8),
            let content = try JSONSerialization.jsonObject(with: textData) as? [String: Any],
            let text = content["text"] as? String
        else { return }
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if binding.ownerID == nil {
            let parts = command.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0] == "/bind",
                let paired = try configuration.pair(
                    id: binding.id, code: String(parts[1]), ownerID: owner, chatID: chat, now: now)
            else { return }
            try enqueue(
                id: id, chat: chat, binding: paired, snapshot: snapshot, filter: paired.filter, now: now)
            return
        }
        guard owner == binding.ownerID, chat == binding.chatID else { return }
        let parts = command.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = parts.first, ["/status", "/settings", "/help"].contains(String(name)) else { return }
        var filter = binding.filter
        filter.query = parts.count > 1 && name == "/status" ? String(parts[1].prefix(100)) : ""
        try enqueue(id: id, chat: chat, binding: binding, snapshot: snapshot, filter: filter, now: now)
    }

    private func enqueue(
        id: String, chat: String, binding: FeishuBotBinding, snapshot: IndexSnapshot,
        filter: FeishuDashboardFilter, now: Date
    ) throws {
        let uuid = SHA256.hash(data: Data((binding.id + id).utf8)).prefix(16).map {
            String(format: "%02x", $0)
        }.joined()
        let card = try FeishuDashboardCard.json(
            snapshot: snapshot, binding: binding, filter: filter, now: now)
        try configuration.enqueue(
            .init(
                id: uuid, bindingID: binding.id, chatID: chat, card: String(decoding: card, as: UTF8.self),
                createdAt: now))
    }

    private func callback(
        _ event: [String: Any], snapshot: IndexSnapshot, binding: FeishuBotBinding, now: Date
    ) throws -> [String: Any] {
        let denied: [String: Any] = ["toast": ["type": "error", "content": "仅配对账号可操作，请重新发送 /status。"]]
        guard let user = event["operator"] as? [String: Any],
            let context = event["context"] as? [String: Any],
            let owner = binding.ownerID, user["open_id"] as? String == owner,
            context["open_chat_id"] as? String == binding.chatID,
            let action = event["action"] as? [String: Any], let value = action["value"] as? [String: Any],
            value["binding"] as? String == binding.id
        else { return denied }
        var filter = FeishuDashboardFilter()
        filter.days = value["days"] as? Int ?? 0
        filter.favoritesOnly = value["favorites"] as? Bool ?? false
        filter.completedOnly = value["completed"] as? Bool ?? false
        filter.pageSize = value["size"] as? Int ?? 5
        filter.query = value["query"] as? String ?? ""
        var page = min(100_000, max(0, value["page"] as? Int ?? 0))
        let operation = value["action"] as? String ?? ""
        switch operation {
        case "days":
            filter.days = Int(action["option"] as? String ?? "") ?? -1
            page = 0
        case "size":
            filter.pageSize = Int(action["option"] as? String ?? "") ?? -1
            page = 0
        case "favorites":
            filter.favoritesOnly.toggle()
            page = 0
        case "completed":
            filter.completedOnly.toggle()
            page = 0
        case "previous": page = max(0, page - 1)
        case "next": page += 1
        case "refresh": break
        default: return denied
        }
        _ = try filter.validated()
        if ["days", "size", "favorites", "completed"].contains(operation) {
            var saved = filter
            saved.query = ""
            try configuration.setFilter(saved, bindingID: binding.id)
        }
        let card = FeishuDashboardCard.card(
            snapshot: snapshot, binding: binding, filter: filter, page: page, now: now)
        return ["card": ["type": "raw", "data": card], "toast": ["type": "success", "content": "看板已更新"]]
    }
}
