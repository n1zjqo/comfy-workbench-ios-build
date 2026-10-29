import SwiftUI

struct CreationPage: View {
    @EnvironmentObject var strata: StrataStore
    @Binding var clean: Bool
    var body: some View {
        VStack(spacing: 0) {
            if !clean {
                Picker("创作方式", selection: $strata.assistantSelected) {
                    Text("ComfyUI 创作").tag(false)
                    Text("Strata 助手").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal, 24).padding(.top, 10)
            }
            if strata.assistantSelected { StrataChatPage() }
            else { ChatView(clean: $clean) }
        }
    }
}

struct PlacesConnectionPage: View {
    @EnvironmentObject var strata: StrataStore
    @EnvironmentObject var clipboard: ClipboardSyncStore
    @EnvironmentObject var store: WorkbenchStore
    @State private var settings = false
    @State private var comfySettings = false
    @State private var confirmation: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("连接").font(.system(size: 26, weight: .semibold))
                VStack(alignment: .leading, spacing: 12) {
                    Label("家里", systemImage: "house").font(.headline)
                    Button { store.activeTab = 4 } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "doc.on.clipboard").font(.title3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("剪贴板中心").font(.body.weight(.medium))
                                Text(clipboard.archive.profile == nil ? "前往配对电脑" : clipboard.route).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(18).glass(20)
                    }.buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Label("办公室", systemImage: "building.2").font(.headline)
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Strata").font(.system(size: 22, weight: .semibold))
                                Text(strata.route).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Button { Task { await strata.refresh(manual: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("刷新 Strata 状态")
                            Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("Strata 连接设置")
                        }
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(strata.status?.paused == true ? Color.orange : (strata.status?.online == true ? Color(red: 0.54, green: 0.78, blue: 0.78) : .gray)).frame(width: 7, height: 7).padding(.top, 6)
                            Text(strata.status?.title ?? (strata.profile.serverID.isEmpty ? "设置地址，连接办公室 5090" : "尚未确认服务状态")).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        }.frame(minHeight: 38, alignment: .topLeading)
                        if let gpu = strata.status?.gpu, let used = gpu["used_mib"], let total = gpu["total_mib"], total > 0 {
                            VStack(alignment: .leading, spacing: 7) {
                                HStack { Text("显存"); Spacer(); Text(String(format: "%.1f / %.1f GB", used / 1024, total / 1024)).monospacedDigit() }.font(.caption).foregroundColor(.secondary)
                                ProgressView(value: min(max(used / total, 0), 1)).tint(Color(red: 0.54, green: 0.78, blue: 0.78))
                            }
                        }
                        if strata.profile.serverID.isEmpty {
                            Button("设置办公室连接") { settings = true }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink)
                        } else if strata.status?.paused == true {
                            Button("恢复并加载模型") { Task { await strata.control("resume") } }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink)
                        } else {
                            HStack(spacing: 10) {
                                Button("加载模型") { Task { await strata.control("load") } }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink)
                                Button("释放显存") { confirmation = "release" }.buttonStyle(.bordered)
                                Button("暂停接收") { confirmation = "pause" }.buttonStyle(.bordered)
                            }.font(.subheadline)
                        }
                        Text("释放显存：空闲时卸载，下次对话自动加载。\n暂停接收：拒绝新请求，当前生成完成后卸载，手动恢复后继续。\n两项操作都会保留控制服务，方便你远程重新开启。").font(.caption).foregroundColor(.secondary).lineSpacing(4)
                        HStack {
                            if strata.busy { ProgressView().scaleEffect(0.8); Text("操作进行中").font(.caption) }
                            Spacer()
                            Menu {
                                Button("重新加载模型") { confirmation = "reload" }
                                Button("释放 ComfyUI 驻留模型") { confirmation = "free_comfy" }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        }.frame(height: 32)
                    }.padding(18).glass(22).disabled(strata.busy)
                    Button { comfySettings = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "square.stack.3d.up").font(.title3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("ComfyUI").font(.body.weight(.medium))
                                Text(store.connectionStatus).font(.caption).foregroundColor(.secondary).lineLimit(2)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(18).glass(20)
                    }.buttonStyle(.plain)
                }
                Text("每个地点分别保存地址。同一局域网直连，离开后使用该地点的 HTTPS 入口。").font(.caption).foregroundColor(.secondary)
            }.padding(24)
        }
        .sheet(isPresented: $settings) { StrataSettings() }
        .sheet(isPresented: $comfySettings) {
            NavigationView { ConnectionPage().navigationTitle("ComfyUI").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { comfySettings = false } } } }.navigationViewStyle(.stack)
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            Button("确认操作") { if let action = confirmation { Task { await strata.control(action) } }; confirmation = nil }
            Button("取消", role: .cancel) { confirmation = nil }
        }
    }
    private var confirmationTitle: String {
        switch confirmation {
        case "pause": return "暂停接收新请求？当前生成会继续完成，之后卸载模型。后续任务步骤等待手动恢复；这不会立即中断正在生成的内容。"
        case "release": return "空闲时卸载 Strata 模型？后续聊天可以自动唤醒。"
        case "free_comfy": return "释放办公室 ComfyUI 的驻留模型？仅在运行和等待队列均为空时执行。"
        default: return "空闲时卸载并重新加载办公室 Strata 模型？"
        }
    }
}

