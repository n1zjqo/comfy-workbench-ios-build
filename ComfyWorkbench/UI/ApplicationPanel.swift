import SwiftUI

struct EditHistoryBar: View {
    @EnvironmentObject private var store: WorkbenchStore
    var body: some View {
        HStack(spacing: 8) {
            Button { store.undoEdit() } label: { Label("撤销", systemImage: "arrow.uturn.backward").font(.caption).frame(minHeight: 44) }.disabled(!store.canUndo || store.busy)
            Button { store.redoEdit() } label: { Label("重做", systemImage: "arrow.uturn.forward").font(.caption).frame(minHeight: 44) }.disabled(!store.canRedo || store.busy)
            Spacer()
            Label("自动保存", systemImage: "checkmark.circle").font(.caption2).foregroundColor(.secondary)
        }
    }
}

struct ApplicationPanel: View {
    @EnvironmentObject private var store: WorkbenchStore
    let edit: (WorkflowField) -> Void
    var body: some View {
        let items = store.panelItems
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if let field = store.canvas?.fields.first(where: { $0.id == item.id }) {
                    if !item.group.isEmpty && (index == 0 || items[index - 1].group != item.group) {
                        Text(item.group).font(.system(size: 14, weight: .semibold)).foregroundColor(Palette.paper).padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)
                    }
                    ApplicationParameter(field: field, config: item, edit: { edit(field) })
                    if index < items.count - 1 { Divider().padding(.horizontal, 18) }
                }
            }
        }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 18)).clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct ApplicationParameter: View {
    @EnvironmentObject private var store: WorkbenchStore
    let field: WorkflowField
    let config: PanelFieldConfiguration
    let edit: () -> Void
    @State private var slider = 0.0
    private var title: String { config.title(for: field) }
    var body: some View {
        Group {
            if config.control == .slider, let range = config.sliderRange(for: field) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(title).font(.subheadline.weight(.medium)); Spacer(); Button { edit() } label: { Text(field.value.displayValue).monospacedDigit().font(.subheadline).frame(minHeight: 32) } }
                    Slider(value: $slider, in: range, step: config.step ?? field.schema.step ?? (field.schema.kind == .integer ? 1 : 0.1), onEditingChanged: { editing in
                        if !editing { save(field.schema.kind == .integer ? String(Int64(slider.rounded())) : String(slider)) }
                    }).tint(Color(red: 0.53, green: 0.83, blue: 0.8)).accessibilityLabel(title)
                    HStack { Text(range.lowerBound.formatted()); Spacer(); Text(range.upperBound.formatted()) }.font(.caption2).foregroundColor(.secondary)
                }.padding(18)
                    .onAppear { slider = min(range.upperBound, max(range.lowerBound, field.value.doubleValue ?? range.lowerBound)) }
                    .onChange(of: field.value) { value in slider = min(range.upperBound, max(range.lowerBound, value.doubleValue ?? range.lowerBound)) }
            } else if config.control == .toggle || (config.control == .automatic && field.schema.kind == .boolean) {
                Toggle(title, isOn: Binding(get: { field.value.boolValue ?? false }, set: { save($0 ? "true" : "false") })).font(.subheadline).tint(.mint).padding(18)
            } else if config.control == .choices {
                Menu {
                    ForEach(config.choices, id: \.self) { option in Button(option) { save(option) } }
                } label: {
                    HStack { Text(title).font(.subheadline.weight(.medium)); Spacer(); Text(field.value.displayValue).font(.subheadline).foregroundColor(.secondary).lineLimit(2); Image(systemName: "chevron.up.chevron.down").font(.caption2) }.padding(18).frame(minHeight: 64)
                }
            } else {
                Button(action: edit) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack { Text(title).font(.system(size: 15, weight: .medium)).foregroundColor(.white); Spacer(); Image(systemName: "pencil").font(.caption2).foregroundColor(.secondary) }
                        Text(field.value.displayValue.isEmpty ? "点此填写" : field.value.displayValue).font(.subheadline).foregroundColor(.white.opacity(0.64)).lineLimit(config.control == .multiline || field.schema.multiline ? 4 : 2).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(18).frame(minHeight: 68).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.disabled(store.busy)
    }
    private func save(_ text: String) {
        do { try store.edit(field, text: text) }
        catch { store.error = error.localizedDescription; slider = field.value.doubleValue ?? slider }
    }
}

