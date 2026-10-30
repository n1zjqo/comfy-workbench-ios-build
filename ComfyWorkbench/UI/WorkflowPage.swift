import SwiftUI
import UniformTypeIdentifiers
import AVKit

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
        let base = allParameters ? available : store.panelItems.compactMap { item in available.first { $0.id == item.id && !$0.schema.isUpload } }
        guard !search.isEmpty else { return base }
        return base.filter { "\($0.name) \($0.nodeType) \($0.nodeID)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("应用").font(.system(size: 24, weight: .semibold))
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
                    HStack(spacing: 4) {
                        Button { graph = true } label: { Label("画布", systemImage: "point.3.connected.trianglepath.dotted").font(.subheadline.weight(.medium)).padding(.horizontal, 14).frame(height: 44).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12)) }.disabled(store.canvas == nil)
                        Spacer()
                        Button { store.undoEdit() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44) }.accessibilityLabel("撤销").disabled(!store.canUndo || store.busy)
                        Button { store.redoEdit() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44) }.accessibilityLabel("重做").disabled(!store.canRedo || store.busy)
                        Menu {
                            Button { manageFields = true } label: { Label("自定义面板", systemImage: "slider.horizontal.3") }
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
                    ReferenceMaterialSection { editing = $0 }
                    Picker("参数范围", selection: $allParameters) { Text("常用参数").tag(false); Text("全部参数").tag(true) }.pickerStyle(.segmented)
                    if allParameters { TextField("搜索参数或节点", text: $search).padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12)) }
                    if fields.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(allParameters ? "没有匹配的参数" : "选择常用参数，组成自己的应用").font(.subheadline).foregroundColor(.secondary)
                            if !allParameters { Button("选择参数") { manageFields = true }.frame(minHeight: 44) }
                        }.padding(.vertical, 16)
                    }
                    if allParameters {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(fields) { field in
                                Button { editing = field } label: { ParameterRow(field: field) }.buttonStyle(.plain)
                                Divider().padding(.leading, 16)
                            }
                        }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
                    } else { ApplicationPanel { editing = $0 } }
                    HStack {
                        Label("更改自动保存", systemImage: "checkmark.circle").font(.caption2).foregroundColor(.secondary)
                        Spacer()
                        Button("自定义面板") { manageFields = true }.font(.caption).frame(minHeight: 44)
                    }
                    Button { Task { await store.submit() } } label: {
                        HStack { if store.busy { ProgressView() }; Text("生成作品").font(.headline); Spacer(); Image(systemName: "sparkles") }.padding(.horizontal, 20).frame(height: 54)
                    }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink).disabled(store.busy || store.document == nil)
                }
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 20)
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
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 20)).foregroundColor(Palette.paper.opacity(0.75))
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.selected?.name ?? "选择工作流").font(.system(size: 16, weight: .medium)).multilineTextAlignment(.leading).lineLimit(2)
                    Text("\(store.canvas?.nodes.count ?? 0) 个节点").font(.caption).foregroundColor(.secondary)
                }
                Spacer(minLength: 0); Image(systemName: "chevron.down").font(.caption)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
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
    @State private var filter = ""
    @State private var randomSeed = false
    @State private var leaving = false
    @State private var restoredDraft = false
    @State private var mediaUploading = false
    private var filteredChoices: [JSONValue] { field.schema.options.filter { filter.isEmpty || $0.displayValue.localizedCaseInsensitiveContains(filter) } }
    init(field: WorkflowField, configuration: PanelFieldConfiguration? = nil) { self.field = field; self.configuration = configuration; _text = State(initialValue: field.value.displayValue) }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(field.nodeType)  #\(field.nodeID)").font(.caption).foregroundColor(.secondary)
                if restoredDraft { Text("已恢复上次未完成的编辑").font(.caption).foregroundColor(.mint) }
                if field.schema.isUpload {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ReferenceMaterialEditor(field: field, value: $text, uploading: $mediaUploading)
                            TextField("服务器素材文件名", text: $text).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                        }
                    }
                } else if field.schema.kind == .choice {
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
                ToolbarItem(placement: .cancellationAction) { Button("取消") { leaving = true; store.saveEditorDraft(field.id, text: nil); presentation.wrappedValue.dismiss() }.disabled(mediaUploading || store.busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { do { try store.edit(field, text: text); if field.name.lowercased().contains("seed") { try store.setRandomSeed(field.id, enabled: randomSeed) }; leaving = true; presentation.wrappedValue.dismiss() } catch { self.error = error.localizedDescription } }.disabled(mediaUploading || store.busy) }
            }
        }.navigationViewStyle(.stack).interactiveDismissDisabled(mediaUploading || store.busy)
        .onAppear {
            randomSeed = store.selected?.randomSeedFields.contains(field.id) ?? false
            if let draft = store.editorDraft(field.id), draft != field.value.displayValue { text = draft; restoredDraft = true }
        }
        .onChange(of: text) { if !leaving { store.saveEditorDraft(field.id, text: $0) } }
        .onDisappear { store.saveDraftsNow() }
    }
}

