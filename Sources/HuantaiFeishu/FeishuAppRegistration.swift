import Foundation
import zlib

/// The same RFC 8628 registration protocol used by Botmux's official SDK path.
/// The confirmation page creates/publishes the bot; credentials never leave the local store.
public struct FeishuRegistrationChallenge: Codable, Sendable {
    let deviceCode: String
    public let verificationURL: URL
    public let expiresAt: Date
    public let interval: TimeInterval
}

public struct FeishuRegistrationProgress: Sendable {
    public let challenge: FeishuRegistrationChallenge
    public let resumed: Bool
}

struct FeishuRegisteredApp {
    let appID: String
    let secret: String
}

enum FeishuRegistrationPoll {
    case pending(slowDown: Bool)
    case registered(FeishuRegisteredApp)
}

public final class FeishuAppRegistration: @unchecked Sendable {
    public static let requiredScopes = ["im:message.p2p_msg:readonly", "im:message:send_as_bot"]
    private let configuration: FeishuBotConfiguration
    private let session: URLSession
    private static let endpoint = URL(string: "https://accounts.feishu.cn/oauth/v1/app/registration")!

    public init(configuration: FeishuBotConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    public func begin(name: String = "换台状态助手", now: Date = .now) async throws -> FeishuRegistrationProgress {
        guard try configuration.binding() == nil else {
            throw FeishuBotError.message("已绑定机器人。使用 ht bot status 查看；要创建另一个，请先明确解绑。")
        }
        if let pending = try configuration.registrationChallenge() {
            guard pending.expiresAt > now else {
                try configuration.clearRegistration(deviceCode: pending.deviceCode)
                throw FeishuBotError.message("上次创建链接已过期。若此前已确认创建，请先检查应用是否存在；再次运行 ht bot create 可重新发起。")
            }
            return .init(challenge: pending, resumed: true)
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw FeishuBotError.message("机器人名称需要1至60个字符。") }
        let response = try await request([
            "action": "begin", "archetype": "PersonalAgent", "auth_method": "client_secret",
            "request_user_info": "open_id",
        ])
        guard let code = response.deviceCode, !code.isEmpty, code.count <= 4096,
            let rawURL = response.verificationURIComplete,
            var url = URLComponents(string: rawURL), url.scheme == "https",
            ["open.feishu.cn", "accounts.feishu.cn"].contains(url.host ?? ""),
            url.port == nil || url.port == 443, url.user == nil, url.password == nil,
            let expiry = response.expiresIn, expiry > 0, expiry <= 3600
        else { throw FeishuBotError.message("飞书没有返回有效的应用创建链接。") }
        var query = url.queryItems ?? []
        let additions = [
            "from": "sdk", "source": "node-sdk/huantai", "tp": "sdk", "createOnly": "true",
            "name": name, "desc": "换台的个人额度与会话状态看板。", "addons": try Self.encodedAddons(),
        ]
        query.removeAll { additions[$0.name] != nil }
        query += additions.keys.sorted().map { URLQueryItem(name: $0, value: additions[$0]) }
        url.queryItems = query
        guard let verificationURL = url.url else { throw FeishuBotError.message("无法生成应用创建链接。") }
        let challenge = FeishuRegistrationChallenge(
            deviceCode: code, verificationURL: verificationURL,
            expiresAt: now.addingTimeInterval(expiry), interval: min(30, max(1, response.interval ?? 5)))
        let saved = try configuration.saveRegistration(challenge)
        return .init(challenge: saved, resumed: saved.deviceCode != code)
    }

    public func finish(
        _ challenge: FeishuRegistrationChallenge,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) async throws -> FeishuBotBinding {
        var interval = challenge.interval
        while Date() < challenge.expiresAt {
            try Task.checkCancellation()
            let result: FeishuRegistrationPoll
            do { result = try await poll(challenge) } catch {
                // The challenge remains private and resumable after network errors. Never
                // begin another registration automatically: the app may already exist.
                throw error
            }
            switch result {
            case .pending(let slowDown):
                if slowDown { interval = min(60, interval + 5) }
                try await sleep(interval)
            case .registered(let app):
                try Task.checkCancellation()
                return try configuration.completeRegistration(
                    deviceCode: challenge.deviceCode, appID: app.appID, secret: app.secret)
            }
        }
        try configuration.clearRegistration(deviceCode: challenge.deviceCode)
        throw FeishuBotError.message("应用创建链接已过期，请重新运行 ht bot create。")
    }

    func poll(_ challenge: FeishuRegistrationChallenge) async throws -> FeishuRegistrationPoll {
        let response = try await request(["action": "poll", "device_code": challenge.deviceCode])
        if let appID = response.clientID, let secret = response.clientSecret {
            guard appID.range(of: "^cli_[A-Za-z0-9]+$", options: .regularExpression) != nil,
                !secret.isEmpty, secret.count <= 512,
                response.userInfo?.tenantBrand != "lark"
            else { throw FeishuBotError.message("飞书返回的应用凭据或租户类型无效，本地绑定未更改。") }
            return .registered(.init(appID: appID, secret: secret))
        }
        switch response.error {
        case "authorization_pending": return .pending(slowDown: false)
        case "slow_down": return .pending(slowDown: true)
        case "access_denied", "expired_token":
            try configuration.clearRegistration(deviceCode: challenge.deviceCode)
            throw FeishuBotError.message(response.error == "access_denied" ? "已取消应用创建。" : "应用创建链接已过期。")
        default: throw FeishuBotError.message("飞书应用创建尚未完成。再次运行 ht bot create 将继续同一次创建，不会另建应用。")
        }
    }

    private struct Response: Decodable {
        var deviceCode: String?
        var verificationURIComplete: String?
        var expiresIn: Double?
        var interval: Double?
        var clientID: String?
        var clientSecret: String?
        var userInfo: UserInfo?
        var error: String?
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code"
            case verificationURIComplete = "verification_uri_complete"
            case expiresIn = "expires_in"
            case interval
            case clientID = "client_id"
            case clientSecret = "client_secret"
            case userInfo = "user_info"
            case error
        }
        struct UserInfo: Decodable {
            var tenantBrand: String?
            enum CodingKeys: String, CodingKey { case tenantBrand = "tenant_brand" }
        }
    }

