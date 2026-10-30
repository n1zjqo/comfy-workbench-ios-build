import XCTest
import Foundation
@testable import ComfyWorkbenchNetworking

final class ComfyClientTests: XCTestCase {
    private var hosts: [String] = []

    override func tearDown() {
        hosts.forEach { ComfyMockURLProtocol.unregister(host: $0) }
        hosts.removeAll()
        super.tearDown()
    }

    func testImageRequestPreservesProxyPrefixQueryAndAuthentication() async throws {
        let config = ServerConfig(baseURL: "https://example.test/comfy/proxy/", username: "demo-user")
        let client = ComfyClient(config: config, password: "p:密")
        let output = ComfyOutput(filename: "a & 世界.png", subfolder: "test + folder", type: "temp")
        let request = try await client.imageRequest(for: output)
        let components = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(components.path, "/comfy/proxy/view")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, ["filename": output.filename, "subfolder": output.subfolder, "type": "temp"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("demo-user:p:密".utf8).base64EncodedString())
        XCTAssertNil(components.user)
        XCTAssertNil(components.password)
    }

    func testInvalidServerURLsAreRejectedAndLocalhostIsRecognized() throws {
        for value in ["example.com", "ftp://example.com", "https://user:pass@example.com", "https://example.com/?key=secret", "https://example.com/#page"] {
            XCTAssertThrowsError(try ServerConfig(baseURL: value).validatedBaseURL(), value)
        }
        XCTAssertTrue(ServerConfig(baseURL: "http://127.0.0.1:8188").isLoopback)
        XCTAssertTrue(ServerConfig(baseURL: "http://localhost:8188").isLoopback)
        XCTAssertFalse(ServerConfig(baseURL: "http://192.168.1.20:8188").isLoopback)
        XCTAssertThrowsError(try ServerConfig(baseURL: "https://example.com", username: "user:invalid").validatedBaseURL())
    }