extension WorkflowField {
    var materialKind: WorkflowFieldSchema.UploadKind {
        if let kind = schema.uploadKind, kind != .file { return kind }
        let name = name.lowercased(), type = nodeType.lowercased()
        if name.contains("audio") || type.contains("audio") { return .audio }
        if name.contains("video") || type.contains("video") { return .video }
        if name.contains("image") || type.contains("image") { return .image }
        return .file
    }
    var materialTitle: String {
        switch materialKind { case .image: return "参考图片"; case .video: return "参考视频"; case .audio: return "参考音频"; case .file: return "参考素材" }
    }
    var materialIcon: String {
        switch materialKind { case .image: return "photo"; case .video: return "video"; case .audio: return "waveform"; case .file: return "doc" }
    }
    var materialContentTypes: [UTType] {
        switch materialKind { case .image: return [.image]; case .video: return [.movie]; case .audio: return [.audio]; case .file: return [.item] }
    }
}

struct ReferenceMaterialSection: View {
    @EnvironmentObject private var store: WorkbenchStore
    let edit: (WorkflowField) -> Void
    @State private var ratios: [String: Double] = [:]
    @State private var playback: ReferencePlayback?
    @State private var loadingID: String?
    @State private var error: String?
    private var groups: [WorkflowReferenceGroup] { store.canvas?.referenceGroups ?? [] }
    private var inputs: [WorkflowReferenceInput] { groups.flatMap(\.inputs) }
    var body: some View {
        if !inputs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("参考素材").font(.headline); Spacer(); Text("已选 \(inputs.filter { !$0.field.value.displayValue.isEmpty }.count) / \(inputs.count)").font(.caption).monospacedDigit().foregroundColor(.secondary) }
                ForEach(groups) { group in
                    if groups.count > 1 { Text(groupTitle(group)).font(.caption.weight(.medium)).foregroundColor(Palette.paper.opacity(0.65)).padding(.top, 6) }
                    if group.layout == .rows {
                        ForEach(group.inputs) { input in
                            HStack(spacing: 8) {
                                Button { edit(input.field) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: input.field.materialIcon).font(.system(size: 24, weight: .light)).frame(width: 44, height: 52).foregroundColor(Palette.paper)
                                        caption(input)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if group.kind == .audio, !input.field.value.displayValue.isEmpty { playButton(input.field) }
                            }.padding(14).glass(16)
                        }
                    } else {
                        let rows = group.mediaRows(aspectRatios: ratios)
                        ForEach(rows.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(rows[index]) { input in
                                    VStack(alignment: .leading, spacing: 10) {
                                        Button { edit(input.field) } label: {
                                            VStack(alignment: .leading, spacing: 10) {
                                                ReferenceMaterialPreview(field: input.field, value: input.field.value.displayValue, compact: rows[index].count > 1, knownRatio: ratios[input.id]) { size in
                                                    let ratio = Double(size.width / max(1, size.height))
                                                    if abs((ratios[input.id] ?? 0) - ratio) > 0.01 { ratios[input.id] = ratio }
                                                }
                                                caption(input)
                                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                        if group.kind == .video, !input.field.value.displayValue.isEmpty {
                                            HStack { Text("预览视频").font(.caption).foregroundColor(.secondary); Spacer(); playButton(input.field) }
                                        }
                                    }.padding(12).frame(maxWidth: cardWidth(input, paired: rows[index].count > 1), alignment: .topLeading).glass(16)
                                }
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }
                if let error = error { Text(error).font(.caption).foregroundColor(.orange) }
            }.padding(.vertical, 6).disabled(store.busy)
                .sheet(item: $playback) { ReferencePlayer(url: $0.url) }
                .onChange(of: store.selectedID) { _ in ratios = [:]; error = nil; playback = nil }
        }
    }
    private func caption(_ input: WorkflowReferenceInput) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(input.role ?? input.field.materialTitle).font(.subheadline.weight(.medium)).foregroundColor(.white)
                Spacer(minLength: 0)
                Image(systemName: input.field.value.displayValue.isEmpty ? "plus.circle" : "arrow.triangle.2.circlepath").font(.caption).foregroundColor(Palette.paper.opacity(0.7))
            }
            if input.field.materialKind == .audio || input.field.materialKind == .file {
                Text(input.field.value.displayValue.isEmpty ? "点此添加" : (input.field.value.displayValue as NSString).lastPathComponent).font(.caption).foregroundColor(Palette.paper.opacity(0.75)).lineLimit(1)
            }
            Text("\(input.field.nodeType) #\(input.field.nodeID) / \(input.field.name)").font(.caption2).foregroundColor(.secondary).lineLimit(2)
            if input.destinations.count > 1 { Text("共用至 \(input.destinations.count) 个输入").font(.caption2).foregroundColor(.secondary) }
        }.accessibilityElement(children: .combine)
    }
    private func groupTitle(_ group: WorkflowReferenceGroup) -> String {
        let title: String
        switch group.kind { case .image: title = "图片"; case .video: title = "视频"; case .audio: title = "音频"; case .file: title = "文件" }
        return "\(title) · \(group.inputs.count)"
    }
    private func cardWidth(_ input: WorkflowReferenceInput, paired: Bool) -> CGFloat {
        guard !paired, let ratio = ratios[input.id], ratio > 0, ratio < 1 else { return .infinity }
        return max(180, CGFloat(ratio) * 360 + 24)
    }
    private func playButton(_ field: WorkflowField) -> some View {
        Button {
            let workflowID = store.selectedID, value = field.value.displayValue
            loadingID = field.id; error = nil
            Task { @MainActor in
                defer { loadingID = nil }
                do {
                    let url = try await store.referenceMediaURL(value)
                    guard store.selectedID == workflowID, store.canvas?.fields.first(where: { $0.id == field.id })?.value.displayValue == value else { return }
                    playback = ReferencePlayback(url: url)
                } catch { self.error = error.localizedDescription }
            }
        } label: {
            ZStack {
                Image(systemName: "play.fill").opacity(loadingID == field.id ? 0 : 1)
                if loadingID == field.id { ProgressView() }
            }.frame(width: 44, height: 44)
        }
        .disabled(loadingID != nil).accessibilityLabel(field.materialKind == .audio ? "试听音频" : "播放视频")
    }
}

