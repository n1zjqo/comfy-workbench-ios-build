import XCTest
@testable import ComfyWorkbenchNetworking

final class ClipboardSyncTests: XCTestCase {
    private func batch(_ sequence: Int64, text: String = "hello", more: Bool = false, reset: Bool = false) throws -> ClipboardBatch {
        let json: [String: Any] = ["items": [["id": UUID().uuidString, "sequence": sequence, "deviceId": "computer", "deviceName": "Test computer", "kind": "text", "text": text, "createdAt": 1_700_000_000_000]], "cursor": sequence, "hasMore": more, "reset": reset]
        return try JSONDecoder().decode(ClipboardBatch.self, from: JSONSerialization.data(withJSONObject: json))
    }
    func testLocalAndPublicEndpointPolicy() throws {
        XCTAssertEqual(try ClipboardEndpoint.url("http://192.168.1.20:8899", publicAddress: false).absoluteString, "http://192.168.1.20:8899/")
        XCTAssertEqual(try ClipboardEndpoint.url("https://example.com/hub", publicAddress: true).absoluteString, "https://example.com/hub/")
        for value in ["http://example.com", "https://name:password@example.com", "https://example.com?token=secret", "file:///tmp/test", "http://192.168.1.999"] { XCTAssertThrowsError(try ClipboardEndpoint.url(value, publicAddress: false)) }
        XCTAssertThrowsError(try ClipboardEndpoint.url("http://192.168.1.20", publicAddress: true))
    }
    func testClipboardValidationPreservesTextAndLimitsImages() throws {
        let input = ClipboardInput(kind: "text", text: "  hello\nworld  ")
        try input.validate(); XCTAssertEqual(input.text, "  hello\nworld  ")
        XCTAssertThrowsError(try ClipboardInput(kind: "text", text: String(repeating: "x", count: 262145)).validate())
        XCTAssertThrowsError(try ClipboardInput(kind: "image", data: "bad").validate())
        try ClipboardInput(kind: "image", data: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jN1sAAAAASUVORK5CYII=").validate()
    }
    func testQueuePersistenceAndEchoSuppression() throws {
        var state = ClipboardArchive(); let first = ClipboardInput(kind: "text", text: "clipboard")
        try state.enqueue(first); try state.enqueue(ClipboardInput(kind: "text", text: "clipboard"))
        XCTAssertEqual(state.outbox.count, 1)
        let restored = try JSONDecoder().decode(ClipboardArchive.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.outbox.first?.id, first.id)
        try state.enqueue(ClipboardInput(kind: "text", text: "clipboard"), force: true)
        XCTAssertEqual(state.outbox.count, 2)
    }
    func testQueueRejectsOverflowWithoutDroppingOldItems() throws {
        var state = ClipboardArchive()
        for n in 0..<30 { try state.enqueue(ClipboardInput(kind: "text", text: "item \(n)")) }
        XCTAssertThrowsError(try state.enqueue(ClipboardInput(kind: "text", text: "overflow")))
        XCTAssertEqual(state.outbox.count, 30); XCTAssertEqual(state.outbox.first?.text, "item 0")
    }
    func testPaginationAndStaleCursorProtection() throws {
        var state = ClipboardArchive(); try state.merge(batch(4, more: true, reset: true)); XCTAssertFalse(state.initialized)
        try state.merge(batch(5)); XCTAssertTrue(state.initialized); XCTAssertEqual(state.history.map(\.sequence), [5,4])
        XCTAssertThrowsError(try state.merge(batch(3))); XCTAssertEqual(state.cursor,5)
        for n in 6...110 { try state.merge(batch(Int64(n))) }
        XCTAssertEqual(state.history.count,100); XCTAssertEqual(state.history.last?.sequence,11)
    }
    func testHubMismatchDoesNotReceiveDeviceToken() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ClipboardURLProtocol.self]
        let seen = RequestLog()
        ClipboardURLProtocol.handler = { request in
            seen.append(request)
            if request.url!.path.hasSuffix("info") {
                let hub = request.url!.host == "192.168.1.20" ? "wrong" : "expected"
                return (200, "application/json", Data("{\"hubId\":\"\(hub)\",\"protocolVersion\":1}".utf8))
            }
            return (200,"application/json",Data("{\"items\":[],\"cursor\":0,\"hasMore\":false,\"reset\":false}".utf8))
        }
        let client = ClipboardClient(configuration: config)
        let profile = ClipboardProfile(lanURL: "http://192.168.1.20:8899", publicURL: "https://example.com", deviceName: "test", hubId: "expected", deviceId: "device")
        let (_, route) = try await client.changes(after: 0, profile: profile, token: "test-token")
        XCTAssertEqual(route,"公网 HTTPS")
        XCTAssertTrue(seen.requests.filter { $0.url!.path.hasSuffix("info") }.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(seen.requests.filter { $0.value(forHTTPHeaderField: "Authorization") != nil }.map { $0.url!.host! },["example.com"])
    }
    func testLANPreferredAndHTMLVerificationRejected() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ClipboardURLProtocol.self]
        ClipboardURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("info") { return (200,"application/json",Data("{\"hubId\":\"hub\",\"protocolVersion\":1}".utf8)) }
            return (200,"text/html",Data("<html>verify</html>".utf8))
        }
        let client = ClipboardClient(configuration: config)
        let profile = ClipboardProfile(lanURL: "http://192.168.1.20", publicURL: "https://example.com", deviceName: "test", hubId: "hub", deviceId: "device")
        let (_, route) = try await client.select(profile); XCTAssertEqual(route,"局域网直连")
        do { _ = try await client.changes(after: 0, profile: profile, token: "test"); XCTFail("Accepted HTML verification page") }
        catch { XCTAssertTrue(error.localizedDescription.contains("网页")) }
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock(); private var values: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ request: URLRequest) { lock.lock(); values.append(request); lock.unlock() }
}
private final class ClipboardURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { let (code, mime, data) = try Self.handler!(request); let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": mime])!; client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
