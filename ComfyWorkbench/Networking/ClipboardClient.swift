import Foundation
import CryptoKit

public struct ClipboardInput: Codable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var text: String?
    public var data: String?
    public var createdAt: Int64
    public init(id: String = UUID().uuidString.lowercased(), kind: String, text: String? = nil, data: String? = nil, createdAt: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) {
        self.id = id; self.kind = kind; self.text = text; self.data = data; self.createdAt = createdAt
    }
    public var digest: String { SHA256.hash(data: Data((kind + ":" + (kind == "text" ? text ?? "" : data ?? "")).utf8)).map { String(format: "%02x", $0) }.joined() }
    public var byteCost: Int { (text?.utf8.count ?? 0) + (data?.utf8.count ?? 0) }
    public func validate() throws {
        guard UUID(uuidString: id) != nil else { throw ClipboardFailure("内容编号无效") }
        if kind == "text" {
            guard let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 256 * 1024, data == nil else { throw ClipboardFailure("文字为空或超过 256 KB") }
        } else if kind == "image" {
            guard text == nil, let encoded = data, encoded.utf8.count <= 6_990_508, let bytes = Data(base64Encoded: encoded), bytes.count >= 24, bytes.count <= 5 * 1024 * 1024,
                  Array(bytes.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw ClipboardFailure("图片必须是 5 MB 以内的 PNG") }
            let b = [UInt8](bytes.prefix(24)); let width = b[16..<20].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }; let height = b[20..<24].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 24_000_000 else { throw ClipboardFailure("图片尺寸超过限制") }
        } else { throw ClipboardFailure("不支持这种剪贴板内容") }
    }
}
public struct ClipboardEntry: Codable, Equatable, Identifiable {
    public var id: String
    public var sequence: Int64
    public var deviceId: String
    public var deviceName: String
    public var kind: String
    public var text: String?
    public var data: String?
    public var createdAt: Int64
    public var input: ClipboardInput { ClipboardInput(id: id, kind: kind, text: text, data: data, createdAt: createdAt) }
    public var date: Date { Date(timeIntervalSince1970: Double(createdAt) / 1000) }
}
public struct ClipboardProfile: Codable, Equatable {
    public var lanURL: String
    public var publicURL: String
    public var deviceName: String
    public var hubId: String
    public var deviceId: String
    public var tokenKey: String
    public init(lanURL: String, publicURL: String, deviceName: String, hubId: String, deviceId: String, tokenKey: String = "clipboard-" + UUID().uuidString) {
        self.lanURL = lanURL; self.publicURL = publicURL; self.deviceName = deviceName; self.hubId = hubId; self.deviceId = deviceId; self.tokenKey = tokenKey
    }
}
public struct ClipboardBatch: Codable {
    public var items: [ClipboardEntry]
    public var cursor: Int64
    public var hasMore: Bool
    public var reset: Bool
}
public struct ClipboardCredentials: Codable { public let hubId: String; public let deviceId: String; public let token: String }
public struct ClipboardReceipt: Codable { public let id: String; public let sequence: Int64 }
public struct ClipboardHubInfo: Codable { public let hubId: String; public let protocolVersion: Int }
public struct ClipboardFailure: LocalizedError {
    public let message: String
    public let status: Int?
    public init(_ message: String, status: Int? = nil) { self.message = message; self.status = status }
    public var errorDescription: String? { message }
}

public enum ClipboardEndpoint {
    public static func url(_ input: String, publicAddress: Bool) throws -> URL {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: value), let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { throw ClipboardFailure("请填写不含密码和查询参数的完整地址") }
        let scheme = parts.scheme?.lowercased()
        if publicAddress && scheme != "https" { throw ClipboardFailure("公网地址必须使用 HTTPS") }
        guard scheme == "https" || (scheme == "http" && isLocal(host)) else { throw ClipboardFailure("HTTP 仅用于可信局域网 IP、localhost 或 .local 地址") }
        if !parts.path.hasSuffix("/") { parts.path += "/" }
        guard let url = parts.url else { throw ClipboardFailure("地址格式无效") }; return url
    }
    private static func isLocal(_ input: String) -> Bool {
        let host = input.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
        if host.contains(":"), host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef:").contains($0) }), (host.hasPrefix("fd") || host.hasPrefix("fc") || host.hasPrefix("fe80:")) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let b = parts.compactMap { UInt8($0) }; guard b.count == 4 else { return false }
        return b[0] == 10 || b[0] == 127 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 100 && (64...127).contains(b[1]))
    }
}