struct ReferenceMaterialPreview: View {
    @EnvironmentObject private var store: WorkbenchStore
    let field: WorkflowField
    let value: String
    var compact = false
    var knownRatio: Double?
    var onDimensions: ((CGSize) -> Void)? = nil
    @State private var image: UIImage?
    @State private var failure = false
    private var ratio: CGFloat {
        if let image = image, image.size.height > 0 { return image.size.width / image.size.height }
        if let known = knownRatio, known.isFinite, known > 0 { return CGFloat(known) }
        return compact ? 1 : 1.65
    }
    var body: some View {
        ZStack {
            Palette.workspace
            if let image = image {
                Image(uiImage: image).resizable().scaledToFit()
                if field.materialKind == .video { Image(systemName: "play.circle.fill").font(.system(size: 26)).foregroundColor(.white).shadow(radius: 4) }
            }
            else {
                VStack(spacing: 9) {
                    Image(systemName: value.isEmpty ? "plus" : field.materialIcon).font(.system(size: compact ? 22 : 32, weight: .light))
                    Text(value.isEmpty ? "添加\(field.materialTitle.dropFirst(2))" : (failure ? "预览暂不可用" : (field.materialKind == .image ? "读取预览…" : (value as NSString).lastPathComponent)))
                        .font(.caption).lineLimit(2).multilineTextAlignment(.center)
                }.foregroundColor(.white.opacity(0.65)).padding(12)
            }
        }.aspectRatio(ratio, contentMode: .fit).frame(maxHeight: compact ? 280 : 360).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
            .task(id: "\(store.server?.baseURL ?? "")|\(field.id)|\(value)") {
                image = nil; failure = false
                guard !value.isEmpty, field.materialKind == .image || field.materialKind == .video else { return }
                do {
                    let url = try await store.referenceMediaURL(value)
                    let maxSize: CGFloat = compact ? 360 : 900
                    let loaded: UIImage?
                    if field.materialKind == .video {
                        loaded = try await Task.detached(priority: .utility) {
                            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: maxSize, height: maxSize)
                            return UIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))
                        }.value
                    } else { loaded = downsampledImage(url, maxPixelSize: Int(maxSize)) }
                    guard !Task.isCancelled else { return }; image = loaded; failure = loaded == nil
                    if let size = loaded?.size { onDimensions?(size) }
                } catch { if !Task.isCancelled { failure = true } }
            }
    }
}