struct StrataSettings: View {
    @EnvironmentObject var strata: StrataStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var lan = ""
    @State private var internet = ""
    @State private var token = ""
    @State private var browserOpened = false
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("办公室 5090"), footer: Text("填写 Strata 控制桥的地址，不能填写 ComfyUI 域名。局域网不可达时自动尝试公网，并校验同一台设备。")) {
                    TextField("局域网 HTTP 地址", text: $lan).keyboardType(.URL)
                    TextField("公网 HTTPS 地址", text: $internet).keyboardType(.URL)
                    SecureField(strata.profile.serverID.isEmpty ? "Strata API 密钥" : "新密钥（留空沿用）", text: $token)
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    Button("检测并保存") { Task { await strata.configure(lan: lan, internet: internet, token: token) } }.disabled(strata.busy)
                    Button("打开公网验证") {
                        do {
                            let url = try ClipboardEndpoint.url(internet, publicAddress: true).appendingPathComponent("workbench/info")
                            browserOpened = true; UIApplication.shared.open(url)
                        } catch { strata.notice = error.localizedDescription }
                    }.disabled(internet.isEmpty)
                    Text(strata.route).font(.caption).foregroundColor(.secondary)
                    if let notice = strata.notice { Text(notice).font(.caption).fixedSize(horizontal: false, vertical: true) }
                }
                Section(footer: Text("全局暂停需要办公室控制桥作为唯一入口。原推理服务应只监听服务器本机，避免其他客户端绕过暂停。")) {
                    Text("首次接入需部署控制桥").font(.subheadline)
                }
            }.navigationTitle("Strata 连接").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.navigationViewStyle(.stack)
            .onAppear { lan = strata.profile.lanURL; internet = strata.profile.publicURL }
            .onChange(of: phase) { value in if value == .active && browserOpened { browserOpened = false; Task { await strata.configure(lan: lan, internet: internet, token: token) } } }
    }
}

