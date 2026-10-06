import Foundation

struct WebHTTPRequest {
    let method: String
    let target: String
    let version: String
    let headers: [String: String]
    let body: Data
}

enum WebRequestParseResult {
    case incomplete
    case request(WebHTTPRequest)
    case invalid
}

/// A single bounded HTTP/1.1 request. Every response closes the connection.
enum WebRequestParser {
    static let maximumHeaderBytes = 16_384
    static let maximumBodyBytes = 8_192
    static let maximumRequestBytes = maximumHeaderBytes + maximumBodyBytes

    static func parse(_ data: Data) -> WebRequestParseResult {
        guard data.count <= maximumRequestBytes else { return .invalid }
        let separator = Data("\r\n\r\n".utf8)
        guard let boundary = data.range(of: separator) else {
            return data.count < maximumHeaderBytes ? .incomplete : .invalid
        }
        guard boundary.lowerBound <= maximumHeaderBytes,
            let text = String(data: data[..<boundary.lowerBound], encoding: .utf8),
            !text.contains("\0")
        else { return .invalid }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .invalid }
        let parts = first.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "HTTP/1.1",
            !parts[0].isEmpty, parts[1].hasPrefix("/"),
            !parts[1].hasPrefix("//"),
            !parts[1].contains("#"),
            parts[1].unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 })
        else { return .invalid }
        var headers: [String: String] = [:]
        let tokenCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = String(line[..<colon])
            guard !name.isEmpty,
                name.unicodeScalars.allSatisfy({ tokenCharacters.contains($0) })
            else { return .invalid }
            let key = name.lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard headers[key] == nil,
                value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) })
            else { return .invalid }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil else { return .invalid }
        var bodyLength = 0
        if let length = headers["content-length"] {
            guard !length.isEmpty,
                length.allSatisfy({ $0.isASCII && $0.isNumber }),
                let parsed = Int(length), parsed <= maximumBodyBytes
            else { return .invalid }
            bodyLength = parsed
        }
        let available = data.count - boundary.upperBound
        guard available >= bodyLength else { return .incomplete }
        // Reject pipelining and unexpected bytes instead of reinterpreting them.
        guard available == bodyLength else { return .invalid }
        return .request(
            WebHTTPRequest(
                method: String(parts[0]), target: String(parts[1]),
                version: String(parts[2]), headers: headers,
                body: data[boundary.upperBound...]))
    }
}

struct WebHTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func text(_ status: Int, _ body: String) -> WebHTTPResponse {
        WebHTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    func encoded() -> Data {
        let reasons = [
            200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
            405: "Method Not Allowed", 408: "Request Timeout", 413: "Payload Too Large",
            500: "Internal Server Error",
        ]
        let policy =
            "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self'; font-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        let head =
            "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Security-Policy: \(policy)\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\nCross-Origin-Resource-Policy: same-origin\r\nPermissions-Policy: camera=(), microphone=(), geolocation=()\r\n\r\n"
        var result = Data(head.utf8)
        result.append(body)
        return result
    }
}

final class WebRequestRouter {
    private let port: UInt16
    private let token: String
    private let getSnapshot: () throws -> Data
    private let setFavorite: (String, Bool) throws -> Void
    private let setCompleted: (String, Bool) throws -> Void
    private let openSession: (String) throws -> Void

    init(
        port: UInt16, token: String, getSnapshot: @escaping () throws -> Data,
        setFavorite: @escaping (String, Bool) throws -> Void,
        setCompleted: @escaping (String, Bool) throws -> Void = { _, _ in
            throw HuantaiWebOpenError.unavailable
        },
        openSession: @escaping (String) throws -> Void = { _ in throw HuantaiWebOpenError.unavailable }
    ) {
        self.port = port
        self.token = token
        self.getSnapshot = getSnapshot
        self.setFavorite = setFavorite
        self.setCompleted = setCompleted
        self.openSession = openSession
    }

