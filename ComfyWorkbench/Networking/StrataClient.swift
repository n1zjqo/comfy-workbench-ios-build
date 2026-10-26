import Foundation

public struct StrataProfile: Codable, Equatable {
    public var lanURL = ""
    public var publicURL = ""
    public var serverID = ""
    public var tokenKey = "strata-" + UUID().uuidString
    public init() {}
}
public struct StrataInfo: Codable, Equatable {
    public var protocolVersion: Int
    public var service: String
    public var serverId: String
    public var name: String
}
public struct StrataStatus: Codable, Equatable {
    public var online: Bool
    public var loaded: Bool
    public var paused: Bool
    public var activeRequests: Int
    public var maintenance: Bool
    public var inFlight: Int
    public var model: String
    public var gpu: [String: Double]
    public var title: String {
        if paused { return loaded ? "已暂停 · 等待释放资源" : "已暂停 · 需手动恢复" }
        if !online { return "推理服务离线" }
        if maintenance { return "正在切换模型" }
        if activeRequests > 0 || inFlight > 0 { return "正在处理任务" }
        return loaded ? "已就绪" : "显存已释放 · 可自动唤醒"
    }
}
public struct StrataMessage: Codable, Equatable, Identifiable {
    public var id = UUID()
    public var role: String
    public var content: String
    public var image: Data?
    public init(role: String, content: String, image: Data? = nil) { self.role = role; self.content = content; self.image = image }
}
public struct StrataPending: Codable, Equatable {
    public var id: String
    public var tool: String
    public var arguments: [String: String]
    public var callId: String
}
public struct StrataTask: Codable, Equatable, Identifiable {
    public var id: String
    public var state: String
    public var title: String
    public var events: [String]
    public var output: String
    public var pending: StrataPending?
    public var step: Int
    public var finished: Bool { ["completed", "cancelled", "failed"].contains(state) }
    public var stateLabel: String { ["running": "执行中", "approval": "等待你确认", "completed": "已完成", "cancelled": "已取消", "failed": "未完成"][state] ?? state }
}
public struct StrataFailure: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
private final class StrataRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public actor StrataClient {
    private let session: URLSession
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: StrataRedirectGuard(), delegateQueue: nil)
    }
    public func select(_ profile: StrataProfile, allowUnpaired: Bool = false) async throws -> (URL, String, StrataInfo) {
        guard allowUnpaired || !profile.serverID.isEmpty else { throw StrataFailure("请先在连接页设置办公室 Strata") }
        var last: Error = StrataFailure("请填写办公室 Strata 地址")
        for (address, internet, route) in [(profile.lanURL, false, "办公室局域网"), (profile.publicURL, true, "办公室公网 HTTPS")] where !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                let url = try ClipboardEndpoint.url(address, publicAddress: internet)
                let info: StrataInfo = try await call(url, "workbench/info", timeout: internet ? 8 : 2)
                guard info.protocolVersion == 1, info.service == "strata-workbench", UUID(uuidString: info.serverId) != nil else { throw StrataFailure("此地址不是办公室 Strata 控制桥") }
                guard profile.serverID.isEmpty || info.serverId == profile.serverID else { throw StrataFailure("地址指向另一台设备，已停止发送密钥") }
                return (url, route, info)
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw error }
            catch { last = error }
        }
        throw last
    }
    public func pair(_ profile: StrataProfile, key: String) async throws -> (StrataProfile, StrataStatus, String) {
        let (url, route, info) = try await select(profile, allowUnpaired: true)
        let state: StrataStatus = try await call(url, "workbench/status", key: key)
        var pinned = profile; pinned.serverID = info.serverId
        return (pinned, state, route)
    }
    public func status(_ profile: StrataProfile, key: String) async throws -> (StrataStatus, String) {
        let (url, route, _) = try await select(profile)
        return (try await call(url, "workbench/status", key: key), route)
    }
    public func control(_ action: String, profile: StrataProfile, key: String) async throws -> StrataStatus {
        guard ["load", "release", "pause", "resume", "reload", "free_comfy"].contains(action) else { throw StrataFailure("未知操作") }
        let (url, _, _) = try await select(profile)
        // Never retry state-changing requests on another route: the first may have succeeded.
        return try await call(url, "workbench/control", key: key, body: ["action": action], timeout: 620)
    }
    public func task(prompt: String, profile: StrataProfile, key: String) async throws -> StrataTask {
        let (url, _, _) = try await select(profile)
        return try await call(url, "workbench/tasks", key: key, body: ["prompt": prompt])
    }
    public func task(id: String, action: String? = nil, approvalID: String? = nil, profile: StrataProfile, key: String) async throws -> StrataTask {
        guard UUID(uuidString: id) != nil else { throw StrataFailure("任务编号无效") }
        let (url, _, _) = try await select(profile)
        var body: [String: Any]? = nil
        if let action = action { body = ["action": action]; if let approvalID = approvalID { body?["approvalId"] = approvalID } }
        return try await call(url, "workbench/tasks/" + id, key: key, body: body)
    }
    public func chat(_ messages: [StrataMessage], model: String, profile: StrataProfile, key: String, onText: @escaping @Sendable (String) async -> Void) async throws {
        let (url, _, _) = try await select(profile)
        let wire: [[String: Any]] = messages.map { message in
            if let image = message.image {
                return ["role": message.role, "content": [["type": "text", "text": message.content], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + image.base64EncodedString()]]]]
            }
            return ["role": message.role, "content": message.content]
        }
        let body: [String: Any] = ["model": model, "messages": wire, "stream": true, "max_tokens": 8192]
        let request = try makeRequest(url, "v1/chat/completions", key: key, body: body, timeout: 620)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw StrataFailure("服务器未返回有效响应") }
        guard http.statusCode == 200, http.mimeType == "text/event-stream" else {
            throw StrataFailure(http.statusCode == 423 ? "Strata 已暂停，请先手动恢复" : "对话未开始（\(http.statusCode)），请检查状态或完成网页验证；未自动重发")
        }
        var output = "", done = false, lastPush = Date.distantPast, received = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            received += line.utf8.count
            guard received < 8_000_000 else { throw StrataFailure("回答超过大小限制") }
            guard line.hasPrefix("data:") else { continue }
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if data == "[DONE]" { done = true; break }
            guard let value = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { continue }
            if value["error"] != nil { throw StrataFailure("模型生成未完成") }
            if let choice = (value["choices"] as? [[String: Any]])?.first {
                if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String { output += text }
                if let reason = choice["finish_reason"] as? String, !reason.isEmpty { done = true }
            }
            if Date().timeIntervalSince(lastPush) > 0.08 { await onText(output); lastPush = Date() }
        }
        await onText(output)
        guard done else { throw StrataFailure("连接中断，已保留收到的回答；未自动重发") }
    }
    private func makeRequest(_ root: URL, _ path: String, key: String?, body: [String: Any]?, timeout: Double) throws -> URLRequest {
        var request = URLRequest(url: root.appendingPathComponent(path)); request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = key { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            guard request.httpBody!.count <= 12 * 1024 * 1024 else { throw StrataFailure("会话过大，请开始新对话") }
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
    private func call<T: Decodable>(_ root: URL, _ path: String, key: String? = nil, body: [String: Any]? = nil, timeout: Double = 20) async throws -> T {
        let (data, response) = try await session.data(for: makeRequest(root, path, key: key, body: body, timeout: timeout))
        guard let http = response as? HTTPURLResponse, data.count <= 12 * 1024 * 1024 else { throw StrataFailure("响应无效或过大") }
        guard http.mimeType == "application/json", !(300..<400).contains(http.statusCode) else { throw StrataFailure("需要网页验证，请在设置中打开公网验证，返回后重试") }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw StrataFailure(message ?? "请求失败（\(http.statusCode)），未自动重试")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
