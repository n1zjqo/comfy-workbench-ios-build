import XCTest
@testable import ComfyWorkbenchNetworking

final class StrataTests: XCTestCase {
    let identity = "20dc53dc-5504-4d0d-911e-1b107e886f88"
    let state = #"{"online":true,"loaded":false,"paused":true,"activeRequests":0,"maintenance":false,"inFlight":0,"model":"synthetic","gpu":{"total_mib":32000,"used_mib":100}}"#
    override func tearDown() { StrataProtocol.handler = nil }
    func config() -> URLSessionConfiguration { let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StrataProtocol.self]; return config }
    func profile() -> StrataProfile {
        var profile = StrataProfile(); profile.lanURL = "http://192.168.1.20:8086"; profile.publicURL = "https://example.com/office"; profile.serverID = identity
        return profile
    }
    func info(_ id: String? = nil) -> String { "{\"protocolVersion\":1,\"service\":\"strata-workbench\",\"serverId\":\"\(id ?? identity)\",\"name\":\"Test office\"}" }
    func testTwoShutdownStatesHaveDifferentMeaning() throws {
        var value = try JSONDecoder().decode(StrataStatus.self, from: Data(state.utf8))
        XCTAssertTrue(value.title.contains("手动恢复"))
        value.paused = false
        XCTAssertTrue(value.title.contains("自动唤醒"))
        value.paused = true; value.loaded = true
        XCTAssertTrue(value.title.contains("等待释放"))
    }
    func testGPUCoordinationStatusKeepsOldBridgeCompatibilityAndManualPausePriority() throws {
        var value = try JSONDecoder().decode(StrataStatus.self, from: Data(state.utf8))
        XCTAssertNil(value.gpuPolicy)
        XCTAssertNil(value.comfyResources)
        XCTAssertNil(value.manuallyReleased)
        value.paused = false
        value.gpuPolicy = "comfy_priority"; value.gpuPhase = "comfy"
        XCTAssertTrue(value.title.contains("ComfyUI"))
        value.gpuPhase = "restoring"
        XCTAssertTrue(value.title.contains("恢复"))
        value.paused = true
        XCTAssertTrue(value.title.contains("手动恢复"))
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(StrataStatus.self, from: data), value)
    }
    func testOfficeLANIsPreferredWithoutPublicProbe() async throws {
        let log = StrataLog()
        StrataProtocol.handler = { [self] request in log.add(request); return (200, "application/json", request.url!.path.hasSuffix("info") ? info() : state) }
        let client = StrataClient(configuration: config())
        let (_, route) = try await client.status(profile(), key: "synthetic-token")
        XCTAssertEqual(route, "办公室局域网")
        XCTAssertEqual(log.requests.map { $0.url!.host! }, ["192.168.1.20", "192.168.1.20"])
        XCTAssertNil(log.requests[0].value(forHTTPHeaderField: "Authorization"))
    }
    func testHomeOrCellularFallsBackToOfficePublicAndKeepsPrefix() async throws {
        let log = StrataLog()
        StrataProtocol.handler = { [self] request in
            log.add(request)
            if request.url!.host == "192.168.1.20" { throw URLError(.cannotConnectToHost) }
            return (200, "application/json", request.url!.path.hasSuffix("info") ? info() : state)
        }
        let client = StrataClient(configuration: config())
        let (_, route) = try await client.status(profile(), key: "synthetic-token")
        XCTAssertEqual(route, "办公室公网 HTTPS")
        XCTAssertEqual(log.requests.last?.url?.path, "/office/workbench/status")
        XCTAssertTrue(log.requests.filter { $0.value(forHTTPHeaderField: "Authorization") != nil }.allSatisfy { $0.url!.host == "example.com" })
    }
    func testMismatchedIdentityNeverReceivesCredentials() async throws {
        let log = StrataLog()
        StrataProtocol.handler = { [self] request in log.add(request); return (200, "application/json", info(UUID().uuidString)) }
        let client = StrataClient(configuration: config())
        do { _ = try await client.control("pause", profile: profile(), key: "secret"); XCTFail("Accepted wrong server") } catch {}
        XCTAssertTrue(log.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.httpMethod == "GET" })
    }
    func testFailedControlIsNotReplayedOnOtherRoute() async throws {
        let log = StrataLog()
        StrataProtocol.handler = { [self] request in
            log.add(request)
            if request.httpMethod == "POST" { throw URLError(.networkConnectionLost) }
            return (200, "application/json", info())
        }
        let client = StrataClient(configuration: config())
        do { _ = try await client.control("pause", profile: profile(), key: "secret"); XCTFail("Failure hidden") } catch {}
        XCTAssertEqual(log.requests.filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertFalse(log.requests.contains { $0.url!.host == "example.com" })
    }
    func testHTMLVerificationPageDoesNotReceiveSecret() async throws {
        let log = StrataLog()
        StrataProtocol.handler = { request in log.add(request); return (200, "text/html", "<html>Verify</html>") }
        let client = StrataClient(configuration: config())
        do { _ = try await client.status(profile(), key: "secret"); XCTFail("Accepted HTML") } catch { XCTAssertTrue(error.localizedDescription.contains("验证")) }
        XCTAssertTrue(log.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }
    func testTaskApprovalContainsOnlyApprovalIdentifier() async throws {
        let log = StrataLog()
        let id = UUID().uuidString
        StrataProtocol.handler = { [self] request in
            log.add(request)
            return (200, "application/json", request.url!.path.hasSuffix("info") ? info() : "{\"id\":\"\(id)\",\"state\":\"running\",\"title\":\"test\",\"events\":[],\"output\":\"\",\"pending\":null,\"step\":1}")
        }
        let client = StrataClient(configuration: config())
        _ = try await client.task(id: id, action: "approve", approvalID: "one-time", profile: profile(), key: "synthetic")
        let body = try JSONSerialization.jsonObject(with: log.requests.last!.httpBody!) as! [String: String]
        XCTAssertEqual(body, ["action": "approve", "approvalId": "one-time"])
    }
    func testOldComfyConfigStillDecodesWithoutNewFields() throws {
        let value = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"baseURL":"https://example.com","username":"","passwordKey":"test"}"#.utf8))
        XCTAssertNil(value.publicURL); XCTAssertNil(value.serviceID)
    }
    func testComfyDualRoutesVerifyIdentityBeforeCredentialsAndPrompt() async throws {
        let log = StrataLog()
        StrataProtocol.handler = { [self] request in
            log.add(request)
            if request.url!.host == "192.168.1.20" { throw URLError(.cannotConnectToHost) }
            if request.url!.path.hasSuffix("identity") { return (200, "application/json", "{\"service\":\"comfy-workbench\",\"serverId\":\"\(identity)\"}") }
            return (200, "application/json", "{}")
        }
        let settings = ServerConfig(baseURL: "http://192.168.1.20:8188", username: "test", passwordKey: "key", publicURL: "https://example.com/comfy", serviceID: identity)
        let client = ComfyClient(config: settings, password: "secret", sessionConfiguration: config())
        _ = try await client.systemStats()
        XCTAssertEqual(log.requests.last?.url?.path, "/comfy/system_stats")
        XCTAssertTrue(log.requests.filter { $0.url!.path.hasSuffix("identity") }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(log.requests.filter { $0.value(forHTTPHeaderField: "Authorization") != nil }.map { $0.url!.host! }, ["example.com"])
    }
}

private final class StrataLog: @unchecked Sendable {
    let lock = NSLock(); private var list: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return list }
    func add(_ request: URLRequest) {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }
            request.httpBody = data
        }
        lock.lock(); list.append(request); lock.unlock()
    }
}
private final class StrataProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, mime, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(data.utf8)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
