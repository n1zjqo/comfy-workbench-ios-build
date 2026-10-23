import SwiftUI
import UniformTypeIdentifiers

struct WorkflowPage: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile = WorkflowFile(data: Data())
    @State private var allParameters = false
    @State private var editing: WorkflowField?
    @State private var graph = false
    @State private var manageFields = false
    @State private var search = ""
    @State private var pendingDelete: UUID?
    var fields: [WorkflowField] {
        guard let doc = store.document else { return [] }
        let base = allParameters ? doc.fields : doc.fields.filter { store.selected?.pinned.contains($0.id) == true }
        guard !search.isEmpty else { return base }
        return base.filter { "\($0.name) \($0.nodeType) \($0.nodeID)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("我的 AI 应用").font(.largeTitle.bold()); Text("让工作流变得顺手").font(.subheadline).foregroundColor(.secondary) }
                    Spacer()
                    Button { importing = true } label: { Image(systemName: "plus").font(.title3).frame(width: 44, height: 44).glass(16) }.accessibilityLabel("导入工作流")
                }
                if store.workflows.isEmpty { emptyState }
                else {
                    workflowSelector
                    HStack(spacing: 12) {
                        Button { graph = true } label: { Label("节点关系", systemImage: "point.3.connected.trianglepath.dotted").font(.caption).frame(minHeight: 44) }
                        Spacer()
                        Button { manageFields = true } label: { Label("配置面板", systemImage: "slider.horizontal.3").font(.caption).frame(minHeight: 44) }
                        Menu {
                            Button("导出 API JSON") {
                                do { exportFile = WorkflowFile(data: try store.document?.promptData(prettyPrinted: true) ?? Data()); exporting = true }
                                catch { store.error = error.localizedDescription }
                            }
                            Button("删除此应用", role: .destructive) { pendingDelete = store.selectedID }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("应用操作")
                    }.foregroundColor(Palette.paper)
                    Picker("参数范围", selection: $allParameters) { Text("应用参数").tag(false); Text("全部参数").tag(true) }.pickerStyle(.segmented)
                    if allParameters { TextField("搜索参数或节点", text: $search).padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)) }
                    if fields.isEmpty { Text("点“配置面板”选择你常用的参数。全部参数仍然可以查看。").font(.subheadline).foregroundColor(.secondary).padding(.vertical, 25) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(fields) { field in
                            Button { editing = field } label: { ParameterRow(field: field) }.buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }.background(Palette.ink.opacity(0.92), in: RoundedRectangle(cornerRadius: 20)).clipShape(RoundedRectangle(cornerRadius: 20))
                    if let count = store.document?.fields.count { Text("共 \(count) 个可编辑参数。连接保持原样；要修改连接的值，请编辑其上游节点。").font(.caption).foregroundColor(.secondary) }
                    Button { Task { await store.submit() } } label: {
                        HStack { if store.busy { ProgressView() }; Text("生成作品").font(.headline); Spacer(); Image(systemName: "sparkles") }.padding(.horizontal, 20).frame(height: 54)
                    }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink).disabled(store.busy)
                }
            }.padding(24).padding(.bottom, 12)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result { case .success(let urls): if let url = urls.first { Task { await store.importWorkflow(url) } }; case .failure(let error): store.error = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json, defaultFilename: store.selected?.name ?? "workflow") { result in if case .failure(let error) = result { store.error = error.localizedDescription } }
        .sheet(item: $editing) { FieldEditor(field: $0) }
        .sheet(isPresented: $graph) { NodeMapView() }
        .sheet(isPresented: $manageFields) { PanelConfiguration() }
        .alert("删除这个应用？", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) { if let id = pendingDelete { store.removeWorkflow(id) }; pendingDelete = nil }
        } message: { Text("只删除 App 中的工作流副本，不影响原文件和生成记录。") }
    }
    private var workflowSelector: some View {
        Menu {
            ForEach(store.workflows) { item in Button { store.select(item.id) } label: { Label(item.name, systemImage: item.id == store.selectedID ? "checkmark" : "square.stack") } }
            Button("导入工作流…") { importing = true }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 25)).frame(width: 50, height: 54).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 15))
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.selected?.name ?? "选择工作流").font(.headline).multilineTextAlignment(.leading).lineLimit(2)
                    Text("\(store.document?.nodes.count ?? 0) 个节点 · \(store.document?.connections.count ?? 0) 条连接").font(.caption).foregroundColor(.secondary)
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
            Button("导入工作流") { importing = true }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink).controlSize(.large)
            Text("API 格式可以离线编辑；普通画布格式需要先连接服务器。遇到无法可靠转换的自定义节点时，会指出原因。").font(.caption).foregroundColor(.secondary)
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
    @State private var text: String
    @State private var error: String?
    @State private var pickingFile = false
    @State private var filter = ""
    @State private var randomSeed = false
    private var filteredChoices: [JSONValue] { field.schema.options.filter { filter.isEmpty || $0.displayValue.localizedCaseInsensitiveContains(filter) } }
    init(field: WorkflowField) { self.field = field; _text = State(initialValue: field.value.displayValue) }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(field.nodeType)  #\(field.nodeID)").font(.caption).foregroundColor(.secondary)
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
                } else if field.schema.multiline {
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
            .navigationTitle(field.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { presentation.wrappedValue.dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try store.edit(field, text: text); if field.name.lowercased().contains("seed") { try store.setRandomSeed(field.id, enabled: randomSeed) }; presentation.wrappedValue.dismiss() } catch { self.error = error.localizedDescription } }.disabled(store.busy) }
            }
        }.navigationViewStyle(.stack)
        .onAppear { randomSeed = store.selected?.randomSeedFields.contains(field.id) ?? false }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.image, .movie, .audio], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { await store.upload(url: url, field: field); if store.error == nil { text = store.document?.fields.first { $0.id == field.id }?.value.displayValue ?? text } else { error = store.error; store.error = nil } }
            } else if case .failure(let error) = result { self.error = error.localizedDescription }
        }
    }
}