    func response(to request: WebHTTPRequest) -> WebHTTPResponse {
        guard isLocalRequest(request) else { return .text(403, "仅允许本机访问。") }
        switch (request.method, request.target) {
        case ("GET", "/"), ("GET", "/index.html"):
            guard request.body.isEmpty else { return .text(400, "请求无效。") }
            return WebHTTPResponse(
                status: 200, contentType: "text/html; charset=utf-8",
                body: Data(WebAssets.html.replacingOccurrences(of: "__CSRF_TOKEN__", with: token).utf8))
        case ("GET", "/assets/app.css"):
            return WebHTTPResponse(
                status: 200, contentType: "text/css; charset=utf-8", body: Data(WebAssets.css.utf8))
        case ("GET", "/assets/app.js"):
            return WebHTTPResponse(
                status: 200, contentType: "text/javascript; charset=utf-8",
                body: Data(WebAssets.javascript.utf8))
        case ("GET", "/api/snapshot"):
            guard request.body.isEmpty else { return .text(400, "请求无效。") }
            do {
                return WebHTTPResponse(
                    status: 200, contentType: "application/json; charset=utf-8", body: try getSnapshot())
            } catch {
                return .text(500, "索引读取失败，请检查 App 中的来源状态。")
            }
        case ("GET", "/assets/model.js"):
            return WebHTTPResponse(
                status: 200, contentType: "text/javascript; charset=utf-8",
                body: Data(WebAssets.modelJavascript.utf8))
        case ("POST", "/api/open"):
            guard secureEqual(request.headers["x-huantai-csrf"] ?? "", token),
                request.headers["content-type"]?.split(separator: ";").first?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
            else { return .text(403, "请求校验失败。") }
            struct OpenRequest: Decodable { let id: String }
            guard let value = try? JSONDecoder().decode(OpenRequest.self, from: request.body),
                !value.id.isEmpty, value.id.utf8.count <= 512,
                !value.id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { return .text(400, "会话参数无效。") }
            do {
                try openSession(value.id)
                return WebHTTPResponse(
                    status: 200, contentType: "application/json; charset=utf-8",
                    body: Data("{\"ok\":true}".utf8))
            } catch { return .text(400, "来源应用未能打开该会话，请检查 App 中的来源状态。") }
        case ("POST", "/api/favorite"), ("POST", "/api/completion"):
            guard secureEqual(request.headers["x-huantai-csrf"] ?? "", token),
                request.headers["content-type"]?.split(separator: ";").first?
                    .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
            else { return .text(403, "请求校验失败。") }
            struct FavoriteMutation: Decodable {
                let id: String
                let value: Bool
            }
            guard let mutation = try? JSONDecoder().decode(FavoriteMutation.self, from: request.body),
                !mutation.id.isEmpty, mutation.id.utf8.count <= 512,
                !mutation.id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { return .text(400, "状态参数无效。") }
            do {
                if request.target == "/api/completion" {
                    try setCompleted(mutation.id, mutation.value)
                } else {
                    try setFavorite(mutation.id, mutation.value)
                }
                return WebHTTPResponse(
                    status: 200, contentType: "application/json; charset=utf-8",
                    body: Data("{\"ok\":true}".utf8))
            } catch {
                return .text(400, "状态更新失败，请刷新会话列表后重试。")
            }
        default:
            if ["/api/favorite", "/api/completion", "/api/snapshot", "/api/open"].contains(request.target) {
                return .text(405, "请求方法不支持。")
            }
            return .text(404, "页面不存在。")
        }
    }

    private func isLocalRequest(_ request: WebHTTPRequest) -> Bool {
        let hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard request.version == "HTTP/1.1",
            let host = request.headers["host"]?.lowercased(), hosts.contains(host)
        else { return false }
        if let origin = request.headers["origin"] {
            guard origin == "http://\(host)" else { return false }
        }
        if let site = request.headers["sec-fetch-site"]?.lowercased(),
            site != "same-origin" && site != "none"
        {
            return false
        }
        return true
    }

    private func secureEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private enum HuantaiWebOpenError: Error { case unavailable }
