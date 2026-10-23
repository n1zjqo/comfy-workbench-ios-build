import Foundation
import UIKit
import SwiftUI
import CryptoKit

struct SavedWorkflow: Codable, Identifiable {
    var id = UUID()
    var name: String
    var data: Data
    var pinned: Set<String> = []
    var promptField: String?
    var randomSeedFields: Set<String> = []
}

struct GenerationJob: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var name: String
    var message: String
    var promptData: Data
    var server: ServerConfig
    var promptID: String?
    var state = "等待提交"
    var progress: Double = 0
    var finished = false
    var outputs: [ComfyOutput] = []
    var text: [String] = []
    var detail: String?
}

private struct SavedState: Codable {
    var workflows: [SavedWorkflow]
    var selectedID: UUID?
    var server: ServerConfig?
    var jobs: [GenerationJob]
    var clientID: String
}

@MainActor final class WorkbenchStore: ObservableObject {
    @Published var workflows: [SavedWorkflow] = []
    @Published var selectedID: UUID?
    @Published var document: WorkflowDocument?
    @Published var server: ServerConfig?
    @Published var jobs: [GenerationJob] = []
    @Published var error: String?
    @Published var busy = false
    @Published var connectionStatus = "尚未连接"
    @Published var background: UIImage?
    @Published var activeTab = 1
    @Published var importStatus: String?
    @Published var verificationRequired: ServerConfig?
    @Published var verificationPage: VerificationPage?
    private var failedConnection: (config: ServerConfig, password: String)?
    private var browserAttempt: (config: ServerConfig, password: String)?
    var clientID = UUID().uuidString
    private var objectInfoData: Data?
    private var monitor: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventClient: ComfyClient?
    private var root: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ComfyWorkbench", isDirectory: true) }
    var selected: SavedWorkflow? { workflows.first { $0.id == selectedID } }
    var currentPromptField: WorkflowField? {
        guard let document = document else { return nil }
        if let id = selected?.promptField { return document.fields.first { $0.id == id } }
        return document.fields.first { $0.name == "prompts" && $0.schema.kind == .text }
            ?? document.fields.first { ["prompt", "text", "positive"].contains($0.name) && $0.schema.kind == .text && !$0.nodeType.lowercased().contains("show") }
    }
    init() {
        do {
            let data = try Data(contentsOf: root.appendingPathComponent("state.json"))
            let state = try JSONDecoder().decode(SavedState.self, from: data)
            workflows = state.workflows; selectedID = state.selectedID; server = state.server
            jobs = state.jobs; clientID = state.clientID
            if let item = selected { document = try WorkflowDocument(data: item.data) }
        } catch { if FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path) { self.error = "本地数据读取失败，原文件已保留：\(error.localizedDescription)" } }
        if let data = try? Data(contentsOf: root.appendingPathComponent("background.jpg")) { background = UIImage(data: data) }
    }
    func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = SavedState(workflows: workflows, selectedID: selectedID, server: server, jobs: jobs, clientID: clientID)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    func select(_ id: UUID) {
        do {
            guard let item = workflows.first(where: { $0.id == id }) else { return }
            let info = try objectInfoData.map { try ObjectInfo(data: $0) }
            document = try WorkflowDocument(data: item.data, objectInfo: info)
            selectedID = id; try persist()
        } catch { self.error = error.localizedDescription }
    }
    func importWorkflow(_ url: URL) async {
        guard !busy else { return }
        busy = true; importStatus = "正在读取文件…"
        defer { busy = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var result: Result<Data, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { location in
                    result = Result {
                        let values = try location.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        guard values.isDirectory != true else { throw WorkflowError.invalid("请选择 JSON 文件，而不是文件夹。") }
                        guard (values.fileSize ?? 0) <= 12_000_000 else { throw WorkflowError.invalid("工作流超过 12 MB。") }
                        let file = try FileHandle(forReadingFrom: location)
                        defer { try? file.close() }
                        return try WorkflowImportData.normalized(file.read(upToCount: 12_000_001) ?? Data())
                    }
                }
                if let error = coordinationError { throw error }
                guard let result = result else { throw WorkflowError.invalid("文件提供器未返回内容，请先在“文件”App 下载文件后重试。") }
                return try result.get()
            }.value
            try await finishImport(data: data, name: url.deletingPathExtension().lastPathComponent)
        } catch {
            importStatus = "导入失败：\(error.localizedDescription)"
            if let config = server { _ = noteVerification(error, config: config) }
        }
    }

    func importServerWorkflow(_ workflow: ServerWorkflow, config: ServerConfig, userID: String?) async -> Bool {
        guard !busy else { return false }
        busy = true; importStatus = "正在读取服务器工作流…"
        defer { busy = false }
        do {
            guard server == config else { throw WorkflowError.invalid("连接已改变，请重新打开服务器工作流列表。") }
            guard (workflow.size ?? 0) <= 12_000_000 else { throw WorkflowError.invalid("工作流超过 12 MB。") }
            let data = try await makeClient(config).serverWorkflow(path: workflow.path, userID: userID)
            try await finishImport(data: data, name: (workflow.name as NSString).deletingPathExtension)
            return true
        } catch {
            importStatus = "导入失败：\(error.localizedDescription)"
            _ = noteVerification(error, config: config)
            return false
        }
    }

    private func finishImport(data source: Data, name: String) async throws {
            var data = try WorkflowImportData.normalized(source)
            importStatus = "正在解析工作流…"
            let json = try JSONValue(data: data)
            if json["nodes"]?.arrayValue != nil {
                guard let server = server else { throw WorkflowError.invalid("这是画布格式。请先连接 ComfyUI 读取节点定义，再导入；也可以先在 ComfyUI 中导出 API 格式。") }
                let client = try makeClient(server)
                let metadata = try await client.objectInfo()
                objectInfoData = metadata
                data = try UIWorkflowConverter.convert(data: data, objectInfoData: metadata)
            }
            let info = try objectInfoData.map { try ObjectInfo(data: $0) }
            let parsed = try WorkflowDocument(data: data, objectInfo: info)
            var item = SavedWorkflow(name: name, data: try parsed.data())
            for node in json["nodes"]?.arrayValue ?? [] {
                let type = node["type"]?.stringValue ?? ""
                let controlIndex = type == "KSampler" ? 1 : (type == "KSamplerAdvanced" ? 2 : -1)
                let widgets = node["widgets_values"]?.arrayValue ?? []
                let positionalRandom = controlIndex >= 0 && controlIndex < widgets.count && widgets[controlIndex].stringValue == "randomize"
                if node["widgets_values_named"]?["control_after_generate"]?.stringValue == "randomize" || positionalRandom, let id = node["id"]?.displayValue {
                    item.randomSeedFields.formUnion(parsed.fields.filter { $0.nodeID == id && ["seed", "noise_seed"].contains($0.name) }.map(\.id))
                }
            }
            // Application display configuration is separate from node data.
            item.pinned = Set(parsed.applicationFields().map(\.id))
            if parsed.nodes.contains(where: { $0.classType == "RayPromptQueue" }) {
                item.pinned.formUnion(parsed.fields.filter { $0.nodeType == "RayPromptQueue" || $0.nodeType.hasPrefix("Primitive") }.map(\.id))
            }
            workflows.append(item); selectedID = item.id; document = parsed
            try persist(); activeTab = 1
            importStatus = "已导入：\(name)"
    }
    func saveDocument() throws {
        guard let index = workflows.firstIndex(where: { $0.id == selectedID }), let document = document else { return }
        workflows[index].data = try document.data(); try persist()
    }
    func edit(_ field: WorkflowField, text: String) throws {
        guard var draft = document else { return }
        try draft.update(fieldID: field.id, fromText: text)
        document = draft; try saveDocument()
    }
    func pin(_ field: WorkflowField, enabled: Bool) {
        guard let index = workflows.firstIndex(where: { $0.id == selectedID }) else { return }
        if enabled { workflows[index].pinned.insert(field.id) } else { workflows[index].pinned.remove(field.id) }
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func choosePrompt(_ id: String) {
        guard let index = workflows.firstIndex(where: { $0.id == selectedID }) else { return }
        workflows[index].promptField = id
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func removeWorkflow(_ id: UUID) {
        workflows.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; document = nil; if let first = workflows.first { select(first.id) } }
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func setRandomSeed(_ fieldID: String, enabled: Bool) throws {
        guard let index = workflows.firstIndex(where: { $0.id == selectedID }) else { return }
        if enabled { workflows[index].randomSeedFields.insert(fieldID) } else { workflows[index].randomSeedFields.remove(fieldID) }
        try persist()
    }
    func connect(config: ServerConfig, password: String) async {
        busy = true; defer { busy = false }
        do {
            _ = try config.validatedBaseURL()
            let client = ComfyClient(config: config, password: password)
            _ = try await client.systemStats()
            let metadata = try await client.objectInfo()
            let info = try ObjectInfo(data: metadata)
            try KeychainStore.savePassword(password, for: config.passwordKey)
            server = config; objectInfoData = metadata
            if var draft = document { try? draft.applyObjectInfo(info); document = draft }
            connectionStatus = "已连接"
            if verificationRequired?.baseURL == config.baseURL { verificationRequired = nil }
            failedConnection = nil
            try persist(); resumeMonitoring()
        } catch {
            connectionStatus = "连接失败"
            if noteVerification(error, config: config) { failedConnection = (config, password) }
            else { self.error = error.localizedDescription }
        }
    }
    @discardableResult
    func noteVerification(_ error: Error, config: ServerConfig) -> Bool {
        guard (error as? ComfyAPIError)?.requiresBrowserVerification == true else { return false }
        verificationRequired = config
        connectionStatus = "需要网页验证"
        return true
    }

    func beginVerification(config: ServerConfig, password: String? = nil) {
        guard !busy, verificationPage == nil else { return }
        do {
            let url = try config.validatedBaseURL()
            guard url.scheme?.lowercased() == "https" else { throw WorkflowError.invalid("网页验证请填写完整的 HTTPS 外网地址。局域网 HTTP 地址无需 DDNSTO 验证。") }
            let saved = failedConnection?.config == config ? failedConnection?.password : nil
            let storedPassword = try KeychainStore.password(for: config.passwordKey)
            browserAttempt = (config, password ?? saved ?? storedPassword ?? "")
            pauseMonitoring()
            verificationPage = VerificationPage(url: url)
        } catch { self.error = error.localizedDescription }
    }

    func finishVerification() async {
        guard let attempt = browserAttempt else { return }
        browserAttempt = nil
        connectionStatus = "正在检查验证结果…"
        // Only GET requests are made here. Closing a browser never resubmits a generation.
        await connect(config: attempt.config, password: attempt.password)
    }

    func makeClient(_ config: ServerConfig) throws -> ComfyClient {
        ComfyClient(config: config, password: try KeychainStore.password(for: config.passwordKey))
    }
    func submit(message: String? = nil) async {
        guard !busy else { return }
        guard let config = server else { error = "先在“连接”中测试并保存 ComfyUI 地址。"; activeTab = 3; return }
        guard var draft = document else { error = "先导入一个工作流。"; activeTab = 1; return }
        busy = true; defer { busy = false }
        var jobID: UUID?
        var submissionAttempted = false
        do {
            if let message = message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let field = currentPromptField else { throw WorkflowError.invalid("此工作流没有选定聊天提示词入口，请到应用页选择文本参数。") }
                try draft.update(fieldID: field.id, fromText: message)
            }
            for id in selected?.randomSeedFields ?? [] {
                guard let field = draft.fields.first(where: { $0.id == id }), field.schema.kind == .integer else { continue }
                let minimum = field.schema.minimumValue?.uint64Value ?? 0
                let maximum = min(field.schema.maximumValue?.uint64Value ?? 4_294_967_295, 4_294_967_295)
                if minimum <= maximum { try draft.update(fieldID: id, fromText: String(UInt64.random(in: minimum...maximum))) }
            }
            let data = try draft.promptData()
            let text = message ?? currentPromptField?.value.displayValue ?? "运行工作流"
            let job = GenerationJob(name: selected?.name ?? "工作流", message: text, promptData: data, server: config)
            jobs.append(job); jobID = job.id
            try persist() // Durably record BEFORE network submission, never auto-retry POST.
            let client = try makeClient(config)
            let extra = try JSONSerialization.data(withJSONObject: ["ios_request_id": job.id.uuidString])
            submissionAttempted = true
            let response = try await client.submit(prompt: data, clientID: clientID, extraData: extra)
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].promptID = response.promptID; jobs[index].state = "排队中"; try persist()
            }
            activeTab = 0; resumeMonitoring()
        } catch {
            if let id = jobID, let index = jobs.firstIndex(where: { $0.id == id }) {
                let rejected = (error as? ComfyAPIError)?.statusCode.map { (400..<500).contains($0) } ?? false
                if !submissionAttempted {
                    jobs[index].state = "未提交"
                    jobs[index].finished = true
                    jobs[index].detail = "任务未发送：\(error.localizedDescription)"
                } else {
                    jobs[index].state = rejected ? "提交失败" : (jobs[index].promptID == nil ? "提交状态待确认" : "已提交，等待查询")
                    jobs[index].finished = rejected
                    jobs[index].detail = error.localizedDescription
                }
                try? persist()
                if submissionAttempted && !rejected { resumeMonitoring() }
            }
            if !noteVerification(error, config: config) { self.error = error.localizedDescription }
        }
    }
    func upload(url: URL, field: WorkflowField) async {
        guard let config = server else { error = "请先连接 ComfyUI。"; return }
        busy = true; defer { busy = false }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 150_000_000 else { throw WorkflowError.invalid("素材超过 150 MB，请先压缩。") }
            let client = try makeClient(config)
            let data = try Data(contentsOf: url)
            let filename = UUID().uuidString + "." + url.pathExtension
            let output = try await client.uploadImage(data: data, filename: filename, mimeType: "application/octet-stream")
            try edit(field, text: output.workflowInputPath)
        } catch { self.error = error.localizedDescription }
    }
    func setBackground(_ image: UIImage) {
        let ratio = min(1, 1600 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard let data = resized.jpegData(compressionQuality: 0.88) else { return }
            try data.write(to: root.appendingPathComponent("background.jpg"), options: .atomic)
            background = resized
        } catch { self.error = error.localizedDescription }
    }
    func pauseMonitoring() {
        monitor?.cancel(); monitor = nil; eventTask?.cancel(); eventTask = nil
        let client = eventClient; eventClient = nil
        Task { await client?.disconnectEvents() }
    }
    func resumeMonitoring() {
        pauseMonitoring()
        guard verificationPage == nil, jobs.contains(where: { !$0.finished }) else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                if self?.jobs.contains(where: { !$0.finished }) != true { return }
            }
        }
        guard let config = server, let client = try? makeClient(config) else { return }
        eventClient = client
        let eventsClientID = clientID
        eventTask = Task { [weak self] in
            do {
                for try await event in await client.events(clientID: eventsClientID) {
                    guard !Task.isCancelled else { return }
                    guard let self = self, let prompt = event.promptID,
                          let index = self.jobs.firstIndex(where: { $0.promptID == prompt && $0.server.baseURL == config.baseURL && !$0.finished }) else { continue }
                    if let value = event.value, let max = event.maximum, max > 0 { self.jobs[index].progress = min(1, value / max) }
                    if event.type == "executing" || event.type == "progress" { self.jobs[index].state = "生成中" }
                }
            } catch { /* History polling remains authoritative after socket loss. */ }
        }
    }
    func poll() async {
        for job in jobs.filter({ !$0.finished && $0.server.baseURL != verificationRequired?.baseURL }) {
            if Task.isCancelled { return }
            do {
                let client = try makeClient(job.server)
                var promptID = job.promptID
                if promptID == nil { promptID = try await client.recoverPrompt(requestID: job.id.uuidString) }
                try Task.checkCancellation()
                guard let prompt = promptID else { continue }
                guard let recoveredIndex = jobs.firstIndex(where: { $0.id == job.id && !$0.finished }) else { continue }
                if jobs[recoveredIndex].promptID != prompt {
                    jobs[recoveredIndex].promptID = prompt
                    try persist()
                }
                if let history = try await client.history(promptID: prompt) {
                    try Task.checkCancellation()
                    guard let index = jobs.firstIndex(where: { $0.id == job.id && !$0.finished }) else { continue }
                    jobs[index].outputs = history.outputs; jobs[index].text = history.textOutputs
                    jobs[index].finished = history.completed || history.failed
                    jobs[index].state = history.failed ? "生成失败" : (history.completed ? "已完成" : "生成中")
                    jobs[index].detail = history.errorMessage
                    if history.completed { jobs[index].progress = 1 }
                } else {
                    let queue = try await client.queue()
                    try Task.checkCancellation()
                    guard let index = jobs.firstIndex(where: { $0.id == job.id && !$0.finished }) else { continue }
                    if queue.running.contains(where: { $0.promptID == prompt }) { jobs[index].state = "生成中" }
                    else if queue.pending.contains(where: { $0.promptID == prompt }) { jobs[index].state = "排队中" }
                    else { jobs[index].state = "等待服务器历史" }
                }
                try persist()
            } catch {
                if Task.isCancelled { return }
                _ = noteVerification(error, config: job.server)
                if let index = jobs.firstIndex(where: { $0.id == job.id && !$0.finished }) { jobs[index].detail = "查询未完成，恢复连接后继续查询：\(error.localizedDescription)" }
            }
        }
    }
    func cancel(_ job: GenerationJob) async {
        guard let prompt = job.promptID else { error = "提交结果未知，请先检查服务器队列，避免重复生成。"; return }
        do {
            let result = try await makeClient(job.server).cancelPrompt(promptID: prompt)
            switch result {
            case .removedFromQueue:
                if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].finished = true; jobs[i].state = "已取消"; try persist() }
            case .alreadyFinished: await poll()
            case .runningCannotSafelyInterrupt: error = "任务已在运行。为避免中断其他人的任务，请到 ComfyUI 页面停止这个任务。"
            }
        } catch { self.error = error.localizedDescription }
    }
    func localMedia(_ output: ComfyOutput, job: GenerationJob) async throws -> URL {
        let folder = root.appendingPathComponent("media", isDirectory: true).appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(output.id.utf8)).map { String(format: "%02x", $0) }.joined()
        let sourceExtension = (output.filename as NSString).pathExtension.lowercased()
        let safeExtension = String(sourceExtension.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(12).map(Character.init))
        let filename = digest + (safeExtension.isEmpty ? "" : "." + safeExtension)
        let url = folder.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let data = try await makeClient(job.server).imageData(for: output)
        try data.write(to: url, options: .atomic)
        return url
    }
}

