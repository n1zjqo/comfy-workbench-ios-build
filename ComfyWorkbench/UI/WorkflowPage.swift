import SwiftUI
import UniformTypeIdentifiers

struct WorkflowPage: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var importing = false
    @State private var browsingServer = false
    @State private var exporting = false
    @State private var exportFile = WorkflowFile(data: Data())
    @State private var allParameters = false
    @State private var editing: WorkflowField?
    @State private var graph = false
    @State private var manageFields = false
    @State private var search = ""
    @State private var pendingDelete: UUID?
    var fields: [WorkflowField] {
        let available = store.canvas?.fields ?? []
        let base = allParameters ? available : store.panelItems.compactMap { item in available.first { $0.id == item.id } }
        guard !search.isEmpty else { return base }
        return base.filter { "\($0.name) \($0.nodeType) \($0.nodeID)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("我的 AI 应用").font(.largeTitle.bold()); Text("让工作流变得顺手").font(.subheadline).foregroundColor(.secondary) }
                    Spacer()
                    Menu {
                        Button { importing = true } label: { Label("从文件导入", systemImage: "doc.badge.plus") }
                        Button { browsingServer = true } label: { Label("从服务器读取", systemImage: "server.rack") }
                    } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).glass(16) }.accessibilityLabel("添加工作流").disabled(store.busy)
                }
                if let status = store.importStatus {
                    HStack(alignment: .top, spacing: 10) {
                        if store.busy { ProgressView() }
                        Text(status).font(.subheadline).textSelection(.enabled)
                        Spacer(minLength: 0)
                        if !store.busy { Button { store.importStatus = nil } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("关闭导入提示") }
                    }.padding(14).glass(18)
                }
                if store.workflows.isEmpty { emptyState }
                else {
                    workflowSelector
                    EditHistoryBar()
                    HStack(spacing: 12) {
                        Button { graph = true } label: { Label("打开画布", systemImage: "point.3.connected.trianglepath.dotted").font(.caption).frame(minHeight: 44) }.disabled(store.canvas == nil)
                        Spacer()
                        Button { manageFields = true } label: { Label("配置面板", systemImage: "slider.horizontal.3").font(.caption).frame(minHeight: 44) }
                        Menu {
                            Button("导出 API JSON") {
                                do { if let doc = store.document { exportFile = WorkflowFile(data: try doc.promptData(prettyPrinted: true)); exporting = true } }
                                catch { store.error = error.localizedDescription }
                            }.disabled(store.document == nil)
                            Button("导出画布 JSON") {
                                do { if let canvas = store.canvas { exportFile = WorkflowFile(data: try canvas.exportData()); exporting = true } }
                                catch { store.error = error.localizedDescription }
                            }.disabled(store.canvas?.originalLayout != true)
                            Button("删除此应用", role: .destructive) { pendingDelete = store.selectedID }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("应用操作")
                    }.foregroundColor(Palette.paper)
                    if let issue = store.canvasRunIssue {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(issue).font(.caption).foregroundColor(.secondary)
                            Button("连接并检查运行条件") { Task { await store.prepareCanvas() } }.frame(minHeight: 44).disabled(store.busy)
                        }.padding(16).glass(18)
                    }
                    Picker("参数范围", selection: $allParameters) { Text("应用参数").tag(false); Text("全部参数").tag(true) }.pickerStyle(.segmented)
                    if allParameters { TextField("搜索参数或节点", text: $search).padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)) }
                    if fields.isEmpty { Text("点“配置面板”选择你常用的参数。全部参数仍然可以查看。").font(.subheadline).foregroundColor(.secondary).padding(.vertical, 25) }
                    if allParameters {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(fields) { field in
                                Button { editing = field } label: { ParameterRow(field: field) }.buttonStyle(.plain)
                                Divider().padding(.leading, 16)
                            }
                        }.background(Palette.ink.opacity(0.92), in: RoundedRectangle(cornerRadius: 20)).clipShape(RoundedRectangle(cornerRadius: 20))
                    } else { ApplicationPanel { editing = $0 } }
                    if let count = store.canvas?.fields.count { Text("共 \(count) 个参数。也可以打开画布，点击节点编辑。").font(.caption).foregroundColor(.secondary) }
                    Button { Task { await store.submit() } } label: {
                        HStack { if store.busy { ProgressView() }; Text("生成作品").font(.headline); Spacer(); Image(systemName: "sparkles") }.padding(.horizontal, 20).frame(height: 54)
                    }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink).disabled(store.busy || store.document == nil)
                }
            }.padding(24).padding(.bottom, 12)
        }
        .sheet(isPresented: $importing) {
            WorkflowPicker { result in
                importing = false
                if let result = result {
                    switch result {
                    case .success(let url): Task { await store.importWorkflow(url) }
                    case .failure(let error): store.importStatus = "导入失败：\(error.localizedDescription)"
                    }
                }
            }
        }
        .sheet(isPresented: $browsingServer) { ServerWorkflowLibrary() }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json, defaultFilename: store.selected?.name ?? "workflow") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
        .sheet(item: $editing) { field in FieldEditor(field: field, configuration: allParameters ? nil : store.panelItems.first { $0.id == field.id }) }
        .fullScreenCover(isPresented: $graph) { WorkflowCanvasView() }
        .sheet(isPresented: $manageFields) { PanelConfiguration() }
        .alert("删除这个应用？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { if let id = pendingDelete { store.removeWorkflow(id) }; pendingDelete = nil }
        } message: { Text("只删除 App 中的工作流副本，不影响原文件和生成记录。") }
    }
    private var workflowSelector: some View {
        Menu {
            ForEach(store.workflows) { item in Button { store.select(item.id) } label: { Label(item.name, systemImage: item.id == store.selectedID ? "checkmark" : "square.stack") } }
            Button("从文件导入…") { importing = true }
            Button("从服务器读取…") { browsingServer = true }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 25)).frame(width: 50, height: 54).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.selected?.name ?? "选择工作流").font(.headline).multilineTextAlignment(.leading).lineLimit(2)
                    Text("\(store.canvas?.nodes.count ?? 0) 个节点 · \(store.canvas?.links.count ?? 0) 条连接").font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 0); Image(systemName: "chevron.down").font(.caption)
            }.padding(17).glass(23)
        }.buttonStyle(.plain)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "slider.horizontal.below.rectangle").font(.system(size: 46, weight: .ultraLight)).padding(.top, 25)
            Text("把工作流\n装进一个小面板。").font(.system(size: 32, weight: .medium)).lineSpacing(6)
            Text("导入 ComfyUI JSON，直接调整提示词、尺寸、种子和模型。常用参数可以固定在这里。").font(.body).foregroundColor(.secondary).lineSpacing(5)
            Button("从文件导入") { importing = true }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink).controlSize(.large).disabled(store.busy)
            Button { browsingServer = true } label: { Label("从服务器读取", systemImage: "server.rack").frame(minHeight: 44) }.disabled(store.busy)
            Text("两种 JSON 都能离线打开和编辑。普通画布保留原始布局，API 格式自动布局；运行画布前需连接服务器检查节点。").font(.caption).foregroundColor(.secondary)
        }.padding(24).glass(28)
    }
}