struct ReferenceMaterialEditor: View {
    @EnvironmentObject private var store: WorkbenchStore
    let field: WorkflowField
    @Binding var value: String
    @Binding var uploading: Bool
    @State private var photos = false
    @State private var files = false
    @State private var error: String?
    @State private var playback: ReferencePlayback?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ReferenceMaterialPreview(field: field, value: value)
            HStack(spacing: 14) {
                if field.materialKind == .image || field.materialKind == .video {
                    Button { photos = true } label: { Label("相册", systemImage: "photo.on.rectangle").frame(minHeight: 44) }
                }
                Button { files = true } label: { Label("文件", systemImage: "folder").frame(minHeight: 44) }
                Spacer(minLength: 0)
                Button(role: .destructive) { value = ""; error = nil } label: { Label("清空", systemImage: "trash").frame(minHeight: 44) }.disabled(value.isEmpty)
            }.font(.subheadline).disabled(uploading || store.busy)
            if !value.isEmpty, field.materialKind == .audio || field.materialKind == .video {
                Button(field.materialKind == .audio ? "试听音频" : "播放视频") {
                    Task { do { playback = ReferencePlayback(url: try await store.referenceMediaURL(value)) } catch { self.error = error.localizedDescription } }
                }.frame(minHeight: 44).disabled(uploading || store.busy)
            }
            if uploading { ProgressView("正在上传素材…").font(.caption) }
            if let error = error { Text(error).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true) }
            Text("保存后应用到此参数。清空只移除当前选择，服务器原文件保留；必填输入需要重新选好素材才能运行。").font(.caption2).foregroundColor(.secondary)
        }
        .sheet(isPresented: $photos) {
            if field.materialKind == .image { PhotoPicker { image in Task { await upload { try await store.uploadReference(image: image) } } } }
            else { ReferenceVideoPicker { result in
                switch result {
                case .success(let url): Task { await upload { try await store.uploadReference(url: url) }; try? FileManager.default.removeItem(at: url) }
                case .failure(let failure): error = failure.localizedDescription
                }
            } }
        }
        .sheet(item: $playback) { ReferencePlayer(url: $0.url) }
        .fileImporter(isPresented: $files, allowedContentTypes: field.materialContentTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { Task { await upload { try await store.uploadReference(url: url) } } }
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
    @MainActor private func upload(_ work: () async throws -> String) async {
        guard !uploading else { return }
        let workflowID = store.selectedID
        uploading = true; error = nil; defer { uploading = false }
        do {
            let result = try await work()
            guard store.selectedID == workflowID else { throw WorkflowError.invalid("工作流已改变，请重新选择素材。") }
            value = result
        } catch { self.error = error.localizedDescription }
    }
}

private struct ReferencePlayback: Identifiable { let id = UUID(); let url: URL }
private struct ReferencePlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    var body: some View {
        NavigationView {
            VideoPlayer(player: player).navigationTitle("预览素材").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.navigationViewStyle(.stack).onAppear { player = AVPlayer(url: url) }.onDisappear { player?.pause() }
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
            store.noteConnected(config)
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
        do { workflows = try await store.makeClient(config).serverWorkflows(userID: userID.isEmpty ? nil : userID); store.noteConnected(config) }
        catch { failure = error.localizedDescription; _ = store.noteVerification(error, config: config) }
    }
}