    func testSubmitCarriesPromptClientAndRecoveryMarker() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/proxy/prompt")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try Self.object(requestBody: request)
            XCTAssertEqual(body["client_id"] as? String, "persistent-client")
            XCTAssertEqual((body["extra_data"] as? [String: Any])?["ios_request_id"] as? String, "local-request")
            let prompt = try XCTUnwrap(body["prompt"] as? [String: Any])
            XCTAssertEqual((prompt["9"] as? [String: Any])?["class_type"] as? String, "SaveImage")
            return try .json(["prompt_id": "server-prompt", "number": 4, "node_errors": [:]])
        }
        let prompt = try JSONSerialization.data(withJSONObject: ["9": ["class_type": "SaveImage", "inputs": ["filename_prefix": "test"]]])
        let extra = try JSONSerialization.data(withJSONObject: ["ios_request_id": "local-request"])
        let result = try await client.submit(prompt: prompt, clientID: "persistent-client", extraData: extra)
        XCTAssertEqual(result.promptID, "server-prompt")
        XCTAssertEqual(result.number, 4)
    }

    func testHTTPValidationFailureIncludesNodeDetails() async throws {
        let client = makeClient { _ in
            try .json(["error": ["message": "Prompt outputs failed validation"],
                       "node_errors": ["7": ["errors": [["message": "Value not in list", "details": "missing.safetensors"]]]]], status: 400)
        }
        let prompt = try JSONSerialization.data(withJSONObject: ["7": ["class_type": "CheckpointLoaderSimple", "inputs": [:]]])
        do {
            _ = try await client.submit(prompt: prompt, clientID: "client")
            XCTFail("Expected HTTP validation failure")
        } catch let error as ComfyAPIError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertTrue(error.message.contains("节点 7"))
            XCTAssertTrue(error.message.contains("missing.safetensors"))
            XCTAssertNotNil(error.nodeErrors)
        }
    }

    func testNodeIDsNamedPromptAndNodesAreAccepted() async throws {
        let client = makeClient { request in
            let body = try Self.object(requestBody: request)
            let prompt = try XCTUnwrap(body["prompt"] as? [String: Any])
            XCTAssertEqual((prompt["prompt"] as? [String: Any])?["class_type"] as? String, "Text")
            XCTAssertEqual((prompt["nodes"] as? [String: Any])?["class_type"] as? String, "SaveImage")
            return try .json(["prompt_id": "accepted-named-ids", "node_errors": [:]])
        }
        let prompt = Data(#"{"prompt":{"class_type":"Text","inputs":{"text":"hello"}},"nodes":{"class_type":"SaveImage","inputs":{"images":["prompt",0]}}}"#.utf8)
        let result = try await client.submit(prompt: prompt, clientID: "client")
        XCTAssertEqual(result.promptID, "accepted-named-ids")
    }

    func testSubmitRejectsCanvasAndWrappedPostBodyBeforeSending() async throws {
        let client = makeClient { _ in
            XCTFail("Invalid request shapes must fail before sending")
            return try .json([:])
        }
        for value in [#"{"nodes":[],"links":[]}"#,
                      #"{"prompt":{"1":{"class_type":"Text","inputs":{"text":"hello"}}},"client_id":"client"}"#] {
            do {
                _ = try await client.submit(prompt: Data(value.utf8), clientID: "client")
                XCTFail("Expected local shape validation failure")
            } catch let error as ComfyAPIError {
                XCTAssertNil(error.statusCode)
                XCTAssertTrue(error.message.contains("API"))
            }
        }
    }

    func testHistoryKeepsFileLocationsTextAndExecutionError() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/proxy/history/job-1")
            return try .json(["job-1": [
                "outputs": ["9": ["images": [["filename": "output.png", "subfolder": "day/one", "type": "output"]]],
                            "10": ["text": ["caption"]]],
                "status": ["completed": false, "status_str": "error", "messages": [["execution_error", ["node_id": "9", "exception_message": "Out of memory"]]]]
            ]])
        }
        let value = try await client.history(promptID: "job-1")
        let history = try XCTUnwrap(value)
        XCTAssertTrue(history.failed)
        XCTAssertFalse(history.completed)
        XCTAssertEqual(history.outputs.first?.filename, "output.png")
        XCTAssertEqual(history.outputs.first?.subfolder, "day/one")
        XCTAssertEqual(history.outputs.first?.nodeID, "9")
        XCTAssertEqual(history.textOutputs, ["caption"])
        XCTAssertTrue(history.errorMessage?.contains("Out of memory") == true)
    }

    func testHistoryAbsentIsNotMistakenForCompletion() async throws {
        let client = makeClient { _ in try .json([:]) }
        let history = try await client.history(promptID: "not-finished")
        XCTAssertNil(history)
    }

    func testRecoverFindsQueuedRequestByMetadata() async throws {
        let client = makeClient { request in
            if request.url?.path == "/proxy/queue" {
                return try .json(["queue_running": [], "queue_pending": [[3, "queued-id", [:], ["ios_request_id": "request-1"], []]]])
            }
            XCTAssertEqual(request.url?.path, "/proxy/history")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "200")
            return try .json([:])
        }
        let recovered = try await client.recoverPrompt(requestID: "request-1")
        XCTAssertEqual(recovered, "queued-id")
    }

    func testRecoverFindsJobThatMovedToHistoryAndDoesNotResubmit() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/proxy/queue" {
                return try .json(["queue_running": [], "queue_pending": []])
            }
            return try .json(["completed-id": ["prompt": [5, "completed-id", [:], ["ios_request_id": "request-2"], []]]])
        }
        let recovered = try await client.recoverPrompt(requestID: "request-2")
        XCTAssertEqual(recovered, "completed-id")
    }

    func testRecoverMissingMetadataReturnsInconclusiveNil() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url?.path == "/proxy/queue" {
                return try .json(["queue_running": [[0, "unrelated", [:], [:], []]], "queue_pending": []])
            }
            return try .json([:])
        }
        let recovered = try await client.recoverPrompt(requestID: "request-3")
        XCTAssertNil(recovered)
    }

    func testRecoverRejectsAmbiguousDuplicateSubmission() async throws {
        let client = makeClient { request in
            if request.url?.path == "/proxy/queue" {
                return try .json(["queue_running": [[0, "first-id", [:], ["ios_request_id": "duplicate"], []]], "queue_pending": []])
            }
            return try .json(["second-id": ["prompt": [1, "second-id", [:], ["ios_request_id": "duplicate"], []]]])
        }
        do {
            _ = try await client.recoverPrompt(requestID: "duplicate")
            XCTFail("Ambiguous request IDs must not select an arbitrary job")
        } catch let error as ComfyAPIError {
            XCTAssertTrue(error.message.contains("多个"))
        }
    }

    func testCancelRunningPromptNeverCallsGlobalInterrupt() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/proxy/queue")
            XCTAssertEqual(request.httpMethod, "GET")
            return try .json(["queue_running": [[0, "running-id", [:], [:], []]], "queue_pending": []])
        }
        let result = try await client.cancelPrompt(promptID: "running-id")
        guard case .runningCannotSafelyInterrupt = result else { return XCTFail("Running cancellation must refuse unknown server capability") }
    }

    func testDeletingPendingPromptOnlySendsThatID() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/proxy/queue")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try Self.object(requestBody: request)
            XCTAssertEqual(body["delete"] as? [String], ["mine-only"])
            XCTAssertNil(body["clear"])
            return ComfyMockResponse(status: 200, data: Data())
        }
        try await client.deleteQueuedPrompt(promptID: "mine-only")
    }

    func testUploadAcceptsBinaryMIMEAndDoesNotOverwriteByDefault() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/proxy/upload/image")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try Self.body(request)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
            XCTAssertTrue(text.contains("Content-Type: application/octet-stream\r\n"))
            XCTAssertTrue(text.contains("name=\"overwrite\"\r\n\r\nfalse"))
            return try .json(["name": "upload.bin", "subfolder": "incoming", "type": "input"])
        }
        let output = try await client.uploadImage(data: Data([1, 2, 3]), filename: "upload.bin", mimeType: "application/octet-stream")
        XCTAssertEqual(output.workflowInputPath, "incoming/upload.bin")
        XCTAssertEqual(output.type, "input")
    }

    func testRedirectHTTPResponseRequiresExplicitURLCorrection() async throws {
        let client = makeClient { _ in ComfyMockResponse(status: 302, data: Data()) }
        do {
            _ = try await client.systemStats()
            XCTFail("Redirect should fail instead of silently changing configured endpoint")
        } catch let error as ComfyAPIError {
            XCTAssertEqual(error.statusCode, 302)
            XCTAssertTrue(error.message.contains("重定向"))
        }
    }

    func testDDNSTOHostnameBoundary() {
        XCTAssertTrue(ServerConfig(baseURL: "https://studio.ddnsto.com").isDDNSTO)
        XCTAssertTrue(ServerConfig(baseURL: "  https://studio.ddnsto.com\n").isDDNSTO)
        XCTAssertFalse(ServerConfig(baseURL: "https://ddnsto.com.attacker.test").isDDNSTO)
        XCTAssertFalse(ServerConfig(baseURL: "https://notddnsto.com").isDDNSTO)
    }

    func testDDNSTORedirectOffersVerificationWithoutForwardingCredentials() async throws {
        let client = makeClient(ddnsto: true) { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return ComfyMockResponse(status: 302, data: Data(), headers: ["Location": "https://untrusted.test/login"])
        }
        do { _ = try await client.systemStats(); XCTFail("Expected verification") }
        catch let error as ComfyAPIError { XCTAssertTrue(error.requiresBrowserVerification) }
    }

    func testDDNSTOHTMLChallengeIsDetectedWithSuccessStatus() async throws {
        let client = makeClient(ddnsto: true) { _ in
            ComfyMockResponse(data: Data("<!doctype html><html>verify</html>".utf8), headers: ["Content-Type": "text/html"])
        }
        do { _ = try await client.objectInfo(); XCTFail("Expected verification") }
        catch let error as ComfyAPIError { XCTAssertTrue(error.requiresBrowserVerification) }
    }

    func testDDNSTOJSONIsNotMistakenForChallenge() async throws {
        let client = makeClient(ddnsto: true) { _ in try .json(["text": "<html> is just text"]) }
        _ = try await client.systemStats()
    }

    func testListsNestedServerWorkflowsAndFiltersUnsafePaths() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/proxy/userdata")
            XCTAssertEqual(request.value(forHTTPHeaderField: "comfy-user"), "chosen-user")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "dir" }?.value, "workflows")
            XCTAssertEqual(query.first { $0.name == "recurse" }?.value, "true")
            return ComfyMockResponse(data: try JSONSerialization.data(withJSONObject: [
                ["path": "文生图/a #1.json", "size": 321], ["path": "../secrets.json"],
                ["path": "/absolute.json"], ["path": "%2e%2e/escape.json"], ["path": "note.txt"],
                ["path": "文生图/a #1.json", "size": 321]
            ]))
        }
        let files = try await client.serverWorkflows(userID: "chosen-user")
        XCTAssertEqual(files.map(\.path), ["文生图/a #1.json"])
        XCTAssertEqual(files.first?.size, 321)
    }

    func testLegacyWorkflowListAndUserProfiles() async throws {
        let client = makeClient { request in
            if request.url?.path == "/proxy/users" { return try .json(["users": ["one-id": "One"]]) }
            return ComfyMockResponse(data: Data(#"["folder/workflow.json","notes.txt"]"#.utf8))
        }
        let users = try await client.workflowUsers()
        XCTAssertEqual(users.first?.id, "one-id")
        let files = try await client.serverWorkflows()
        XCTAssertEqual(files.map(\.path), ["folder/workflow.json"])
    }

    func testDownloadsWorkflowAsOneEncodedSegmentWithoutWrites() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            XCTAssertEqual(components.percentEncodedPath, "/proxy/userdata/workflows%2Ffolder%2Fa%20%231.json")
            XCTAssertNil(components.query)
            XCTAssertNil(components.fragment)
            XCTAssertEqual(request.value(forHTTPHeaderField: "comfy-user"), "selected")
            return try .json(["1": ["class_type": "Text", "inputs": ["text": "demo"]]])
        }
        let data = try await client.serverWorkflow(path: "folder/a #1.json", userID: "selected")
        XCTAssertFalse(data.isEmpty)
    }

    func testRejectsServerPathTraversalBeforeRequest() async throws {
        let client = makeClient { _ in XCTFail("Unsafe path should never be sent"); return try .json([:]) }
        for path in ["../private.json", "/private.json", "a//b.json", "a/%2E%2E/b.json", "a\\b.json", "notes.txt"] {
            do { _ = try await client.serverWorkflow(path: path); XCTFail(path) } catch {}
        }
    }

    func testSevenWorkflowOutputsShowTerminalImageAndPreserveAllExtras() throws {
        let graph = Data(#"{"1":{"class_type":"Generate","inputs":{}},"2":{"class_type":"PreviewImage","inputs":{"images":["1",0]}},"3":{"class_type":"Refine","inputs":{"image":["1",0]}},"4":{"class_type":"SaveImage","inputs":{"images":["3",0]}},"5":{"class_type":"Upscale","inputs":{"image":["3",0]}},"6":{"class_type":"SaveImage","inputs":{"images":["5",0]}},"7":{"class_type":"Comparer","inputs":{"image_a":["1",0],"image_b":["3",0]}},"8":{"class_type":"Comparer","inputs":{"image_a":["3",0],"image_b":["5",0]}}}"#.utf8)
        let outputs = [ComfyOutput(filename: "preview.png", type: "temp", nodeID: "2"), ComfyOutput(filename: "intermediate.png", nodeID: "4"), ComfyOutput(filename: "final.png", nodeID: "6"), ComfyOutput(filename: "compare-a.png", type: "temp", nodeID: "7"), ComfyOutput(filename: "compare-b.png", type: "temp", nodeID: "7"), ComfyOutput(filename: "compare-c.png", type: "temp", nodeID: "8"), ComfyOutput(filename: "compare-d.png", type: "temp", nodeID: "8")]
        let selection = ComfyOutputSelection(outputs: outputs, promptData: graph)
        XCTAssertEqual(selection.primary.map(\.filename), ["final.png"])
        XCTAssertEqual(selection.other.count, 6)
        XCTAssertEqual(Set(selection.primary + selection.other), Set(outputs))
    }

    func testOutputSelectionKeepsTrueBatchesIndependentBranchesAndUnknownGraphs() {
        let graph = Data(#"{"1":{"class_type":"Generate","inputs":{}},"2":{"class_type":"OtherGenerate","inputs":{}},"3":{"class_type":"SaveImage","inputs":{"images":["1",0]}},"4":{"class_type":"SaveImage","inputs":{"images":["2",0]}}}"#.utf8)
        let outputs = [ComfyOutput(filename: "batch-1.png", nodeID: "3"), ComfyOutput(filename: "batch-2.png", nodeID: "3"), ComfyOutput(filename: "other.png", nodeID: "4")]
        for data in [graph, Data("{}".utf8), Data("invalid".utf8)] {
            let selection = ComfyOutputSelection(outputs: outputs, promptData: data)
            XCTAssertEqual(selection.primary, outputs); XCTAssertTrue(selection.other.isEmpty)
        }
    }

    func testOutputSelectionDeduplicatesSameFileButKeepsDifferentFoldersAndTempFallback() {
        let first = ComfyOutput(filename: "same.png", subfolder: "a", type: "temp", nodeID: "1")
        let repeated = ComfyOutput(filename: "same.png", subfolder: "a", type: "temp", nodeID: "2")
        let different = ComfyOutput(filename: "same.png", subfolder: "b", type: "temp", nodeID: "2")
        let selection = ComfyOutputSelection(outputs: [first, repeated, different], promptData: Data())
        XCTAssertEqual(selection.primary, [first, different]); XCTAssertTrue(selection.other.isEmpty)
    }

    private func makeClient(ddnsto: Bool = false, _ handler: @escaping (URLRequest) throws -> ComfyMockResponse) -> ComfyClient {
        let host = UUID().uuidString.lowercased() + (ddnsto ? ".ddnsto.com" : ".test")
        hosts.append(host)
        ComfyMockURLProtocol.register(host: host, handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ComfyMockURLProtocol.self]
        return ComfyClient(config: ServerConfig(baseURL: "https://\(host)/proxy"), sessionConfiguration: configuration)
    }

    private static func object(requestBody request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body(request)) as? [String: Any])
    }

    private static func body(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { break }
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private struct ComfyMockResponse {
    var status = 200
    var data: Data
    var headers = ["Content-Type": "application/json"]
    static func json(_ value: [String: Any], status: Int = 200) throws -> ComfyMockResponse {
        ComfyMockResponse(status: status, data: try JSONSerialization.data(withJSONObject: value))
    }
}

private final class ComfyMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) throws -> ComfyMockResponse] = [:]

    static func register(host: String, handler: @escaping (URLRequest) throws -> ComfyMockResponse) {
        lock.lock(); defer { lock.unlock() }
        handlers[host] = handler
    }

    static func unregister(host: String) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let host = request.url?.host
        let handler = host.flatMap { Self.handlers[$0] }
        Self.lock.unlock()
        do {
            guard let handler = handler, let url = request.url else { throw URLError(.unsupportedURL) }
            let result = try handler(request)
            guard let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: "HTTP/1.1", headerFields: result.headers) else { throw URLError(.badServerResponse) }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