struct StrataChatPage: View {
    @EnvironmentObject var strata: StrataStore
    @EnvironmentObject var store: WorkbenchStore
    @State private var mode = 0
    @State private var image: UIImage?
    @State private var photoPicker = false
    @State private var imagePreview = false
    @State private var review: StrataTask?
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Strata 助手").font(.system(size: 22, weight: .semibold))
                    Text("办公室 5090 · " + (strata.status?.title ?? "尚未连接")).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                Menu {
                    Button("开始新对话") { strata.clearChat() }.disabled(strata.chatting)
                    Button("连接设置") { store.activeTab = 3 }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).glass(16) }
            }.padding(.horizontal, 24).padding(.top, 14)
            Picker("用途", selection: $mode) { Text("对话").tag(0); Text("任务").tag(1) }.pickerStyle(.segmented).padding(.horizontal, 24)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if mode == 0 {
                        if strata.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("和办公室的模型聊聊").font(.title3.weight(.medium))
                                Text("文字和图片发送给办公室 5090。任务模式可以整理指定目录里的文件，并在写入前交给你确认。").font(.subheadline).foregroundColor(.secondary).lineSpacing(4)
                            }.padding(.vertical, 36)
                        }
                        ForEach(strata.messages) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(message.role == "user" ? "你" : "Strata").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                                if let data = message.image, let picture = UIImage(data: data) { Image(uiImage: picture).resizable().scaledToFit().frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 12)) }
                                Text(message.content.isEmpty ? "正在思考…" : message.content).font(.body).textSelection(.enabled)
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).glass(18)
                        }
                    } else {
                        if strata.tasks.isEmpty { taskGuide }
                        ForEach(strata.tasks) { task in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Text(task.title).font(.headline).lineLimit(2); Spacer(); Text(task.stateLabel).font(.caption) }
                                Text("执行位置：办公室 5090").font(.caption).foregroundColor(.secondary)
                                ForEach(Array(task.events.enumerated()), id: \.offset) { _, event in Text(event).font(.caption).foregroundColor(.secondary) }
                                if !task.output.isEmpty { Text(task.output).font(.subheadline).textSelection(.enabled) }
                                HStack {
                                    if task.pending != nil { Button("查看并确认写入") { review = task }.buttonStyle(.borderedProminent) }
                                    if !task.finished { Button("取消任务", role: .destructive) { Task { await strata.taskAction(task, action: "cancel") } }.buttonStyle(.bordered) }
                                }.disabled(strata.busy)
                            }.padding(16).glass(18)
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let selectedImage = image, mode == 0 {
                    StrataAttachmentPreview(image: selectedImage, open: { imagePreview = true }, remove: { image = nil })
                }
                HStack(spacing: 10) {
                    if mode == 0 { Button { photoPicker = true } label: { Image(systemName: "photo").frame(width: 36, height: 44) }.accessibilityLabel("添加图片") }
                    TextField(mode == 0 ? "给 Strata 发消息…" : "描述文件任务…", text: $strata.draft).padding(.vertical, 12)
                    if strata.chatting {
                        Button { strata.stopChat() } label: { Image(systemName: "stop.fill").frame(width: 44, height: 44) }.accessibilityLabel("停止接收")
                    } else {
                        Button {
                            if mode == 0 { strata.send(image: image); if strata.chatting { image = nil } }
                            else { Task { await strata.startTask() } }
                        } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 44, height: 44).foregroundColor(Palette.ink).background(Palette.paper, in: Circle()) }.disabled(strata.busy || strata.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel(mode == 0 ? "发送消息" : "开始任务")
                    }
                }.padding(.horizontal, 10).padding(.vertical, 5).glass(26)
            }.padding(.horizontal, 22).padding(.bottom, 12)
        }
        .sheet(isPresented: $photoPicker) { PhotoPicker { image = $0 } }
        .sheet(isPresented: $imagePreview) {
            NavigationView {
                Group {
                    if let selectedImage = image { FittedArtwork(image: selectedImage, margin: CGSize(width: 24, height: 32)) }
                    else { Color.black }
                }
                .navigationTitle("待发送图片").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { imagePreview = false } } }
            }.navigationViewStyle(.stack)
        }
        .sheet(item: $review) { task in
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("办公室 5090").font(.headline)
                        Text("新文件：" + (task.pending?.arguments["path"] ?? "")).font(.subheadline)
                        Text(task.pending?.arguments["content"] ?? "").font(.body).textSelection(.enabled)
                        Button("确认创建此文件") { Task { await strata.taskAction(task, action: "approve"); review = nil } }.buttonStyle(.borderedProminent).disabled(strata.busy)
                    }.padding(24)
                }.navigationTitle("确认文件内容").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { review = nil } } }
            }.navigationViewStyle(.stack)
        }
        .onDisappear { strata.save() }
        .onChange(of: strata.draft) { _ in strata.scheduleDraftSave() }
    }

    private var taskGuide: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("让 Strata 处理任务文件").font(.title3.weight(.medium))
            Text("在办公室 5090 的专用目录中列文件、读取文本，或生成新的文本文件。选择一个示例后，再点发送。").font(.subheadline).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { strata.draft = "列出任务目录中的文件。" } label: {
                Label("列出任务文件", systemImage: "list.bullet").frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
            Button { strata.draft = "写一份三条事项的工作清单，建议一个未使用的新文件名；先展示文件内容，等我确认后再创建。" } label: {
                Label("生成一份工作清单", systemImage: "doc.badge.plus").frame(minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
            Text("创建文件前，你会看到文件名和完整内容，确认后才会写入。当前不支持操作桌面软件、任意运行命令或直接读取手机文件。").font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 24)
    }
}

struct StrataAttachmentPreview: View {
    let image: UIImage
    let open: () -> Void
    let remove: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: 68, height: 68)
                    .padding(4).background(Palette.workspace)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            }.buttonStyle(.plain).accessibilityLabel("预览待发送图片")
            VStack(alignment: .leading, spacing: 5) {
                Text("已选图片").font(.subheadline.weight(.medium))
                Text("轻点查看大图").font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("移除已选图片")
        }.padding(.horizontal, 6).padding(.vertical, 4)
    }
}