    private func request(_ fields: [String: String]) async throws -> Response {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(
            fields.keys.sorted().map {
                $0 + "=" + fields[$0]!.addingPercentEncoding(withAllowedCharacters: allowed)!
            }.joined(separator: "&").utf8)
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                (200..<500).contains(http.statusCode), data.count <= 64 * 1024,
                let parsed = try? JSONDecoder().decode(Response.self, from: data)
            else { throw FeishuBotError.message("飞书应用创建请求失败，未重新创建应用。") }
            return parsed
        } catch is CancellationError { throw CancellationError() } catch let error as FeishuBotError {
            throw error
        } catch { throw FeishuBotError.message("连接飞书应用创建服务失败。再次运行 ht bot create 可继续，凭据不会显示在日志中。") }
    }

    static func encodedAddons() throws -> String {
        let object: [String: Any] = [
            "preset": false,
            "scopes": ["tenant": requiredScopes, "user": [String]()],
            "events": ["items": ["tenant": ["im.message.receive_v1"], "user": [String]()]],
            "callbacks": ["items": ["card.action.trigger"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var stream = z_stream()
        guard
            deflateInit2_(
                &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw FeishuBotError.message("无法生成机器人配置。") }
        defer { deflateEnd(&stream) }
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))))
        let result = data.withUnsafeBytes { input in
            output.withUnsafeMutableBytes { buffer in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(data.count)
                stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(buffer.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard result == Z_STREAM_END else { throw FeishuBotError.message("无法压缩机器人配置。") }
        return Data(output.prefix(Int(stream.total_out))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