struct ParameterRow: View {
    let field: WorkflowField
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(field.name).font(.system(size: 15, weight: .medium)).foregroundColor(.white)
                Text("\(field.nodeType)  #\(field.nodeID)").font(.caption2).foregroundColor(.white.opacity(0.48))
                if field.schema.multiline { Text(field.value.displayValue.isEmpty ? "添加提示词" : field.value.displayValue).font(.subheadline).foregroundColor(.white.opacity(0.75)).lineLimit(3).padding(.top, 5) }
            }
            Spacer(minLength: 8)
            if !field.schema.multiline { Text(field.value.displayValue.isEmpty ? "未填写" : field.value.displayValue).font(.subheadline).foregroundColor(.white.opacity(0.72)).lineLimit(2).multilineTextAlignment(.trailing).frame(maxWidth: 150, alignment: .trailing) }
            Image(systemName: "chevron.right").font(.caption2).foregroundColor(.white.opacity(0.4)).padding(.top, 4)
        }.padding(17).frame(minHeight: 66).contentShape(Rectangle())
    }
}

struct FieldEditor: View {
    @EnvironmentObject var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    let field: WorkflowField
    var configuration: PanelFieldConfiguration?
    @State private var text: String
    @State private var error: String?
    @State private var pickingFile = false
    @State private var filter = ""
    @State private var randomSeed = false
    @State private var leaving = false
    @State private var restoredDraft = false
    private var filteredChoices: [JSONValue] { field.schema.options.filter { filter.isEmpty || $0.displayValue.localizedCaseInsensitiveContains(filter) } }
    init(field: WorkflowField, configuration: PanelFieldConfiguration? = nil) { self.field = field; self.configuration = configuration; _text = State(initialValue: field.value.displayValue) }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(field.nodeType)  #\(field.nodeID)").font(.caption).foregroundColor(.secondary)
                if restoredDraft { Text("已恢复上次未完成的编辑").font(.caption).foregroundColor(.mint) }
                if field.schema.isUpload {
                    Button { pickingFile = true } label: { Label(store.busy ? "上传中…" : "上传参考素材", systemImage: "arrow.up.doc").frame(minHeight: 44) }.disabled(store.busy)
                }
                if field.schema.kind == .choice && !field.schema.isUpload {
                    TextField("搜索选项", text: $filter).textFieldStyle(.roundedBorder)
                    List {
                        if !field.schema.options.contains(where: { $0.displayValue == text }) { Text("当前值：\(text)").foregroundColor(.orange) }
                        ForEach(filteredChoices.indices, id: \.self) { index in
                            let value = filteredChoices[index]
                            Button { text = value.displayValue } label: { HStack { Text(value.displayValue); Spacer(); if text == value.displayValue { Image(systemName: "checkmark") } } }
                        }
                    }.listStyle(.plain)
                } else if field.schema.kind == .boolean {
                    Toggle(field.name, isOn: Binding(get: { text == "true" }, set: { text = $0 ? "true" : "false" }))
                    Spacer()
                } else if configuration?.control == .multiline || (configuration?.control != .text && field.schema.multiline) {
                    TextEditor(text: $text).font(.body).padding(8).background(Palette.ink).cornerRadius(14)
                    Text("\(text.count) 字符").font(.caption).foregroundColor(.secondary)
                } else {
                    TextField(field.name, text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        .keyboardType(field.schema.kind == .integer || field.schema.kind == .decimal ? .numbersAndPunctuation : .default)
                    if field.name.lowercased().contains("seed") {
                        Button("随机种子") { text = String(UInt64.random(in: 0...4_294_967_295)) }.frame(minHeight: 44)
                        Toggle("每次生成使用新种子", isOn: $randomSeed)
                    }
                    if let min = field.schema.minimum, let max = field.schema.maximum { Text("范围：\(min.formatted()) 至 \(max.formatted())").font(.caption).foregroundColor(.secondary) }
                    Spacer()
                }
                if let error = error { Text(error).font(.caption).foregroundColor(.red) }
            }.padding(20).background(Palette.ink.ignoresSafeArea())
            .navigationTitle(configuration?.title(for: field) ?? field.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { leaving = true; store.saveEditorDraft(field.id, text: nil); presentation.wrappedValue.dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try store.edit(field, text: text); if field.name.lowercased().contains("seed") { try store.setRandomSeed(field.id, enabled: randomSeed) }; leaving = true; presentation.wrappedValue.dismiss() } catch { self.error = error.localizedDescription } }.disabled(store.busy) }
            }
        }.navigationViewStyle(.stack)
        .onAppear {
            randomSeed = store.selected?.randomSeedFields.contains(field.id) ?? false
            if let draft = store.editorDraft(field.id), draft != field.value.displayValue { text = draft; restoredDraft = true }
        }
        .onChange(of: text) { if !leaving { store.saveEditorDraft(field.id, text: $0) } }
        .onDisappear { store.saveDraftsNow() }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image, .movie, .audio], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await store.upload(url: url, field: field); if store.error == nil { text = store.canvas?.fields.first { $0.id == field.id }?.value.displayValue ?? text } else { error = store.error; store.error = nil } }
            } else if case .failure(let error) = result { self.error = error.localizedDescription }
        }
    }
}

