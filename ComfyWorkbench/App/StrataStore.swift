import SwiftUI
import UIKit

private struct StrataArchive: Codable {
    var profile = StrataProfile()
    var messages: [StrataMessage] = []
    var tasks: [StrataTask] = []
    var draft = ""
}

@MainActor final class StrataStore: ObservableObject {
    @Published private(set) var profile = StrataProfile()
    @Published private(set) var messages: [StrataMessage] = []
    @Published private(set) var tasks: [StrataTask] = []
    @Published private(set) var status: StrataStatus?
    @Published private(set) var route = "尚未连接"
    @Published private(set) var busy = false
    @Published private(set) var chatting = false
    @Published var notice: String?
    @Published private(set) var controlNotice: String?
    @Published var draft = ""
    @Published var assistantSelected = false
    private let client: StrataClient
    private let credentialReader: (String) throws -> String?
    private let storage: URL
    private var chatTask: Task<Void, Never>?
    private var polling: Task<Void, Never>?
    private var draftSave: Task<Void, Never>?
    private var refreshing = false
    private var statusRevision = 0
    init(storage: URL? = nil, client: StrataClient = StrataClient(), credentialReader: @escaping (String) throws -> String? = { try KeychainStore.password(for: $0) }) {
        self.client = client
        self.credentialReader = credentialReader
        self.storage = storage ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Strata/state.json")
        if let data = try? Data(contentsOf: self.storage), let saved = try? JSONDecoder().decode(StrataArchive.self, from: data) {
            profile = saved.profile; messages = saved.messages; tasks = saved.tasks; draft = saved.draft
        }
    }
    private func key() throws -> String {
        guard let key = try credentialReader(profile.tokenKey), !key.isEmpty else { throw StrataFailure("请先设置办公室 Strata 密钥") }
        return key
    }
    func save() {
        do {
            var archive = StrataArchive(); archive.profile = profile; archive.messages = messages; archive.tasks = tasks; archive.draft = draft
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(archive).write(to: storage, options: [.atomic, .completeFileProtection])
        } catch { notice = "草稿未能保存：" + error.localizedDescription }
    }
    func scheduleDraftSave() {
        draftSave?.cancel()
        draftSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
            self?.save()
        }
    }
    func configure(lan: String, internet: String, token: String) async {
        guard !busy, !chatting else { return }
        statusRevision += 1
        busy = true; defer { busy = false }
        do {
            var candidate = profile; candidate.lanURL = lan.trimmingCharacters(in: .whitespacesAndNewlines); candidate.publicURL = internet.trimmingCharacters(in: .whitespacesAndNewlines)
            let secret = token.isEmpty ? try key() : token.trimmingCharacters(in: .whitespacesAndNewlines)
            let (pinned, state, selected) = try await client.pair(candidate, key: secret)
            try KeychainStore.savePassword(secret, for: pinned.tokenKey)
            profile = pinned; status = state; route = selected; save(); notice = "办公室 Strata 已连接"
        } catch { notice = error.localizedDescription }
    }
    func refresh(manual: Bool = false) async {
        guard !profile.serverID.isEmpty, !refreshing, !busy else { return }
        let revision = statusRevision
        refreshing = true; defer { refreshing = false }
        do {
            let (state, selected) = try await client.status(profile, key: key())
            guard revision == statusRevision, !busy else { return }
            if status != state { status = state }; if route != selected { route = selected }
            for item in tasks where !item.finished {
                let next = try await client.task(id: item.id, profile: profile, key: key())
                update(next)
            }
        } catch {
            guard revision == statusRevision, !busy else { return }
            if manual { notice = error.localizedDescription }
            if route != "连接暂不可用" { route = "连接暂不可用" }
            if status != nil { status = nil }
        }
    }
    func resume() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
    func background() { polling?.cancel(); polling = nil; draftSave?.cancel(); save() }
    func control(_ action: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        statusRevision += 1
        controlNotice = "正在提交操作…"
        do {
            let result = try await client.control(action, profile: profile, key: key())
            status = result
            switch action {
            case "release":
                if !result.online { controlNotice = "操作已返回，但推理服务暂时不可达，尚不能确认卸载状态。" }
                else { controlNotice = result.loaded ? "服务器仍显示模型已加载，请刷新状态确认。" : "Strata 已卸载；下次对话可自动加载。" }
            case "free_comfy": controlNotice = result.comfyResources?.loadedModels == 0 ? "ComfyUI 驻留模型已卸载；整卡占用还包含 Strata 和桌面。" : "已提交 ComfyUI 释放请求，请刷新确认；整卡占用还包含其他程序。"
            case "pause": controlNotice = result.loaded ? "已暂停接收，等待当前任务结束后卸载。" : "已暂停并卸载，需手动恢复。"
            default: controlNotice = result.loaded ? "模型已加载。" : "操作已完成，请查看当前状态。"
            }
        } catch { controlNotice = "操作未能确认：" + error.localizedDescription; status = nil }
    }
    func send(image: UIImage?) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chatting, !text.isEmpty else { return }
        guard !profile.serverID.isEmpty else { notice = "请先在连接页设置办公室 Strata"; return }
        guard status?.paused != true else { notice = "Strata 已暂停，请先手动恢复"; return }
        if status?.gpuPolicy == "comfy_priority", ["waiting_strata", "yielding", "comfy", "settling", "restoring"].contains(status?.gpuPhase ?? "") {
            notice = "ComfyUI 正在优先生产或切换显存，输入已保留；Strata 就绪后再发送。"
            return
        }
        guard messages.count < 60 else { notice = "当前对话已满，请开始新对话"; return }
        let picture = image.flatMap { resizedChatImage($0) }
        messages.append(StrataMessage(role: "user", content: text, image: picture)); draft = ""
        let outgoing = messages
        let answer = StrataMessage(role: "assistant", content: ""); messages.append(answer); save(); chatting = true
        chatTask = Task {
            defer { chatting = false; chatTask = nil; save() }
            do {
                try await client.chat(outgoing, model: status?.model ?? "", profile: profile, key: key()) { [weak self] text in
                    await self?.receive(text, id: answer.id)
                }
            } catch is CancellationError { notice = "已停止接收，服务器可能仍在完成当前生成" }
            catch { notice = error.localizedDescription }
        }
    }
    private func receive(_ text: String, id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }), messages[index].content != text { messages[index].content = text }
    }
    func stopChat() { chatTask?.cancel() }
    func clearChat() { guard !chatting else { return }; messages = []; save() }
    func startTask() async {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !busy, !prompt.isEmpty else { return }; busy = true; defer { busy = false }
        do { let result = try await client.task(prompt: prompt, profile: profile, key: key()); tasks.insert(result, at: 0); tasks = Array(tasks.prefix(30)); draft = ""; save() }
        catch { notice = error.localizedDescription }
    }
    func taskAction(_ task: StrataTask, action: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do { update(try await client.task(id: task.id, action: action, approvalID: task.pending?.id, profile: profile, key: key())) }
        catch { notice = error.localizedDescription }
    }
    private func update(_ task: StrataTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }), tasks[index] != task else { return }
        tasks[index] = task; save()
    }
    private func resizedChatImage(_ image: UIImage) -> Data? {
        let ratio = min(1, 1600 / max(image.size.width, image.size.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: image.size.width * ratio, height: image.size.height * ratio), format: format).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: image.size.width * ratio, height: image.size.height * ratio))
        }.jpegData(compressionQuality: 0.8)
    }
}