struct PanelConfiguration: View {
    @EnvironmentObject var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("聊天提示词入口")) {
                    Picker("发送到", selection: Binding(get: { store.currentPromptField?.id ?? "" }, set: { store.choosePrompt($0) })) {
                        ForEach(store.document?.fields.filter { $0.schema.kind == .text && !$0.schema.isUpload } ?? []) { field in Text("\(field.nodeType) #\(field.nodeID) / \(field.name)").tag(field.id) }
                    }
                }
                Section(header: Text("固定在应用页的参数")) {
                    ForEach(store.document?.fields ?? []) { field in
                        Toggle(isOn: Binding(get: { store.selected?.pinned.contains(field.id) ?? false }, set: { store.pin(field, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 4) { Text(field.name); Text("\(field.nodeType) #\(field.nodeID)").font(.caption).foregroundColor(.secondary) }
                        }
                    }
                }
            }.navigationTitle("配置面板").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presentation.wrappedValue.dismiss() } } }
        }.navigationViewStyle(.stack)
    }
}

struct NodeMapView: View {
    @EnvironmentObject var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    @State private var editing: WorkflowField?
    var body: some View {
        NavigationView {
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.document?.nodes ?? []) { node in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(node.classType).font(.headline); Spacer(); Text("#\(node.id)").font(.caption).foregroundColor(.secondary) }
                            ForEach((store.document?.connections ?? []).filter { $0.targetNodeID == node.id }) { link in
                                HStack { Image(systemName: "arrow.turn.down.right").foregroundColor(Palette.rose); Text("#\(link.sourceNodeID) : \(link.sourceOutputIndex)"); Image(systemName: "arrow.right"); Text(link.targetInputName) }.font(.caption)
                            }
                            ForEach((store.document?.fields ?? []).filter { $0.nodeID == node.id }) { field in
                                Button { editing = field } label: { HStack { Text(field.name); Spacer(); Text(field.value.displayValue).lineLimit(1).foregroundColor(.secondary); Image(systemName: "pencil") }.font(.caption).frame(minHeight: 44) }.buttonStyle(.plain)
                            }
                        }.padding(16).frame(width: 320).background(Palette.ink, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.18)))
                    }
                }.padding(20)
            }.background(Color.black.opacity(0.2)).navigationTitle("节点关系").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presentation.wrappedValue.dismiss() } } }
        }.navigationViewStyle(.stack).sheet(item: $editing) { FieldEditor(field: $0) }
    }
}
