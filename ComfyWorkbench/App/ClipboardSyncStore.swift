import SwiftUI
import UIKit

@MainActor
final class ClipboardSyncStore: ObservableObject {
    @Published private(set) var archive = ClipboardArchive()
    @Published private(set) var route = "未连接"
    @Published private(set) var status = "先和电脑配对"
    @Published private(set) var busy = false
    @Published private(set) var refreshing = false
    @Published var notice: String?
    private let client: ClipboardClient
    private let credentialReader: (String) throws -> String?
    private let storage: URL
    private var loop: Task<Void, Never>?
    private var pasteboardObserver: NSObjectProtocol?
    private var changeCount: Int
    private var localChangedAt = Date.distantPast
    private var nextNetwork = Date.distantPast
    // Polling is internal scheduling state, not a visible loading transition.
    private var polling = false
    private var refreshRequested = false

    init(storageURL: URL? = nil, client: ClipboardClient = ClipboardClient(), credentialReader: @escaping (String) throws -> String? = { try KeychainStore.password(for: $0) }) {
        self.client = client
        self.credentialReader = credentialReader
        storage = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ClipboardSync/state.json")
        changeCount = UIPasteboard.general.changeCount
        do { if FileManager.default.fileExists(atPath: storage.path) { archive = try JSONDecoder().decode(ClipboardArchive.self, from: Data(contentsOf: storage)); status = "等待同步" } }
        catch { notice = "同步草稿暂时无法读取：\(error.localizedDescription)" }
        pasteboardObserver = NotificationCenter.default.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkClipboard() }
        }
    }
    deinit { loop?.cancel(); if let pasteboardObserver = pasteboardObserver { NotificationCenter.default.removeObserver(pasteboardObserver) } }
    func resume() {
        guard loop == nil else { return }; nextNetwork = .distantPast
        loop = Task { [weak self] in
            await self?.client.reset()
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }
    func pause() { loop?.cancel(); loop = nil; refreshRequested = false; if refreshing { refreshing = false } }
    private func commit(_ next: ClipboardArchive) throws {
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(next).write(to: storage, options: [.atomic, .completeFileProtection])
        archive = next
    }
    func setAutomatic(send: Bool? = nil, receive: Bool? = nil) {
        do { var next = archive; if let send = send { next.autoSend = send; changeCount = UIPasteboard.general.changeCount }; if let receive = receive { next.autoReceive = receive }; try commit(next) }
        catch { notice = error.localizedDescription }
    }
    func checkConnection(lan: String, internet: String) async throws -> ClipboardConnection {
        guard !busy, !polling else { throw ClipboardFailure("正在同步，请稍后检测") }
        busy = true; defer { busy = false }
        try validateAddresses(lan, internet)
        return try await client.probe(lan: lan, internet: internet, expectedHubID: archive.profile?.hubId)
    }
    func pair(lan: String, internet: String, code: String, name: String, expectedHubID: String? = nil) async {
        guard !busy, !polling else { return }
        guard archive.outbox.isEmpty else { notice = "请先处理待发送内容，再切换中心"; return }
        busy = true; defer { busy = false }
        do {
            try validateAddresses(lan, internet)
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClipboardFailure("请输入设备名") }
            let credentials = try await client.pair(lan: lan, internet: internet, code: code, name: name, expectedHubID: expectedHubID)
            let profile = ClipboardProfile(lanURL: lan.trimmingCharacters(in: .whitespacesAndNewlines), publicURL: internet.trimmingCharacters(in: .whitespacesAndNewlines), deviceName: name, hubId: credentials.hubId, deviceId: credentials.deviceId)
            try KeychainStore.savePassword(credentials.token, for: profile.tokenKey)
            var next = ClipboardArchive(); next.profile = profile; next.autoSend = archive.autoSend; next.autoReceive = archive.autoReceive
            let oldKey = archive.profile?.tokenKey
            do { try commit(next) } catch { try? KeychainStore.deletePassword(for: profile.tokenKey); throw error }
            if let oldKey = oldKey { try? KeychainStore.deletePassword(for: oldKey) }
            changeCount = UIPasteboard.general.changeCount; status = "已配对，正在读取历史"; nextNetwork = .distantPast; notice = "配对完成"
        } catch { notice = error.localizedDescription }
    }
    func saveAddresses(lan: String, internet: String) async {
        guard !busy, !polling else { notice = "正在同步，请稍后保存"; return }
        do { try validateAddresses(lan, internet); var next = archive; guard next.profile != nil else { throw ClipboardFailure("请先配对") }; next.profile?.lanURL = lan.trimmingCharacters(in: .whitespacesAndNewlines); next.profile?.publicURL = internet.trimmingCharacters(in: .whitespacesAndNewlines); try commit(next); await client.reset(); nextNetwork = .distantPast; notice = "地址已保存" }
        catch { notice = error.localizedDescription }
    }
    private func validateAddresses(_ lan: String, _ internet: String) throws {
        let lan = lan.trimmingCharacters(in: .whitespacesAndNewlines), internet = internet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lan.isEmpty || !internet.isEmpty else { throw ClipboardFailure("请至少填写一个地址") }
        if !lan.isEmpty { _ = try ClipboardEndpoint.url(lan, publicAddress: false) }
        if !internet.isEmpty { _ = try ClipboardEndpoint.url(internet, publicAddress: true) }
    }
    func sendCurrent() { do { try capture(force: true) } catch { notice = error.localizedDescription } }
    private func capture(force: Bool) throws {
        guard archive.profile != nil else { throw ClipboardFailure("请先配对电脑") }
        let pasteboard = UIPasteboard.general
        let input: ClipboardInput
        if pasteboard.hasImages {
            guard let image = pasteboard.image, image.size.width * image.scale <= 8192, image.size.height * image.scale <= 8192,
                  image.size.width * image.size.height * image.scale * image.scale <= 24_000_000,
                  let data = pasteboard.data(forPasteboardType: "public.png") ?? image.pngData() else { throw ClipboardFailure("图片无法读取或尺寸过大") }
            input = ClipboardInput(kind: "image", data: data.base64EncodedString())
        } else if let text = pasteboard.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { input = ClipboardInput(kind: "text", text: text) }
        else { if force { throw ClipboardFailure("剪贴板中没有文字或图片") }; return }
        var next = archive; try next.enqueue(input, force: force); try commit(next)
        changeCount = pasteboard.changeCount; localChangedAt = Date(); nextNetwork = .distantPast
        if force { notice = "已加入待发送" }
    }
    func copy(_ entry: ClipboardEntry, notify: Bool = true) {
        do {
            try entry.input.validate()
            if entry.kind == "text" { UIPasteboard.general.setItems([["public.utf8-plain-text": entry.text ?? ""]], options: [.localOnly: true]) }
            else if let data = Data(base64Encoded: entry.data ?? ""), UIImage(data: data) != nil { UIPasteboard.general.setItems([["public.png": data]], options: [.localOnly: true]) }
            else { throw ClipboardFailure("图片内容无效") }
            changeCount = UIPasteboard.general.changeCount; if notify { localChangedAt = Date() }
            var next = archive; next.lastDigest = entry.input.digest; try commit(next)
            if notify { notice = "已复制" }
        } catch { notice = error.localizedDescription }
    }
    func removePending(_ id: String) { do { var next = archive; next.outbox.removeAll { $0.id == id }; try commit(next) } catch { notice = error.localizedDescription } }
    func retry() {
        guard archive.profile != nil, !refreshing else { return }
        refreshRequested = true; refreshing = true; nextNetwork = .distantPast
    }
    func disconnect() {
        guard !busy, !polling else { notice = "正在同步，请稍后再试"; return }
        do { let key = archive.profile?.tokenKey; try commit(ClipboardArchive()); if let key = key { try? KeychainStore.deletePassword(for: key) }; refreshRequested = false; if refreshing { refreshing = false }; route = "未连接"; status = "先和电脑配对" }
        catch { notice = error.localizedDescription }
    }
    private func checkClipboard() {
        guard UIApplication.shared.applicationState == .active else { return }
        let count = UIPasteboard.general.changeCount
        if count != changeCount {
            changeCount = count; localChangedAt = Date()
            if archive.autoSend && archive.profile != nil { do { try capture(force: false) } catch { notice = error.localizedDescription } }
        }
    }
    func tick(force: Bool = false) async {
        guard UIApplication.shared.applicationState == .active else { return }
        checkClipboard()
        guard !busy, !polling, force || Date() >= nextNetwork, let profile = archive.profile else { return }
        polling = true
        let manualRefresh = refreshRequested; refreshRequested = false
        defer {
            polling = false
            if manualRefresh, refreshing { refreshing = false }
            // A tap during an existing poll must still schedule its requested refresh.
            if refreshRequested { nextNetwork = .distantPast }
        }
        if manualRefresh { await client.reset() }
        let started = Date(), hadPending = !archive.outbox.isEmpty
        do {
            guard let token = try credentialReader(profile.tokenKey) else { throw ClipboardFailure("配对凭据不可用，请重新配对") }
            if let first = archive.outbox.first {
                let (receipt, label) = try await client.send(first, profile: profile, token: token)
                try Task.checkCancellation()
                guard receipt.id == first.id else { throw ClipboardFailure("发送确认不匹配") }
                var next = archive; next.outbox.removeAll { $0.id == first.id }; try commit(next); if route != label { route = label }
            }
            let (batch, label) = try await client.changes(after: archive.cursor, profile: profile, token: token)
            try Task.checkCancellation()
            let initialized = archive.initialized
            if !batch.items.isEmpty || !initialized || batch.cursor != archive.cursor { var next = archive; try next.merge(batch); try commit(next) }
            if route != label { route = label }
            if initialized, !batch.reset, !batch.hasMore, !hadPending, archive.outbox.isEmpty, archive.autoReceive, localChangedAt < started.addingTimeInterval(-3), UIPasteboard.general.changeCount == changeCount,
               let latest = batch.items.max(by: { $0.sequence < $1.sequence }), latest.deviceId != profile.deviceId { copy(latest, notify: false) }
            let message = archive.outbox.isEmpty ? "已同步" : "正在发送"
            if status != message { status = message }
            nextNetwork = Date().addingTimeInterval(batch.hasMore || !archive.outbox.isEmpty ? 0.1 : 1.5)
        } catch {
            guard !Task.isCancelled else { return }
            if route != "离线 · 等待重连" { route = "离线 · 等待重连" }
            let message = error is ClipboardFailure ? error.localizedDescription : "暂时无法连接，待发送内容已保留"
            if status != message { status = message }
            nextNetwork = Date().addingTimeInterval(4)
        }
    }
}

