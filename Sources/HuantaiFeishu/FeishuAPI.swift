import Foundation

actor FeishuAPI {
    private let appID: String
    private let secret: String
    private let session: URLSession
    private var token: String?
    private var tokenExpiry = Date.distantPast
    static let origin = URL(string: "https://open.feishu.cn")!

    init(appID: String, secret: String, session: URLSession = .shared) {
        self.appID = appID
        self.secret = secret
        self.session = session
    }

    func validate() async throws { _ = try await accessToken() }

    struct Endpoint {
        var url: URL
        var service: UInt64
        var pingInterval: Double
    }
    func endpoint() async throws -> Endpoint {
        let response = try await request(
            path: "/callback/ws/endpoint", body: ["AppID": appID, "AppSecret": secret])
        guard let data = response["data"] as? [String: Any], let value = data["URL"] as? String,
            let url = URL(string: value), url.scheme == "wss", let host = url.host,
            host.hasSuffix(".feishu.cn") || host.hasSuffix(".larksuite.com"),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let serviceValue = components.queryItems?.first(where: { $0.name == "service_id" })?.value,
            let service = UInt64(serviceValue)
        else {
            throw FeishuBotError.message("飞书没有返回有效的长连接地址。")
        }
        let config = data["ClientConfig"] as? [String: Any]
        let ping = (config?["PingInterval"] as? Double) ?? 120
        return Endpoint(url: url, service: service, pingInterval: min(300, max(5, ping)))
    }

    func send(_ item: FeishuOutboxItem) async throws {
        for attempt in 0...1 {
            let access = try await accessToken()
            let result = try await request(
                path: "/open-apis/im/v1/messages?receive_id_type=chat_id",
                body: [
                    "receive_id": item.chatID, "msg_type": "interactive", "content": item.card,
                    "uuid": item.id,
                ], token: access, checkCode: false)
            let code = result["code"] as? Int ?? -1
            if code == 0 { return }
            if attempt == 0 && [99_991_661, 99_991_663, 99_991_668].contains(code) {
                token = nil
                continue
            }
            throw FeishuBotError.message("飞书发卡失败（\(code)），请检查机器人消息权限和可用范围。")
        }
    }

    private func accessToken() async throws -> String {
        if let token, tokenExpiry > Date() { return token }
        let result = try await request(
            path: "/open-apis/auth/v3/tenant_access_token/internal",
            body: ["app_id": appID, "app_secret": secret])
        guard let token = result["tenant_access_token"] as? String, !token.isEmpty else {
            throw FeishuBotError.message("飞书认证未返回有效凭据。")
        }
        self.token = token
        tokenExpiry = Date().addingTimeInterval(max(0, (result["expire"] as? Double ?? 0) - 120))
        return token
    }

    private func request(path: String, body: [String: Any], token: String? = nil, checkCode: Bool = true)
        async throws -> [String: Any]
    {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.origin)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Huantai/0.2.3", forHTTPHeaderField: "User-Agent")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
            data.count <= 2 * 1024 * 1024,
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw FeishuBotError.message("飞书网络请求失败，请检查网络后重试。")
        }
        if checkCode, let code = result["code"] as? Int, code != 0 {
            throw FeishuBotError.message("飞书请求失败（\(code)），请检查应用凭据、权限及长连接配置。")
        }
        return result
    }
}

public enum FeishuBotSetup {
    public static func validate(appID: String, secret: String) async throws {
        try await FeishuAPI(
            appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: secret.trimmingCharacters(in: .whitespacesAndNewlines)
        ).validate()
    }
}
