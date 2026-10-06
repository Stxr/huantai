import AppKit
import Foundation

/// Native routes from installed applications and Botmux's thread-link generator.
public enum SourceOpening {
    public static let deepSeekHarnessURL = "dsh://open"

    public static func codexURL(sessionID: String) -> String? {
        guard UUID(uuidString: sessionID) != nil else { return nil }
        return "codex://threads/" + sessionID.lowercased()
    }

    public static func feishuChatURL(chatID: String) -> String? {
        guard chatID.count <= 128,
            chatID.range(of: "^oc_[A-Za-z0-9]+$", options: .regularExpression) != nil
        else { return nil }
        var url = URLComponents(string: "lark://applink.feishu.cn/client/chat/open")!
        url.queryItems = [URLQueryItem(name: "openChatId", value: chatID)]
        return url.url?.absoluteString
    }

    public static func feishuThreadURL(chatID: String, threadID: String) -> String? {
        guard feishuChatURL(chatID: chatID) != nil, threadID.count <= 128,
            threadID.range(of: "^omt_[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return nil }
        var url = URLComponents(string: "lark://applink.feishu.cn/client/thread/open")!
        // Match Botmux's generator, including the client's legacy parameter aliases.
        url.queryItems = [
            URLQueryItem(name: "open_chat_id", value: chatID),
            URLQueryItem(name: "open_thread_id", value: threadID),
            URLQueryItem(name: "openchatid", value: chatID),
            URLQueryItem(name: "openthreadid", value: threadID),
            URLQueryItem(name: "thread_position", value: "-1"),
        ]
        return url.url?.absoluteString
    }

    public static func feishuApplication(
        candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/Lark.app"),
            URL(fileURLWithPath: "/Applications/Feishu.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Lark.app"),
        ]
    ) -> URL? {
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.electron.lark")
        return (candidates + [registered].compactMap { $0 }).first { candidate in
            guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "com.electron.lark",
                let types = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
            else { return false }
            return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("lark") == true }
        }
    }

    public static func codexApplication(
        candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/Codex.app"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Codex.app"),
        ]
    ) -> URL? {
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        return (candidates + [registered].compactMap { $0 }).first { candidate in
            guard let bundle = Bundle(url: candidate), bundle.bundleIdentifier == "com.openai.codex",
                let types = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]]
            else { return false }
            return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("codex") == true }
        }
    }

    public static func deepSeekHarnessApplication(
        candidates: [URL] = [
            URL(fileURLWithPath: "/Applications/DeepSeek Harness.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Applications/DeepSeek Harness.app"),
        ]
    ) -> URL? {
        let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.deepseek.dsh")
        return (candidates + [registered].compactMap { $0 }).first {
            Bundle(url: $0)?.bundleIdentifier == "com.deepseek.dsh"
        }
    }

    public static func open(_ url: URL, completion: @escaping (Error?) -> Void) {
        guard let value = SessionStore.validatedOpenURL(url.absoluteString), let url = URL(string: value)
        else {
            completion(HuantaiError.invalidOpenURL)
            return
        }
        if url.scheme?.lowercased() == "dsh" {
            guard let application = deepSeekHarnessApplication() else {
                completion(HuantaiError.sourceUnavailable("未找到已安装的官方 DeepSeek Harness 应用，请先安装。"))
                return
            }
            NSWorkspace.shared.openApplication(at: application, configuration: .init()) { _, error in
                completion(error)
            }
        } else if url.scheme?.lowercased() == "codex" {
            guard let application = codexApplication() else {
                completion(
                    HuantaiError.sourceUnavailable(
                        "未找到已安装的 Codex 应用。可在终端执行 codex resume " + String(url.path.dropFirst()) + "。"))
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) {
                _, error in
                completion(error)
            }
        } else {
            guard let application = feishuApplication() else {
                completion(HuantaiError.sourceUnavailable("未找到支持原生链接的飞书客户端，请先安装飞书。"))
                return
            }
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) {
                _, error in completion(error)
            }
        }
    }
}