struct ServerWorkflowLibrary: View {
    @EnvironmentObject var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    @State private var config: ServerConfig?
    @State private var users: [ComfyUser] = []
    @State private var userID = ""
    @State private var workflows: [ServerWorkflow] = []
    @State private var search = ""
    @State private var loading = false
    @State private var failure: String?
    @State private var importingID: String?
    private var filtered: [ServerWorkflow] { workflows.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("读取 ComfyUI 中已保存的工作流，导入为手机上的副本。").font(.subheadline).foregroundColor(.secondary)
                if config == nil {
                    Text("先连接你的 ComfyUI 服务器。").font(.headline)
                    Button("前往连接") { store.activeTab = 3; presentation.wrappedValue.dismiss() }.frame(minHeight: 44)
                } else {
                    if !users.isEmpty {
                        Picker("ComfyUI 用户", selection: $userID) {
                            Text("选择用户").tag("")
                            ForEach(users) { user in Text(user.name).tag(user.id) }
                        }.onChange(of: userID) { _ in Task { await refresh() } }.disabled(loading || store.busy)
                    }
                    TextField("搜索名称或文件夹", text: $search).textFieldStyle(.roundedBorder)
                    if loading { ProgressView("正在读取服务器…").frame(maxWidth: .infinity).padding() }
                    if let failure = failure {
                        Text(failure).font(.subheadline).foregroundColor(.orange).textSelection(.enabled)
                        if store.verificationRequired != nil {
                            Button("前往连接验证") { store.activeTab = 3; presentation.wrappedValue.dismiss() }.frame(minHeight: 44)
                        }
                    }
                    if !loading && failure == nil && workflows.isEmpty && (users.isEmpty || !userID.isEmpty) {
                        Text("还没有保存的工作流").font(.headline)
                        Text("请先在 ComfyUI 的工作流列表中保存文件，再点刷新。只存在于浏览器临时画布或其他服务器目录中的文件不会出现在这里。").font(.subheadline).foregroundColor(.secondary)
                    }
                    List(filtered) { workflow in
                        Button {
                            guard let config = config else { return }
                            importingID = workflow.id; failure = nil
                            Task {
                                let success = await store.importServerWorkflow(workflow, config: config, userID: userID.isEmpty ? nil : userID)
                                importingID = nil
                                if success { presentation.wrappedValue.dismiss() }
                                else { failure = store.importStatus }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "doc.text").foregroundColor(Palette.paper)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(workflow.name).foregroundColor(.primary)
                                    Text(workflow.path).font(.caption).foregroundColor(.secondary)
                                    if let size = workflow.size { Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(.caption2).foregroundColor(.secondary) }
                                }
                                Spacer()
                                if importingID == workflow.id { ProgressView() } else { Image(systemName: "arrow.down.to.line").font(.caption) }
                            }.padding(.vertical, 6)
                        }.disabled(loading || store.busy)
                    }.listStyle(.plain)
                }
                Spacer(minLength: 0)
            }.padding(20).background(Palette.ink.ignoresSafeArea())
            .navigationTitle("服务器工作流").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { presentation.wrappedValue.dismiss() }.disabled(store.busy) }
                ToolbarItem(placement: .confirmationAction) { Button("刷新") { Task { await load() } }.disabled(config == nil || loading || store.busy) }
            }
        }.navigationViewStyle(.stack)
        .task { await load() }
    }
    private func load() async {
        guard !loading else { return }
        if config != store.server { userID = ""; workflows = [] }
        config = store.server
        guard let config = config else { return }
        loading = true; failure = nil; workflows = []
        do {
            users = try await store.makeClient(config).workflowUsers()
            if !users.contains(where: { $0.id == userID }) { userID = "" }
        }
        catch { failure = error.localizedDescription; _ = store.noteVerification(error, config: config) }
        loading = false
        if failure == nil && (users.isEmpty || !userID.isEmpty) { await refresh() }
    }
    private func refresh() async {
        guard !loading, let config = config else { return }
        workflows = []; failure = nil
        guard users.isEmpty || !userID.isEmpty else { return }
        loading = true; defer { loading = false }
        do { workflows = try await store.makeClient(config).serverWorkflows(userID: userID.isEmpty ? nil : userID) }
        catch { failure = error.localizedDescription; _ = store.noteVerification(error, config: config) }
    }
}