struct PanelConfiguration: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    @State private var search = ""
    @State private var editing: PanelFieldConfiguration?
    private var available: [WorkflowField] {
        (store.canvas?.fields ?? []).filter { search.isEmpty || "\($0.name) \($0.nodeType) #\($0.nodeID)".localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("聊天提示词入口")) {
                    Picker("发送到", selection: Binding(get: { store.currentPromptField?.id ?? store.selected?.promptField ?? "" }, set: { store.choosePrompt($0) })) {
                        Text("自动选择").tag("")
                        ForEach(store.canvas?.fields.filter { $0.schema.kind == .text && !$0.schema.isUpload } ?? []) { field in Text("\(field.nodeType) #\(field.nodeID) / \(field.name)").tag(field.id) }
                    }
                }
                Section(header: Text("面板顺序"), footer: Text("拖动右侧把手排序。点击一项可修改显示名称、分组和控件；仅改变手机上的面板。")) {
                    ForEach(store.panelItems) { item in
                        if let field = store.canvas?.fields.first(where: { $0.id == item.id }) {
                            Button { editing = item } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title(for: field)).foregroundColor(.primary)
                                    Text("\(item.group.isEmpty ? "" : item.group + " · ")\(field.nodeType) #\(field.nodeID) / \(field.name)").font(.caption2).foregroundColor(.secondary)
                                }.padding(.vertical, 5)
                            }
                        }
                    }.onMove { source, destination in
                        var items = store.panelItems; items.move(fromOffsets: source, toOffset: destination)
                        do { try store.configurePanel(items) } catch { store.error = error.localizedDescription }
                    }.onDelete { offsets in
                        var items = store.panelItems; items.remove(atOffsets: offsets)
                        do { try store.configurePanel(items) } catch { store.error = error.localizedDescription }
                    }
                }
                Section(header: Text("添加或隐藏参数")) {
                    TextField("搜索参数或节点", text: $search).textInputAutocapitalization(.never)
                    ForEach(available) { field in
                        Toggle(isOn: Binding(get: { store.panelItems.contains { $0.id == field.id } }, set: { store.pin(field, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 4) { Text(field.name); Text("\(field.nodeType) #\(field.nodeID)").font(.caption2).foregroundColor(.secondary) }
                        }.tint(.mint)
                    }
                }
            }.environment(\.editMode, .constant(.active)).disabled(store.busy)
                .navigationTitle("自定义应用面板").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presentation.wrappedValue.dismiss() } } }
        }.navigationViewStyle(.stack)
        .sheet(item: $editing) { item in
            if let field = store.canvas?.fields.first(where: { $0.id == item.id }) { PanelFieldEditor(field: field, configuration: item) }
        }
    }
}

private struct PanelFieldEditor: View {
    @EnvironmentObject private var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    let field: WorkflowField
    @State private var config: PanelFieldConfiguration
    @State private var minimum: String
    @State private var maximum: String
    @State private var increment: String
    @State private var options: String
    @State private var error: String?
    init(field: WorkflowField, configuration: PanelFieldConfiguration) {
        self.field = field
        _config = State(initialValue: configuration)
        _minimum = State(initialValue: (configuration.minimum ?? field.schema.minimum).map { String($0) } ?? "")
        _maximum = State(initialValue: (configuration.maximum ?? field.schema.maximum).map { String($0) } ?? "")
        _increment = State(initialValue: (configuration.step ?? field.schema.step).map { String($0) } ?? "")
        _options = State(initialValue: (configuration.choices.isEmpty ? field.schema.options.map(\.displayValue) : configuration.choices).joined(separator: "\n"))
    }
    private var controls: [PanelFieldConfiguration.Control] {
        var values: [PanelFieldConfiguration.Control] = [.automatic]
        if [.text, .integer, .decimal].contains(field.schema.kind) { values.append(.text) }
        if field.schema.kind == .text { values.append(.multiline) }
        if (field.schema.kind == .integer || field.schema.kind == .decimal) && !field.name.lowercased().contains("seed") { values.append(.slider) }
        if field.schema.kind == .boolean { values.append(.toggle) }
        values.append(.choices); return values
    }
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("显示")) {
                    TextField("显示名称（留空使用参数名）", text: $config.label)
                    TextField("分组（可留空）", text: $config.group)
                    Text("\(field.nodeType) #\(field.nodeID) / \(field.name)").font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("控件")) {
                    Picker("类型", selection: $config.control) { ForEach(controls, id: \.self) { control in Text(title(control)).tag(control) } }
                    if config.control == .slider {
                        TextField("最小值", text: $minimum).keyboardType(.numbersAndPunctuation)
                        TextField("最大值", text: $maximum).keyboardType(.numbersAndPunctuation)
                        TextField("步长（可留空）", text: $increment).keyboardType(.numbersAndPunctuation)
                    }
                    if config.control == .choices {
                        Text("每行一个选项").font(.caption).foregroundColor(.secondary)
                        TextEditor(text: $options).frame(minHeight: 170).autocorrectionDisabled()
                    }
                }
                if let error = error { Section { Text(error).font(.caption).foregroundColor(.red) } }
            }.navigationTitle("参数外观").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { presentation.wrappedValue.dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(store.busy) }
                }
        }.navigationViewStyle(.stack)
    }
    private func title(_ control: PanelFieldConfiguration.Control) -> String {
        switch control { case .automatic: return "自动"; case .text: return "输入框"; case .multiline: return "多行文本"; case .slider: return "滑块"; case .choices: return "下拉选项"; case .toggle: return "开关" }
    }
    private func save() {
        do {
            if config.control == .slider {
                guard let low = Double(minimum), let high = Double(maximum) else { throw WorkflowError.invalid("请填写有效的范围数字。") }
                config.minimum = low; config.maximum = high
                if !increment.isEmpty { guard let step = Double(increment) else { throw WorkflowError.invalid("步长不是有效数字。") }; config.step = step }
                else { config.step = nil }
            }
            config.choices = options.components(separatedBy: .newlines).filter { !$0.isEmpty }
            try config.validate(for: field)
            var items = store.panelItems
            guard let index = items.firstIndex(where: { $0.id == config.id }) else { throw WorkflowError.invalid("此参数已从面板移除。") }
            items[index] = config; try store.configurePanel(items); presentation.wrappedValue.dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