private final class ClipboardRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor ClipboardClient {
    private let session: URLSession
    private var cached: (url: URL, route: String, key: String, date: Date)?
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 20
        session = URLSession(configuration: configuration, delegate: ClipboardRedirectGuard(), delegateQueue: nil)
    }
    public func reset() { cached = nil }
    public func pair(address: String, code: String, name: String) async throws -> ClipboardCredentials {
        let url = try ClipboardEndpoint.url(address, publicAddress: false)
        let info: ClipboardHubInfo = try await call(url, "v1/info", timeout: 3)
        guard info.protocolVersion == 1 else { throw ClipboardFailure("同步中心版本不兼容") }
        struct Pair: Encodable { let code: String; let deviceName: String }
        let body = try JSONEncoder().encode(Pair(code: code.trimmingCharacters(in: .whitespacesAndNewlines), deviceName: name.trimmingCharacters(in: .whitespacesAndNewlines)))
        let credentials: ClipboardCredentials = try await call(url, "v1/pair", body: body)
        guard credentials.hubId == info.hubId, UUID(uuidString: credentials.deviceId) != nil, credentials.token.count == 64 else { throw ClipboardFailure("配对响应无效，请检查中心地址") }
        cached = nil; return credentials
    }
    public func select(_ profile: ClipboardProfile) async throws -> (URL, String) {
        let key = profile.hubId + "|" + profile.lanURL + "|" + profile.publicURL
        if let cached = cached, cached.key == key, Date().timeIntervalSince(cached.date) < 15 { return (cached.url, cached.route) }
        var reason = "同步中心暂不可达，内容已保留"
        for (address, isPublic, label) in [(profile.lanURL, false, "局域网直连"), (profile.publicURL, true, "公网 HTTPS")] where !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let url = try ClipboardEndpoint.url(address, publicAddress: isPublic)
                let info: ClipboardHubInfo = try await call(url, "v1/info", timeout: 1.8)
                guard info.hubId == profile.hubId, info.protocolVersion == 1 else { reason = "地址指向另一台中心，已停止向它发送凭据"; continue }
                cached = (url, label, key, Date()); return (url, label)
            } catch let error as ClipboardFailure { reason = error.message }
            catch { reason = "同步中心暂不可达，内容已保留" }
        }
        cached = nil; throw ClipboardFailure(reason)
    }
    public func send(_ item: ClipboardInput, profile: ClipboardProfile, token: String) async throws -> (ClipboardReceipt, String) {
        do { let (url, route) = try await select(profile); let result: ClipboardReceipt = try await call(url, "v1/clips", body: JSONEncoder().encode(item), token: token); return (result, route) }
        catch { cached = nil; throw error }
    }
    public func changes(after: Int64, profile: ClipboardProfile, token: String) async throws -> (ClipboardBatch, String) {
        do { let (url, route) = try await select(profile); let result: ClipboardBatch = try await call(url, "v1/changes?after=\(after)", token: token); return (result, route) }
        catch { cached = nil; throw error }
    }
    private func call<T: Decodable>(_ root: URL, _ path: String, body: Data? = nil, token: String? = nil, timeout: TimeInterval = 14) async throws -> T {
        guard let url = URL(string: path, relativeTo: root)?.absoluteURL else { throw ClipboardFailure("地址无效") }
        var request = URLRequest(url: url); request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body = body { request.httpMethod = "POST"; request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 20 * 1024 * 1024, let http = response as? HTTPURLResponse else { throw ClipboardFailure("同步响应过大或无效") }
        guard !(300..<400).contains(http.statusCode) else { throw ClipboardFailure("地址跳转或需要网页验证，请检查地址后重试") }
        guard http.mimeType == "application/json" else { throw ClipboardFailure("返回了网页，请检查地址或完成外网验证") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let reason = (try? JSONDecoder().decode(ErrorBody.self, from: data).error) ?? "同步请求失败"
            throw ClipboardFailure(reason, status: http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

public struct ClipboardArchive: Codable {
    public var profile: ClipboardProfile?
    public var cursor: Int64 = 0
    public var initialized = false
    public var autoSend = false
    public var autoReceive = false
    public var lastDigest = ""
    public var outbox: [ClipboardInput] = []
    public var history: [ClipboardEntry] = []
    public init() {}
    public mutating func enqueue(_ input: ClipboardInput, force: Bool = false) throws {
        try input.validate()
        if !force && input.digest == lastDigest { return }
        guard outbox.count < 30, outbox.reduce(input.byteCost, { $0 + $1.byteCost }) <= 32 * 1024 * 1024 else { throw ClipboardFailure("待发送已满，请连接后重试或移除旧内容") }
        outbox.append(input); lastDigest = input.digest
    }
    public mutating func merge(_ batch: ClipboardBatch) throws {
        guard batch.cursor >= cursor, batch.items.count <= 100, batch.items.allSatisfy({ $0.sequence > cursor && $0.sequence <= batch.cursor }) else { throw ClipboardFailure("同步序号无效，请重新配对") }
        for entry in batch.items { try entry.input.validate() }
        var bySequence = Dictionary(history.map { ($0.sequence, $0) }, uniquingKeysWith: { _, new in new })
        for entry in batch.items { bySequence[entry.sequence] = entry }
        history = Array(bySequence.values.sorted { $0.sequence > $1.sequence }.prefix(100))
        while history.reduce(0, { $0 + $1.input.byteCost }) > 32 * 1024 * 1024 { history.removeLast() }
        cursor = batch.cursor
        if !batch.hasMore { initialized = true }
    }
}
