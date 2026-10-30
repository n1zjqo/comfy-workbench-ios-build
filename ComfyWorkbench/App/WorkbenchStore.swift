import Foundation
import UIKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

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
    var workflowID: UUID?
    var execution: ExecutionTrace?
    var displayedOutputs: ComfyOutputSelection { ComfyOutputSelection(outputs: outputs, promptData: promptData) }
}

private struct SavedState: Codable {
    var workflows: [SavedWorkflow]
    var selectedID: UUID?
    var server: ServerConfig?
    var jobs: [GenerationJob]
    var clientID: String
    var backgroundDate: Date?
}

@MainActor final class WorkbenchStore: ObservableObject {
    @Published var workflows: [SavedWorkflow] = []
    @Published var selectedID: UUID?
    @Published var document: WorkflowDocument?
    @Published var canvas: WorkflowCanvas?
    @Published var canvasRunIssue: String?
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
    @Published var verificationInSettings = false
    private var failedConnection: (config: ServerConfig, password: String)?
    private var browserAttempt: (config: ServerConfig, password: String)?
    var clientID = UUID().uuidString
    private var objectInfoData: Data?
    private var monitor: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var eventClient: ComfyClient?
    private var draftSaveTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    private var backgroundDate: Date?
    private var backgroundRevision = UUID()
    private var bufferedEvents: [ComfyEvent] = []
    private var clients: [(ServerConfig, ComfyClient)] = []
    private let clientFactory: ((ServerConfig) throws -> ComfyClient)?
    private var checkingConnection = false
    private var connectionRevision = 0
    private var lastConnectionSuccess = Date.distantPast
    private var referenceDownloads: [String: Task<URL, Error>] = [:]
    private var lastReferenceDownload: Task<URL, Error>?
    private let root: URL
    var selected: SavedWorkflow? { workflows.first { $0.id == selectedID } }
    var panelItems: [PanelFieldConfiguration] {
        guard let selected = selected else { return [] }
        let fields = canvas?.fields ?? []
        if let items = selected.panelItems { return items.filter { item in fields.contains { $0.id == item.id } } }
        return fields.filter { selected.pinned.contains($0.id) }.map { PanelFieldConfiguration(id: $0.id) }
    }
    var canvasJob: GenerationJob? {
        let matching = jobs.filter { $0.workflowID == selectedID && $0.workflowID != nil }
        return matching.last { !$0.finished && $0.execution?.phase == .running } ?? matching.last
    }
    var canUndo: Bool { !(selected?.journal?.past.isEmpty ?? true) }
    var canRedo: Bool { !(selected?.journal?.future.isEmpty ?? true) }
    var currentPromptField: WorkflowField? {
        guard let document = document else { return nil }
        if let id = selected?.promptField { return document.fields.first { $0.id == id } }
        return document.fields.first { $0.name == "prompts" && $0.schema.kind == .text }
            ?? document.fields.first { ["prompt", "text", "positive"].contains($0.name) && $0.schema.kind == .text && !$0.nodeType.lowercased().contains("show") }
    }
    init(storageURL: URL? = nil, clientFactory: ((ServerConfig) throws -> ComfyClient)? = nil) {
        self.clientFactory = clientFactory
        root = storageURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ComfyWorkbench", isDirectory: true)
        do {
            let data = try Data(contentsOf: root.appendingPathComponent("state.json"))
            let state = try JSONDecoder().decode(SavedState.self, from: data)
            workflows = state.workflows; selectedID = state.selectedID; server = state.server
            jobs = state.jobs; clientID = state.clientID
            if server != nil { connectionStatus = "等待检查连接" }
            backgroundDate = state.backgroundDate
            for index in jobs.indices where !jobs[index].finished { jobs[index].execution?.disconnect() }
            if let item = selected { try loadWorkflow(item) }
        } catch { if FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path) { self.error = "本地数据读取失败，原文件已保留：\(error.localizedDescription)" } }
        if let data = try? Data(contentsOf: root.appendingPathComponent("background.jpg")) {
            background = UIImage(data: data)
            if backgroundDate == nil { backgroundDate = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("background.jpg").path)[.modificationDate]) as? Date }
        }
    }
    func persist() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = SavedState(workflows: workflows, selectedID: selectedID, server: server, jobs: jobs, clientID: clientID, backgroundDate: backgroundDate)
        try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
    }
    func select(_ id: UUID) {
        do {
            guard let item = workflows.first(where: { $0.id == id }) else { return }
            try loadWorkflow(item)
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
            noteConnected(config)
            try await finishImport(data: data, name: (workflow.name as NSString).deletingPathExtension)
            return true
        } catch {
            importStatus = "导入失败：\(error.localizedDescription)"
            _ = noteVerification(error, config: config)
            return false
        }
    }

    private func finishImport(data source: Data, name: String) async throws {
            let data = try WorkflowImportData.normalized(source)
            importStatus = "正在解析工作流…"
            let json = try JSONValue(data: data)
            let info = try objectInfoData.map { try ObjectInfo(data: $0) }
            let graph = try WorkflowCanvas(data: data, objectInfo: info)
            var item = SavedWorkflow(name: name, data: data)
            item.canvasWidgetOrder = graph.widgetOrder
            let editable = graph.fields
            for node in json["nodes"]?.arrayValue ?? [] {
                let type = node["type"]?.stringValue ?? ""
                let controlIndex = type == "KSampler" ? 1 : (type == "KSamplerAdvanced" ? 2 : -1)
                let widgets = node["widgets_values"]?.arrayValue ?? []
                let positionalRandom = controlIndex >= 0 && controlIndex < widgets.count && widgets[controlIndex].stringValue == "randomize"
                if node["widgets_values_named"]?["control_after_generate"]?.stringValue == "randomize" || positionalRandom, let id = node["id"]?.displayValue {
                    item.randomSeedFields.formUnion(editable.filter { $0.nodeID == id && ["seed", "noise_seed"].contains($0.name) }.map(\.id))
                }
            }
            // Application display configuration is separate from node data.
            item.pinned = Set(editable.filter { ["text", "prompt", "prompts", "seed", "steps", "cfg", "width", "height", "image", "video", "audio"].contains($0.name) }.map(\.id))
            if !graph.originalLayout {
                let api = try WorkflowDocument(data: data, objectInfo: info)
                item.pinned = Set(api.applicationFields().map(\.id))
            }
            if item.pinned.isEmpty { item.pinned = Set(editable.map(\.id)) }
            if graph.nodes.contains(where: { $0.type == "RayPromptQueue" }) {
                item.pinned.formUnion(editable.filter { $0.nodeType == "RayPromptQueue" || $0.nodeType.hasPrefix("Primitive") }.map(\.id))
            }
            workflows.append(item); selectedID = item.id; try loadWorkflow(item)
            try persist(); activeTab = 1
            importStatus = "已导入：\(name)"
    }
    private func loadWorkflow(_ item: SavedWorkflow) throws {
        let info = try objectInfoData.map { try ObjectInfo(data: $0) }
        let graph = try WorkflowCanvas(data: item.data, objectInfo: info, widgetOrder: item.canvasWidgetOrder ?? [:])
        canvas = graph; document = nil; canvasRunIssue = nil
        if graph.originalLayout {
            guard let metadata = objectInfoData else { canvasRunIssue = "画布已就绪，可离线编辑。连接服务器并检查节点定义后即可确认能否运行。"; return }
            do { document = try WorkflowDocument(data: UIWorkflowConverter.convert(data: item.data, objectInfoData: metadata), objectInfo: info) }
            catch { canvasRunIssue = "画布可编辑，暂不能运行：\(error.localizedDescription)" }
        } else { document = try WorkflowDocument(data: item.data, objectInfo: info) }
    }
    func prepareCanvas() async {
        guard !busy else { return }
        guard let config = server else { activeTab = 3; return }
        busy = true; defer { busy = false }
        do {
            objectInfoData = try await makeClient(config).objectInfo()
            noteConnected(config)
            if let item = selected { try loadWorkflow(item) }
        } catch { canvasRunIssue = error.localizedDescription; noteConnectionFailure(error, config: config) }
    }
    func edit(_ field: WorkflowField, text: String) throws {
        guard let current = canvas?.fields.first(where: { $0.id == field.id }) else { throw WorkflowError.invalid("找不到这个参数。") }
        let change = WorkflowChange(kind: .parameter, fieldID: current.id, label: current.name, before: current.value, after: try current.parsedValue(from: text))
        try commit(change)
    }
    func pin(_ field: WorkflowField, enabled: Bool) {
        var items = panelItems
        if enabled && !items.contains(where: { $0.id == field.id }) { items.append(PanelFieldConfiguration(id: field.id)) }
        if !enabled { items.removeAll { $0.id == field.id } }
        do { try configurePanel(items) } catch { self.error = error.localizedDescription }
    }
    func choosePrompt(_ id: String) {
        do { try commit(WorkflowChange(kind: .prompt, label: "提示词入口", before: selected?.promptField.map(JSONValue.string) ?? .null, after: id.isEmpty ? .null : .string(id))) }
        catch { self.error = error.localizedDescription }
    }
    func removeWorkflow(_ id: UUID) {
        workflows.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; document = nil; canvas = nil; canvasRunIssue = nil; if let first = workflows.first { select(first.id) } }
        do { try persist() } catch { self.error = error.localizedDescription }
    }
    func setRandomSeed(_ fieldID: String, enabled: Bool) throws {
        let before = selected?.randomSeedFields ?? []
        var after = before
        if enabled { after.insert(fieldID) } else { after.remove(fieldID) }
        try commit(WorkflowChange(kind: .randomSeeds, label: "随机种子", before: .array(before.sorted().map(JSONValue.string)), after: .array(after.sorted().map(JSONValue.string))))
    }
    func configurePanel(_ items: [PanelFieldConfiguration]) throws {
        guard Set(items.map(\.id)).count == items.count else { throw WorkflowError.invalid("面板不能重复添加同一个参数。") }
        for item in items {
            guard let field = canvas?.fields.first(where: { $0.id == item.id }) else { throw WorkflowError.invalid("找不到面板参数。") }
            try item.validate(for: field)
        }
        try commit(WorkflowChange(kind: .panel, label: "应用面板", before: JSONValue(data: JSONEncoder().encode(panelItems)), after: JSONValue(data: JSONEncoder().encode(items))))
    }
    private func applying(_ change: WorkflowChange, value: JSONValue, to item: SavedWorkflow) throws -> SavedWorkflow {
        var item = item
        switch change.kind {
        case .parameter:
            guard let id = change.fieldID else { throw WorkflowError.invalid("编辑记录不完整。") }
            let info = try objectInfoData.map { try ObjectInfo(data: $0) }
            var graph = try WorkflowCanvas(data: item.data, objectInfo: info, widgetOrder: item.canvasWidgetOrder ?? [:])
            try graph.update(fieldID: id, value: value)
            item.data = try graph.data(); item.canvasWidgetOrder = graph.widgetOrder
            item.editorDrafts?.removeValue(forKey: id)
        case .panel:
            item.panelItems = try JSONDecoder().decode([PanelFieldConfiguration].self, from: value.data())
            item.pinned = Set(item.panelItems?.map(\.id) ?? [])
        case .prompt: item.promptField = value.stringValue
        case .randomSeeds: item.randomSeedFields = Set(value.arrayValue?.compactMap(\.stringValue) ?? [])
        }
        item.editedAt = Date()
        return item
    }
    private func commit(_ change: WorkflowChange) throws {
        guard let index = workflows.firstIndex(where: { $0.id == selectedID }) else { throw WorkflowError.invalid("先选择工作流。") }
        let previous = workflows[index]
        var item = try applying(change, value: change.after, to: previous)
        var journal = item.journal ?? WorkflowJournal(); journal.record(change); item.journal = journal
        workflows[index] = item
        do { try persist(); try loadWorkflow(item) } catch { workflows[index] = previous; try? loadWorkflow(previous); throw error }
    }
    func undoEdit() { replay(redo: false) }
    func redoEdit() { replay(redo: true) }
    private func replay(redo: Bool) {
        guard !busy, let index = workflows.firstIndex(where: { $0.id == selectedID }) else { return }
        let previous = workflows[index]
        var journal = previous.journal ?? WorkflowJournal()
        guard let change = redo ? journal.redo() : journal.undo() else { return }
        do {
            var item = try applying(change, value: redo ? change.after : change.before, to: previous)
            item.journal = journal; workflows[index] = item
            try persist(); try loadWorkflow(item)
        } catch { workflows[index] = previous; try? loadWorkflow(previous); self.error = error.localizedDescription }
    }
    func editorDraft(_ fieldID: String) -> String? { selected?.editorDrafts?[fieldID] }
    func saveEditorDraft(_ fieldID: String, text: String?) {
        guard let index = workflows.firstIndex(where: { $0.id == selectedID }) else { return }
        if workflows[index].editorDrafts == nil { workflows[index].editorDrafts = [:] }
        workflows[index].editorDrafts?[fieldID] = text
        scheduleDraftSave()
    }
    func setChatDraft(_ text: String) {
        guard let index = workflows.firstIndex(where: { $0.id == selectedID }), workflows[index].chatDraft != text else { return }
        workflows[index].chatDraft = text; scheduleDraftSave()
    }
    func saveViewport(_ viewport: CanvasViewport, workflowID: UUID?) {
        guard viewport.valid, let index = workflows.firstIndex(where: { $0.id == workflowID }) else { return }
        workflows[index].viewport = viewport; scheduleDraftSave()
    }
    private func scheduleDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 750_000_000); try Task.checkCancellation(); self?.saveDraftsNow() } catch { }
        }
    }
    func saveDraftsNow() {
        draftSaveTask?.cancel(); draftSaveTask = nil
        do { try persist() } catch { self.error = "草稿保存失败：\(error.localizedDescription)" }
    }
    func connect(config: ServerConfig, password: String) async {
        guard !busy else { return }
        connectionRevision += 1
        busy = true; defer { busy = false }
        var reachedServer = false
        do {
            var config = config
            _ = try config.validatedBaseURL()
            let probe = ComfyClient(config: config, password: password)
            if let id = try await probe.pairRoutes() { config.serviceID = id }
            let client = ComfyClient(config: config, password: password)
            _ = try await client.systemStats()
            reachedServer = true; connectionStatus = "已连接，正在读取节点定义…"
            let metadata = try await client.objectInfo()
            _ = try ObjectInfo(data: metadata)
            try KeychainStore.savePassword(password, for: config.passwordKey)
            if server != config { bufferedEvents = [] }
            server = config; objectInfoData = metadata
            clients = [(config, client)]
            if let item = selected { try loadWorkflow(item) }
            noteConnected(config)
            if verificationRequired?.baseURL == config.baseURL { verificationRequired = nil }
            failedConnection = nil
            try persist(); resumeMonitoring()
        } catch {
            connectionStatus = reachedServer ? "服务器可达，节点定义未能读取" : "连接失败"
            if noteVerification(error, config: config, asConnectionAttempt: true) { failedConnection = (config, password) }
            else { self.error = error.localizedDescription }
        }
    }
    @discardableResult
    func noteVerification(_ error: Error, config: ServerConfig, asConnectionAttempt: Bool = false) -> Bool {
        guard (error as? ComfyAPIError)?.requiresBrowserVerification == true else { return false }
        // A historical job on a different server must not replace the selected connection's state.
        guard asConnectionAttempt || server == nil || server == config else { return true }
        connectionRevision += 1; lastConnectionSuccess = .distantPast
        verificationRequired = config
        connectionStatus = "需要网页验证"
        return true
    }

    func beginVerification(config: ServerConfig, password: String? = nil, inSettings: Bool = false) {
        guard !busy, verificationPage == nil else { return }
        do {
            var verification = config
            if let internet = config.publicURL, !internet.isEmpty { verification.baseURL = internet }
            let url = try verification.validatedBaseURL()
            guard url.scheme?.lowercased() == "https" else { throw WorkflowError.invalid("网页验证请填写完整的 HTTPS 外网地址。局域网 HTTP 地址无需 DDNSTO 验证。") }
            let saved = failedConnection?.config == config ? failedConnection?.password : nil
            let storedPassword = try KeychainStore.password(for: config.passwordKey)
            browserAttempt = (config, password ?? saved ?? storedPassword ?? "")
            pauseMonitoring()
            verificationInSettings = inSettings
            verificationPage = VerificationPage(url: url.appendingPathComponent("workbench/identity"))
        } catch { self.error = error.localizedDescription }
    }

    func finishVerification() async {
        verificationInSettings = false
        guard let attempt = browserAttempt else { return }
        browserAttempt = nil
        connectionStatus = "正在检查验证结果…"
        // Only GET requests are made here. Closing a browser never resubmits a generation.
        await connect(config: attempt.config, password: attempt.password)
    }

    func makeClient(_ config: ServerConfig) throws -> ComfyClient {
        if let cached = clients.first(where: { $0.0 == config }) { return cached.1 }
        let client: ComfyClient
        if let factory = clientFactory { client = try factory(config) }
        else { client = ComfyClient(config: config, password: try KeychainStore.password(for: config.passwordKey)) }
        clients.append((config, client)); if clients.count > 8 { clients.removeFirst() }
        return client
    }
    func noteConnected(_ config: ServerConfig) {
        guard server == config else { return }
        connectionRevision += 1; lastConnectionSuccess = Date()
        if connectionStatus != "已连接" { connectionStatus = "已连接" }
        if verificationRequired == config { verificationRequired = nil }
    }
    private func noteConnectionFailure(_ failure: Error, config: ServerConfig, isProbe: Bool = false) {
        guard server == config, !(failure is CancellationError), (failure as? URLError)?.code != .cancelled else { return }
        if noteVerification(failure, config: config) { return }
        if isProbe || failure is URLError || ((failure as? ComfyAPIError)?.statusCode ?? 0) >= 500 {
            connectionRevision += 1; connectionStatus = "连接暂不可用"; lastConnectionSuccess = .distantPast
        }
    }
    func refreshConnectionStatus(force: Bool = false) async {
        guard let config = server, !checkingConnection, !busy, verificationPage == nil else { return }
        guard force || Date().timeIntervalSince(lastConnectionSuccess) >= 20 else { return }
        checkingConnection = true; defer { checkingConnection = false }
        let revision = connectionRevision
        do {
            _ = try await makeClient(config).systemStats()
            guard revision == connectionRevision, !Task.isCancelled else { return }
            noteConnected(config)
        } catch {
            guard revision == connectionRevision, !Task.isCancelled else { return }
            noteConnectionFailure(error, config: config, isProbe: true)
        }
    }
    func submit(message: String? = nil) async {
        guard !busy else { return }
        guard let config = server else { error = "先在“连接”中测试并保存 ComfyUI 地址。"; activeTab = 3; return }
        guard var draft = document else { error = canvasRunIssue ?? "先导入一个工作流。"; activeTab = 1; return }
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
            var job = GenerationJob(name: selected?.name ?? "工作流", message: text, promptData: data, server: config)
            job.workflowID = selectedID; job.execution = ExecutionTrace()
            jobs.append(job); jobID = job.id
            try persist() // Durably record BEFORE network submission, never auto-retry POST.
            resumeMonitoring()
            let client = try makeClient(config)
            let extra = try JSONSerialization.data(withJSONObject: ["ios_request_id": job.id.uuidString])
            submissionAttempted = true
            let response = try await client.submit(prompt: data, clientID: clientID, extraData: extra)
            noteConnected(config)
            if let index = jobs.firstIndex(where: { $0.id == job.id }) {
                jobs[index].promptID = response.promptID; jobs[index].state = "排队中"; try persist()
                replayBufferedEvents(promptID: response.promptID, config: config)
            }
            activeTab = 0; resumeMonitoring()
        } catch {
            noteConnectionFailure(error, config: config)
            if let id = jobID, let index = jobs.firstIndex(where: { $0.id == id }) {
                let rejected = (error as? ComfyAPIError)?.statusCode.map { (400..<500).contains($0) } ?? false
                if !submissionAttempted {
                    jobs[index].state = "未提交"
                    jobs[index].finished = true
                    jobs[index].detail = "任务未发送：\(error.localizedDescription)"
                    jobs[index].execution?.receive(type: "execution_interrupted", node: nil, message: "任务未发送：\(error.localizedDescription)")
                } else {
                    jobs[index].state = rejected ? "提交失败" : (jobs[index].promptID == nil ? "提交状态待确认" : "已提交，等待查询")
                    jobs[index].finished = rejected
                    jobs[index].detail = error.localizedDescription
                    if rejected { jobs[index].execution?.receive(type: "execution_error", node: nil, message: error.localizedDescription) }
                }
                try? persist()
                if submissionAttempted && !rejected { resumeMonitoring() }
            }
            if !noteVerification(error, config: config) { self.error = error.localizedDescription }
        }
    }
    func uploadReference(url: URL) async throws -> String {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 150_000_000 else { throw WorkflowError.invalid("素材为空或超过 150 MB，请先压缩后重试。") }
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        let ext = url.pathExtension.lowercased()
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        return try await uploadReference(data: data, extension: ext.isEmpty ? "bin" : ext, mime: mime)
    }
    func uploadReference(image: UIImage) async throws -> String {
        guard image.size.width * image.size.height * image.scale * image.scale <= 40_000_000 else { throw WorkflowError.invalid("图片超过 4000 万像素，请先缩小后上传。") }
        let upright: UIImage
        if image.imageOrientation == .up { upright = image }
        else {
            let format = UIGraphicsImageRendererFormat(); format.scale = image.scale
            upright = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        }
        guard let data = upright.pngData() else { throw WorkflowError.invalid("无法读取这张图片，请换一张重试。") }
        return try await uploadReference(data: data, extension: "png", mime: "image/png")
    }
    private func uploadReference(data: Data, extension ext: String, mime: String) async throws -> String {
        guard !busy else { throw WorkflowError.invalid("请等待当前操作完成。") }
        guard let config = server else { throw WorkflowError.invalid("请先设置 ComfyUI 连接。") }
        guard !data.isEmpty, data.count <= 150_000_000 else { throw WorkflowError.invalid("素材为空或超过 150 MB。") }
        busy = true; defer { busy = false }
        do {
            let output = try await makeClient(config).uploadImage(data: data, filename: UUID().uuidString + "." + ext, mimeType: mime)
            noteConnected(config)
            guard server == config else { throw WorkflowError.invalid("连接已改变，请重新选择素材。") }
            return output.workflowInputPath
        } catch { noteConnectionFailure(error, config: config); throw error }
    }
    func referenceMediaURL(_ value: String) async throws -> URL {
        guard let config = server else { throw WorkflowError.invalid("请先设置 ComfyUI 连接。") }
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines), type = "input"
        for candidate in ["input", "output", "temp"] where name.hasSuffix(" [\(candidate)]") {
            name = String(name.dropLast(candidate.count + 3)); type = candidate; break
        }
        name = name.replacingOccurrences(of: "\\", with: "/")
        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else { throw WorkflowError.invalid("素材文件名无效。") }
        let filename = String(components.last!)
        let output = ComfyOutput(filename: filename, subfolder: components.dropLast().joined(separator: "/"), type: type)
        let digest = SHA256.hash(data: Data((config.baseURL + "|" + (config.serviceID ?? "") + "|" + output.id).utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent("references", isDirectory: true)
        let ext = String((filename as NSString).pathExtension.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.prefix(12).map(Character.init))
        let file = folder.appendingPathComponent(digest + (ext.isEmpty ? "" : "." + ext))
        if FileManager.default.fileExists(atPath: file.path) { return file }
        if let pending = referenceDownloads[digest] { return try await pending.value }
        // A mixed video workflow must not download several large clips into memory at once.
        let previous = lastReferenceDownload
        let task = Task { @MainActor () async throws -> URL in
            _ = try? await previous?.value
            do {
                let data = try await makeClient(config).imageData(for: output)
                noteConnected(config)
                guard data.count <= 150_000_000 else { throw WorkflowError.invalid("素材过大，无法在手机预览。") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic); return file
            } catch { noteConnectionFailure(error, config: config); throw error }
        }
        referenceDownloads[digest] = task; lastReferenceDownload = task
        defer { referenceDownloads.removeValue(forKey: digest); if referenceDownloads.isEmpty { lastReferenceDownload = nil } }
        return try await task.value
    }
    func setBackground(_ image: UIImage, sourceDate: Date = Date()) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        backgroundRevision = UUID()
        let ratio = min(1, 2400 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            guard let data = resized.jpegData(compressionQuality: 0.88) else { return }
            try data.write(to: root.appendingPathComponent("background.jpg"), options: .atomic)
            background = resized; backgroundDate = sourceDate; try persist()
        } catch { self.error = error.localizedDescription }
    }
    private func updateGeneratedBackground() {
        guard backgroundTask == nil,
              let job = jobs.last(where: { $0.finished && $0.state == "已完成" && $0.date > (backgroundDate ?? .distantPast) && $0.displayedOutputs.primary.contains(where: { ["png", "jpg", "jpeg", "webp", "heic"].contains(($0.filename as NSString).pathExtension.lowercased()) }) }),
              let output = job.displayedOutputs.primary.first(where: { ["png", "jpg", "jpeg", "webp", "heic"].contains(($0.filename as NSString).pathExtension.lowercased()) }) else { return }
        let revision = backgroundRevision
        backgroundTask = Task { [weak self] in
            guard let self = self else { return }
            var applied = false
            defer { self.backgroundTask = nil; if applied { self.updateGeneratedBackground() } }
            do {
                let local = try await self.localMedia(output, job: job)
                let image = await Task.detached(priority: .utility) { downsampledImage(local, maxPixelSize: 2400) }.value
                try Task.checkCancellation()
                guard self.backgroundRevision == revision, let image = image else { return }
                self.setBackground(image, sourceDate: job.date)
                applied = self.backgroundDate == job.date
            } catch { /* Retain the current picture; retry on the next history refresh. */ }
        }
    }
    func pauseMonitoring(markDisconnected: Bool = true) {
        monitor?.cancel(); monitor = nil; eventTask?.cancel(); eventTask = nil
        if markDisconnected {
            for index in jobs.indices where !jobs[index].finished { jobs[index].execution?.disconnect() }
        }
        let client = eventClient; eventClient = nil
        Task { await client?.disconnectEvents() }
    }
    func resumeMonitoring() {
        pauseMonitoring(markDisconnected: false)
        updateGeneratedBackground()
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
            while !Task.isCancelled {
                guard self?.jobs.contains(where: { !$0.finished && $0.server.baseURL == config.baseURL }) == true else { return }
                do {
                    for try await event in await client.events(clientID: eventsClientID) {
                        guard !Task.isCancelled else { return }
                        self?.noteConnected(config)
                        self?.receive(event, config: config)
                    }
                } catch {
                    guard !Task.isCancelled, let self = self else { return }
                    for index in self.jobs.indices where !self.jobs[index].finished && self.jobs[index].server.baseURL == config.baseURL { self.jobs[index].execution?.disconnect() }
                }
                do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            }
        }
    }
    private func receive(_ event: ComfyEvent, config: ServerConfig, bufferUnknown: Bool = true) {
        guard let prompt = event.promptID else { return }
        guard let index = jobs.firstIndex(where: { $0.promptID == prompt && $0.server.baseURL == config.baseURL && !$0.finished }) else {
            if bufferUnknown && jobs.contains(where: { $0.promptID == nil && !$0.finished && $0.server.baseURL == config.baseURL }) {
                bufferedEvents.append(event); if bufferedEvents.count > 200 { bufferedEvents.removeFirst(bufferedEvents.count - 200) }
            }
            return
        }
        var trace = jobs[index].execution ?? ExecutionTrace()
        trace.receive(type: event.type, node: event.nodeID, nodes: event.nodes, value: event.value, maximum: event.maximum, message: event.message)
        jobs[index].execution = trace
        if let fraction = trace.fraction { jobs[index].progress = fraction }
        if trace.phase == .running { jobs[index].state = "生成中" }
        if let detail = trace.detail { jobs[index].detail = detail }
    }
    private func replayBufferedEvents(promptID: String, config: ServerConfig) {
        let events = bufferedEvents.filter { $0.promptID == promptID }
        bufferedEvents.removeAll { $0.promptID == promptID }
        for event in events { receive(event, config: config, bufferUnknown: false) }
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
                    replayBufferedEvents(promptID: prompt, config: job.server)
                    try persist()
                }
                if let history = try await client.history(promptID: prompt) {
                    try Task.checkCancellation()
                    noteConnected(job.server)
                    guard let index = jobs.firstIndex(where: { $0.id == job.id && !$0.finished }) else { continue }
                    jobs[index].outputs = history.outputs; jobs[index].text = history.textOutputs
                    jobs[index].finished = history.completed || history.failed
                    jobs[index].state = history.failed ? "生成失败" : (history.completed ? "已完成" : "生成中")
                    jobs[index].detail = history.errorMessage
                    var trace = jobs[index].execution ?? ExecutionTrace()
                    if let record = try? JSONValue(data: history.rawData) {
                        for entry in record["status"]?["messages"]?.arrayValue ?? [] {
                            guard let pair = entry.arrayValue, pair.count > 1, let type = pair[0].stringValue else { continue }
                            guard ["execution_cached", "execution_error", "execution_interrupted", "execution_success"].contains(type) else { continue }
                            let body = pair[1]
                            trace.receive(type: type, node: body["node_id"]?.displayValue ?? body["node"]?.stringValue,
                                          nodes: (body["nodes"]?.arrayValue ?? body["executed"]?.arrayValue ?? []).map(\.displayValue), message: history.errorMessage)
                        }
                        trace.completedNodes.formUnion(record["outputs"]?.objectValue?.keys.map { $0 } ?? [])
                        if let failed = trace.failedNode { trace.completedNodes.remove(failed) }
                    }
                    if history.failed { trace.receive(type: "execution_error", node: trace.failedNode, message: history.errorMessage) }
                    else if history.completed { trace.receive(type: "execution_success", node: nil) }
                    jobs[index].execution = trace
                    if history.completed { jobs[index].progress = 1 }
                } else {
                    let queue = try await client.queue()
                    try Task.checkCancellation()
                    noteConnected(job.server)
                    guard let index = jobs.firstIndex(where: { $0.id == job.id && !$0.finished }) else { continue }
                    if queue.running.contains(where: { $0.promptID == prompt }) { jobs[index].state = "生成中" }
                    else if queue.pending.contains(where: { $0.promptID == prompt }) { jobs[index].state = "排队中" }
                    else { jobs[index].state = "等待服务器历史" }
                }
                try persist()
            } catch {
                if Task.isCancelled { return }
                noteConnectionFailure(error, config: job.server)
                _ = noteVerification(error, config: job.server)
                if let index = jobs.firstIndex(where: { $0.id == job.id && !$0.finished }) { jobs[index].detail = "查询未完成，恢复连接后继续查询：\(error.localizedDescription)" }
            }
        }
        updateGeneratedBackground()
    }
    func cancel(_ job: GenerationJob) async {
        guard let prompt = job.promptID else { error = "提交结果未知，请先检查服务器队列，避免重复生成。"; return }
        do {
            let result = try await makeClient(job.server).cancelPrompt(promptID: prompt)
            switch result {
            case .removedFromQueue:
                if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].finished = true; jobs[i].state = "已取消"; jobs[i].execution?.receive(type: "execution_interrupted", node: nil, message: "已取消排队"); try persist() }
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

