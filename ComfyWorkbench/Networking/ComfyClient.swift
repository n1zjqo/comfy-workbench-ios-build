import Foundation

public struct ServerConfig: Codable, Equatable, Sendable {
    public var baseURL: String
    public var username: String
    public var passwordKey: String

    public init(baseURL: String = "", username: String = "", passwordKey: String = UUID().uuidString) {
        self.baseURL = baseURL
        self.username = username
        self.passwordKey = passwordKey
    }

    public func validatedBaseURL() throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else {
            throw ComfyAPIError(message: "请输入完整的 http:// 或 https:// 服务器地址；账号密码请填写在单独的输入框中，地址不要包含查询参数或 #。")
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw ComfyAPIError(message: "服务器端口必须在 1–65535 之间。")
        }
        guard !username.contains(":"), !username.contains("\r"), !username.contains("\n") else {
            throw ComfyAPIError(message: "Basic Auth 用户名不能包含冒号或换行。")
        }
        return url
    }

    /// On an iPhone, localhost points at that iPhone, not the ComfyUI computer.
    public var isLoopback: Bool {
        guard let host = URLComponents(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    public var isDDNSTO: Bool {
        guard let host = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return host == "ddnsto.com" || host.hasSuffix(".ddnsto.com")
    }
}

public struct ServerWorkflow: Identifiable, Sendable {
    public let path: String
    public let size: Int?
    public var id: String { path }
    public var name: String { (path as NSString).lastPathComponent }
}

public struct ComfyUser: Identifiable, Sendable {
    public let id: String
    public let name: String
}

public struct ComfyOutput: Codable, Hashable, Identifiable, Sendable {
    public var filename: String
    public var subfolder: String
    public var type: String
    public var nodeID: String?
    public var kind: String
    public var id: String { [nodeID ?? "", type, subfolder, filename].joined(separator: "|") }
    public var workflowInputPath: String { subfolder.isEmpty ? filename : "\(subfolder)/\(filename)" }

    public init(filename: String, subfolder: String = "", type: String = "output", nodeID: String? = nil, kind: String = "images") {
        self.filename = filename
        self.subfolder = subfolder
        self.type = type
        self.nodeID = nodeID
        self.kind = kind
    }
}

public struct PromptSubmission: Sendable {
    public let promptID: String
    public let number: Double?
    public let nodeErrors: Data?
}

public struct ComfyHistoryResult: Sendable {
    public let promptID: String
    public let completed: Bool
    public let status: String
    public let outputs: [ComfyOutput]
    public let textOutputs: [String]
    public let errorMessage: String?
    public let rawData: Data
    public var failed: Bool { status == "error" || status == "failed" || status == "interrupted" || errorMessage != nil }
}

public struct ComfyQueueItem: Sendable {
    public let promptID: String
    public let number: Double?
}

public struct ComfyQueue: Sendable {
    public let running: [ComfyQueueItem]
    public let pending: [ComfyQueueItem]
}

public struct ComfyEvent: Sendable {
    public var type: String
    public var promptID: String?
    public var nodeID: String?
    public var value: Double?
    public var maximum: Double?
    public var queueRemaining: Int?
    public var message: String?
    public var outputs: [ComfyOutput] = []
    public var previewData: Data?
    public var rawData: Data = Data()
}

public enum CancellationResult: Sendable {
    case removedFromQueue
    case alreadyFinished
    case runningCannotSafelyInterrupt
}

public struct ComfyAPIError: LocalizedError, Sendable {
    public let statusCode: Int?
    public let message: String
    public let nodeErrors: Data?
    public let requiresBrowserVerification: Bool

    public init(statusCode: Int? = nil, message: String, nodeErrors: Data? = nil, requiresBrowserVerification: Bool = false) {
        self.statusCode = statusCode
        self.message = message
        self.nodeErrors = nodeErrors
        self.requiresBrowserVerification = requiresBrowserVerification
    }

    public var errorDescription: String? { message }
}

/// Foreground network client. Persist prompt IDs in the app and query history after resuming.
/// A dropped socket does not mean a server-side generation has stopped.
public actor ComfyClient {
    private let config: ServerConfig
    private let password: String?
    private let session: URLSession
    private let sessionDelegate: ComfySessionDelegate
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<ComfyEvent, Error>.Continuation?
    private var streamID: UUID?

    public init(config: ServerConfig, password: String? = nil, sessionConfiguration: URLSessionConfiguration? = nil) {
        self.config = config
        self.password = password
        let settings = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 45
        settings.timeoutIntervalForResource = 180
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.httpCookieStorage = nil
        settings.urlCredentialStorage = nil
        let delegate = ComfySessionDelegate()
        self.sessionDelegate = delegate
        self.session = URLSession(configuration: settings, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        reader?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        continuation?.finish()
        session.invalidateAndCancel()
    }

    public func systemStats() async throws -> Data {
        let data = try await perform(request(path: ["system_stats"]))
        _ = try Self.dictionary(data)
        return data
    }

    public func objectInfo() async throws -> Data {
        let data = try await perform(request(path: ["object_info"]))
        _ = try Self.dictionary(data)
        return data
    }

    /// Reads ComfyUI's existing user profiles; never creates or changes one.
    public func workflowUsers() async throws -> [ComfyUser] {
        do {
            let data = try await perform(request(path: ["users"]))
            let value = try Self.dictionary(data)
            guard let users = value["users"] as? [String: String] else { return [] }
            return users.map { ComfyUser(id: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
        } catch let error as ComfyAPIError where error.statusCode == 404 { return [] }
    }

    public func serverWorkflows(userID: String? = nil) async throws -> [ServerWorkflow] {
        var req = try request(path: ["userdata"], query: [
            URLQueryItem(name: "dir", value: "workflows"), URLQueryItem(name: "recurse", value: "true"),
            URLQueryItem(name: "split", value: "false"), URLQueryItem(name: "full_info", value: "true")])
        try Self.setUser(userID, on: &req)
        let data: Data
        do { data = try await perform(req) }
        catch let error as ComfyAPIError where error.statusCode == 404 {
            throw ComfyAPIError(statusCode: 404, message: "服务器没有可读取的工作流目录，或未提供工作流接口。请先在 ComfyUI 的工作流列表中保存工作流，再刷新；也可以从文件导入。")
        }
        guard let records = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ComfyAPIError(message: "服务器没有返回工作流列表。")
        }
        var seen = Set<String>()
        return records.compactMap { record -> ServerWorkflow? in
            let info = record as? [String: Any]
            guard let path = (record as? String) ?? (info?["path"] as? String),
                  Self.validWorkflowPath(path), seen.insert(path).inserted else { return nil }
            return ServerWorkflow(path: path, size: (info?["size"] as? NSNumber)?.intValue)
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    public func serverWorkflow(path: String, userID: String? = nil) async throws -> Data {
        guard Self.validWorkflowPath(path) else { throw ComfyAPIError(message: "工作流路径无效，只能读取 workflows 中的 JSON 文件。") }
        var req = try request(path: ["userdata"])
        var components = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let encoded = ("workflows/" + path).addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ComfyAPIError(message: "无法编码工作流路径。")
        }
        // ComfyUI's {file} route takes the full relative path as one encoded segment.
        components.percentEncodedPath += "/" + encoded
        req.url = components.url
        try Self.setUser(userID, on: &req)
        let data = try await perform(req)
        guard data.count <= 12_000_000 else { throw ComfyAPIError(message: "工作流超过 12 MB，请导出不含预览图片的 JSON。") }
        return data
    }

    private static func validWorkflowPath(_ path: String) -> Bool {
        guard path.lowercased().hasSuffix(".json"), !path.contains("\\"), !path.contains("%"),
              !path.contains(":"), !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func setUser(_ id: String?, on request: inout URLRequest) throws {
        guard let id = id, !id.isEmpty else { return }
        guard !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ComfyAPIError(message: "ComfyUI 用户标识无效。")
        }
        request.setValue(id, forHTTPHeaderField: "comfy-user")
    }

    /// `prompt` is the API-format node dictionary, not a whole POST body or a UI workflow.
    public func submit(prompt: Data, clientID: String, extraData: Data? = nil) async throws -> PromptSubmission {
        let nodes = try Self.dictionary(prompt)
        let isNodeDictionary = !nodes.isEmpty && nodes.values.allSatisfy { value in
            guard let node = value as? [String: Any],
                  let classType = node["class_type"] as? String, !classType.isEmpty else { return false }
            return node["inputs"] is [String: Any]
        }
        guard isNodeDictionary else {
            throw ComfyAPIError(message: "提交内容必须是 ComfyUI API 格式的节点字典。")
        }
        guard !clientID.isEmpty else { throw ComfyAPIError(message: "缺少客户端标识。") }
        var payload: [String: Any] = ["prompt": nodes, "client_id": clientID]
        if let extraData = extraData { payload["extra_data"] = try Self.dictionary(extraData) }
        let responseData = try await perform(request(path: ["prompt"], method: "POST", json: payload))
        let response = try Self.dictionary(responseData)
        guard let promptID = response["prompt_id"] as? String, !promptID.isEmpty else {
            throw Self.serverError(status: 200, data: responseData, fallback: "服务器没有返回 prompt_id，无法追踪此任务。请先检查服务器队列，避免重复提交。")
        }
        return PromptSubmission(promptID: promptID, number: (response["number"] as? NSNumber)?.doubleValue,
                                nodeErrors: Self.jsonData(response["node_errors"]))
    }

    public func history(promptID: String) async throws -> ComfyHistoryResult? {
        try Self.validatePromptID(promptID)
        let data = try await perform(request(path: ["history", promptID]))
        let response = try Self.dictionary(data)
        guard let item = response[promptID] as? [String: Any] else { return nil }
        let status = item["status"] as? [String: Any] ?? [:]
        let statusString = status["status_str"] as? String ?? "unknown"
        let nodes = item["outputs"] as? [String: Any] ?? [:]
        var outputs: [ComfyOutput] = []
        var texts: [String] = []
        for nodeID in nodes.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let output = nodes[nodeID] as? [String: Any] else { continue }
            outputs.append(contentsOf: Self.parseOutputs(output, nodeID: nodeID))
            if let values = output["text"] as? [String] { texts.append(contentsOf: values) }
            else if let value = output["text"] as? String { texts.append(value) }
        }
        var errorMessage: String?
        var interrupted = false
        for entry in status["messages"] as? [[Any]] ?? [] {
            guard let type = entry.first as? String else { continue }
            if type == "execution_error", entry.count > 1, let details = entry[1] as? [String: Any] {
                errorMessage = Self.executionErrorMessage(details)
            } else if type == "execution_interrupted" {
                interrupted = true
                errorMessage = "任务已被服务器中断。"
            }
        }
        return ComfyHistoryResult(promptID: promptID, completed: status["completed"] as? Bool ?? false,
                                  status: interrupted ? "interrupted" : statusString,
                                  outputs: outputs, textOutputs: texts, errorMessage: errorMessage,
                                  rawData: Self.jsonData(item) ?? data)
    }

    public func queue() async throws -> ComfyQueue {
        let data = try await perform(request(path: ["queue"]))
        let response = try Self.dictionary(data)
        guard response["queue_running"] is [[Any]], response["queue_pending"] is [[Any]] else {
            throw ComfyAPIError(message: "服务器返回了无法识别的队列。")
        }
        return ComfyQueue(running: Self.parseQueue(response["queue_running"]),
                          pending: Self.parseQueue(response["queue_pending"]))
    }

    /// Recovers an accepted POST whose response was lost. A nil result is inconclusive:
    /// metadata may have been stripped or history pruned. The caller must not auto-resubmit.
    public func recoverPrompt(requestID: String) async throws -> String? {
        try Self.validatePromptID(requestID)
        let queueData = try await perform(request(path: ["queue"]))
        let queued = try Self.dictionary(queueData)
        var matches = Set<String>()
        for key in ["queue_running", "queue_pending"] {
            for tuple in queued[key] as? [[Any]] ?? [] {
                if let promptID = Self.matchRequestID(requestID, tuple: tuple) { matches.insert(promptID) }
            }
        }
        // Read history after queue, so a job finishing between snapshots is still recoverable.
        let historyData = try await perform(request(path: ["history"], query: [URLQueryItem(name: "max_items", value: "200")]))
        let recentHistory = try Self.dictionary(historyData)
        for value in recentHistory.values {
            guard let item = value as? [String: Any], let tuple = item["prompt"] as? [Any] else { continue }
            if let promptID = Self.matchRequestID(requestID, tuple: tuple) { matches.insert(promptID) }
        }
        guard matches.count <= 1 else {
            throw ComfyAPIError(message: "同一请求标识匹配到多个服务器任务，请检查 ComfyUI 队列；应用不会自动重新提交。")
        }
        return matches.first
    }

    public func uploadImage(data: Data, filename: String, mimeType: String = "image/jpeg", overwrite: Bool = false) async throws -> ComfyOutput {
        guard !data.isEmpty else { throw ComfyAPIError(message: "所选素材没有可上传的数据。") }
        let safeFilename = filename.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "image.jpg"
        guard !safeFilename.isEmpty, safeFilename != ".", safeFilename != "..",
              !safeFilename.contains("\r"), !safeFilename.contains("\n"), !safeFilename.contains("\""),
              mimeType.range(of: "^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$", options: .regularExpression) != nil else {
            throw ComfyAPIError(message: "素材文件名或 MIME 类型无效。")
        }
        let boundary = "ComfyWorkbench-" + UUID().uuidString
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(safeFilename)\"\r\nContent-Type: \(mimeType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\ninput")
        append("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\n\(overwrite ? "true" : "false")")
        append("\r\n--\(boundary)--\r\n")
        var uploadRequest = try request(path: ["upload", "image"], method: "POST")
        uploadRequest.timeoutInterval = 120
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = body
        let responseData = try await perform(uploadRequest)
        let result = try Self.dictionary(responseData)
        guard let name = result["name"] as? String, !name.isEmpty else {
            throw ComfyAPIError(message: "服务器没有返回上传后的图片文件名。")
        }
        return ComfyOutput(filename: name, subfolder: result["subfolder"] as? String ?? "",
                           type: result["type"] as? String ?? "input")
    }

    /// Use imageData to retain this client's redirect policy; do not send this request through an unrestricted session.
    public func imageRequest(for output: ComfyOutput) throws -> URLRequest {
        guard ["input", "output", "temp"].contains(output.type), !output.filename.isEmpty else {
            throw ComfyAPIError(message: "服务器输出的文件信息不完整。")
        }
        var result = try request(path: ["view"], query: [URLQueryItem(name: "filename", value: output.filename),
                                                       URLQueryItem(name: "subfolder", value: output.subfolder),
                                                       URLQueryItem(name: "type", value: output.type)])
        result.setValue("*/*", forHTTPHeaderField: "Accept")
        return result
    }

    public func imageData(for output: ComfyOutput) async throws -> Data {
        try await perform(imageRequest(for: output))
    }

    /// Deletes this ID only; there is deliberately no queue-wide clear operation.
    public func deleteQueuedPrompt(promptID: String) async throws {
        try Self.validatePromptID(promptID)
        _ = try await perform(request(path: ["queue"], method: "POST", json: ["delete": [promptID]]))
    }

    /// Old ComfyUI versions ignore `prompt_id` on /interrupt and interrupt someone else's job.
    /// Refuse that operation until a verifiable scoped-cancel capability is available.
    public func cancelPrompt(promptID: String) async throws -> CancellationResult {
        try Self.validatePromptID(promptID)
        let before = try await queue()
        if before.running.contains(where: { $0.promptID == promptID }) { return .runningCannotSafelyInterrupt }
        if before.pending.contains(where: { $0.promptID == promptID }) {
            try await deleteQueuedPrompt(promptID: promptID)
            let after = try await queue()
            if after.running.contains(where: { $0.promptID == promptID }) { return .runningCannotSafelyInterrupt }
            if after.pending.contains(where: { $0.promptID == promptID }) {
                throw ComfyAPIError(message: "任务仍在服务器队列中，取消未生效。")
            }
            if try await history(promptID: promptID) != nil { return .alreadyFinished }
            return .removedFromQueue
        }
        return .alreadyFinished
    }

    public func events(clientID: String) -> AsyncThrowingStream<ComfyEvent, Error> {
        disconnectEvents()
        let token = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(128)) { stream in
            do {
                guard !clientID.isEmpty else { throw ComfyAPIError(message: "缺少客户端标识。") }
                var socketRequest = try request(path: ["ws"], query: [URLQueryItem(name: "clientId", value: clientID)])
                guard let url = socketRequest.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                    throw ComfyAPIError(message: "WebSocket 地址无效。")
                }
                components.scheme = components.scheme?.lowercased() == "https" ? "wss" : "ws"
                socketRequest.url = components.url
                socketRequest.timeoutInterval = 30
                let socket = session.webSocketTask(with: socketRequest)
                self.socket = socket
                self.continuation = stream
                self.streamID = token
                socket.maximumMessageSize = 32 * 1024 * 1024
                socket.resume()
                self.reader = Task { [weak self] in
                    do {
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            if let event = try Self.parseEvent(message) { stream.yield(event) }
                        }
                        stream.finish()
                    } catch {
                        if Task.isCancelled { stream.finish() }
                        else { stream.finish(throwing: error) }
                    }
                    await self?.finishEvents(token: token)
                }
                stream.onTermination = { @Sendable [weak self] _ in
                    socket.cancel(with: .goingAway, reason: nil)
                    Task { await self?.finishEvents(token: token) }
                }
            } catch {
                stream.finish(throwing: error)
            }
        }
    }

    public func disconnectEvents() {
        streamID = nil
        reader?.cancel()
        reader = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        let stream = continuation
        continuation = nil
        stream?.finish()
    }

    private func finishEvents(token: UUID) {
        guard streamID == token else { return }
        disconnectEvents()
    }

    private func request(path: [String], method: String = "GET", query: [URLQueryItem] = [], json: [String: Any]? = nil) throws -> URLRequest {
        var url = try config.validatedBaseURL()
        // Appending components retains a reverse proxy prefix such as https://host/comfy/.
        for component in path { url.appendPathComponent(component) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ComfyAPIError(message: "服务器地址无效。")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let finalURL = components.url else { throw ComfyAPIError(message: "请求地址无效。") }
        var result = URLRequest(url: finalURL)
        result.httpMethod = method
        result.setValue("application/json", forHTTPHeaderField: "Accept")
        if !config.username.isEmpty {
            let credentials = Data("\(config.username):\(password ?? "")".utf8).base64EncodedString()
            result.setValue("Basic " + credentials, forHTTPHeaderField: "Authorization")
        }
        if let json = json {
            result.setValue("application/json", forHTTPHeaderField: "Content-Type")
            result.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        return result
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ComfyAPIError(message: "服务器没有返回 HTTP 响应。") }
        let prefix = String(decoding: data.prefix(1024), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isHTML = response.mimeType?.lowercased() == "text/html" || prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
        if config.isDDNSTO && ((300...399).contains(response.statusCode) || response.statusCode == 401 || response.statusCode == 403 || isHTML) {
            throw ComfyAPIError(statusCode: response.statusCode, message: "DDNSTO 连接需要检查网页验证。请点“去验证”，完成后关闭网页，App 会重新检查连接。", requiresBrowserVerification: true)
        }
        guard (200...299).contains(response.statusCode) else {
            let fallback: String
            if (300...399).contains(response.statusCode) {
                fallback = "服务器要求重定向。为避免把登录信息发往其他地址，请在连接设置中填写最终的 ComfyUI 地址。"
            } else if response.statusCode == 401 || response.statusCode == 403 {
                fallback = "服务器拒绝访问，请检查账号、密码和反向代理设置。"
            } else { fallback = "服务器请求失败（HTTP \(response.statusCode)）。" }
            throw Self.serverError(status: response.statusCode, data: data, fallback: fallback)
        }
        return data
    }

    private static func validatePromptID(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !value.isEmpty, value.count <= 256, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ComfyAPIError(message: "任务标识无效。")
        }
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ComfyAPIError(message: "服务器返回的 JSON 不是对象。")
            }
            return object
        } catch let error as ComfyAPIError { throw error }
        catch { throw ComfyAPIError(message: "无法读取服务器 JSON。请确认地址指向 ComfyUI 服务，而不是登录页面或其他网站。") }
    }

    private static func jsonData(_ value: Any?) -> Data? {
        guard let value = value, JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func parseQueue(_ value: Any?) -> [ComfyQueueItem] {
        (value as? [[Any]] ?? []).compactMap { tuple in
            guard tuple.count > 1, let id = tuple[1] as? String else { return nil }
            return ComfyQueueItem(promptID: id, number: (tuple[0] as? NSNumber)?.doubleValue)
        }
    }

    private static func matchRequestID(_ requestID: String, tuple: [Any]) -> String? {
        guard tuple.count > 3, let promptID = tuple[1] as? String,
              let extra = tuple[3] as? [String: Any], extra["ios_request_id"] as? String == requestID else { return nil }
        return promptID
    }

    private static func parseOutputs(_ value: [String: Any], nodeID: String?) -> [ComfyOutput] {
        var results: [ComfyOutput] = []
        for kind in value.keys.sorted() {
            let records: [[String: Any]]
            if let array = value[kind] as? [[String: Any]] { records = array }
            else if let item = value[kind] as? [String: Any] { records = [item] }
            else { continue }
            for record in records {
                guard let filename = record["filename"] as? String, !filename.isEmpty else { continue }
                results.append(ComfyOutput(filename: filename, subfolder: record["subfolder"] as? String ?? "",
                                           type: record["type"] as? String ?? "output", nodeID: nodeID, kind: kind))
            }
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0.id).inserted }
    }

    private static func parseEvent(_ message: URLSessionWebSocketTask.Message) throws -> ComfyEvent? {
        switch message {
        case .string(let string):
            let bytes = Data(string.utf8)
            let envelope = try dictionary(bytes)
            guard let type = envelope["type"] as? String else { return nil }
            let data = envelope["data"] as? [String: Any] ?? [:]
            let status = data["status"] as? [String: Any] ?? data
            let info = status["exec_info"] as? [String: Any] ?? [:]
            let nodeID = data["node"] as? String ?? data["node_id"] as? String
            var event = ComfyEvent(type: type)
            event.promptID = data["prompt_id"] as? String
            event.nodeID = nodeID
            event.value = (data["value"] as? NSNumber)?.doubleValue
            event.maximum = (data["max"] as? NSNumber)?.doubleValue
            event.queueRemaining = (info["queue_remaining"] as? NSNumber)?.intValue
            if type == "execution_error" { event.message = executionErrorMessage(data) }
            else if type == "execution_interrupted" { event.message = "任务已被服务器中断。" }
            if let output = data["output"] as? [String: Any] { event.outputs = parseOutputs(output, nodeID: nodeID) }
            event.rawData = bytes
            return event
        case .data(let data):
            // Legacy previews: 4-byte big-endian event type, 4-byte image type, then image bytes.
            // Never interpret an unknown binary packet as a completed output.
            guard data.count > 8 else { return nil }
            let eventType = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard eventType == 1 else { return nil }
            var event = ComfyEvent(type: "preview")
            event.previewData = Data(data.dropFirst(8))
            return event
        @unknown default:
            return nil
        }
    }

    private static func executionErrorMessage(_ data: [String: Any]) -> String {
        let node = data["node_id"] as? String ?? data["node"] as? String
        let detail = data["exception_message"] as? String ?? data["exception_type"] as? String ?? "执行失败"
        return node.map { "节点 \($0)：\(detail)" } ?? detail
    }

    private static func serverError(status: Int, data: Data, fallback: String) -> ComfyAPIError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var parts: [String] = []
        if let error = object["error"] as? [String: Any] {
            if let message = error["message"] as? String { parts.append(message) }
            if let detail = error["details"] as? String, !detail.isEmpty, !parts.contains(detail) { parts.append(detail) }
        } else if let message = object["error"] as? String { parts.append(message) }
        if let nodes = object["node_errors"] as? [String: Any] {
            for id in nodes.keys.sorted().prefix(12) {
                guard let node = nodes[id] as? [String: Any] else { continue }
                let errors = node["errors"] as? [[String: Any]] ?? []
                for error in errors.prefix(4) {
                    let message = error["message"] as? String ?? "参数校验失败"
                    let details = error["details"] as? String ?? ""
                    parts.append("节点 \(id)：\(message)\(details.isEmpty ? "" : " — " + details)")
                }
            }
        }
        let message = parts.isEmpty ? fallback : String(parts.joined(separator: "\n").prefix(8000))
        return ComfyAPIError(statusCode: status, message: message, nodeErrors: jsonData(object["node_errors"]))
    }
}

/// Refuse all redirects, including same-origin redirects: a wrong URL should be fixed explicitly.
/// Trust evaluation remains the platform default; this does not bypass invalid TLS certificates.
private final class ComfySessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            // Basic authentication is preemptive and scoped to the validated endpoint.
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
