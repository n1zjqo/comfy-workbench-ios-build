import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchView: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var clean = false
    @State private var photoPicker = false
    var body: some View {
        ZStack {
            ArtworkBackground(image: store.background)
            VStack(spacing: 0) {
                Group {
                    switch store.activeTab {
                    case 0: ChatView(clean: $clean)
                    case 1: WorkflowPage()
                    case 2: GalleryPage()
                    default: ConnectionPage()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !clean {
                    HStack(spacing: 0) {
                        tab(0, "对话", "bubble.left.and.bubble.right")
                        tab(1, "应用", "slider.horizontal.3")
                        tab(2, "作品", "square.stack")
                        tab(3, "连接", "network")
                    }.padding(.vertical, 7).glass(26).padding(.horizontal, 18).padding(.bottom, 6)
                }
            }
            if clean { CrystalFrame() }
        }
        .tint(Palette.paper)
        .alert("提示", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil }
        } message: { Text(store.error ?? "") }
        .onChange(of: store.activeTab) { _ in clean = false }
    }
    private func tab(_ index: Int, _ title: String, _ icon: String) -> some View {
        Button { store.activeTab = index } label: {
            VStack(spacing: 4) { Image(systemName: icon).font(.system(size: 19)); Text(title).font(.caption) }
                .foregroundColor(store.activeTab == index ? .white : .white.opacity(0.55))
                .frame(maxWidth: .infinity).frame(minHeight: 44)
                .background(store.activeTab == index ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityAddTraits(store.activeTab == index ? .isSelected : [])
    }
}

struct ChatView: View {
    @EnvironmentObject var store: WorkbenchStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var clean: Bool
    @State private var message = ""
    @State private var photoPicker = false
    @GestureState private var drag: CGFloat = 0
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("创作对话").font(.title.bold())
                            Text(store.selected?.name ?? "选择一个工作流开始").font(.caption).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                        Button { photoPicker = true } label: { Image(systemName: "photo").frame(width: 44, height: 44).glass(16) }.accessibilityLabel("更换聊天底图")
                        Button { toggleClean(true) } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44).glass(16) }.accessibilityLabel("清屏")
                    }.padding(.horizontal, 24).padding(.top, 18)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Spacer(minLength: 70)
                                if store.jobs.isEmpty {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("让画面，留在眼前。").font(.system(size: 28, weight: .medium, design: .serif))
                                        Text("选好工作流，输入提示词开始生成。\n右滑清屏，左滑回来。").font(.subheadline).foregroundColor(.white.opacity(0.75)).lineSpacing(5)
                                    }.padding(24).padding(.top, 100)
                                }
                                ForEach(store.jobs) { job in JobBubble(job: job).id(job.id) }
                            }.padding(.horizontal, 22).padding(.bottom, 10)
                        }.onChange(of: store.jobs.count) { _ in
                            if let last = store.jobs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        if let field = store.currentPromptField {
                            Text("提示词入口：\(field.nodeType)  #\(field.nodeID) / \(field.name)").font(.caption2).foregroundColor(.white.opacity(0.65)).lineLimit(1)
                        }
                        HStack(alignment: .bottom, spacing: 10) {
                            TextField("描述你想生成的画面…", text: $message).font(.body).focused($focused).padding(.vertical, 13)
                            Button {
                                let text = message; focused = false
                                Task { await store.submit(message: text); if store.error == nil { message = "" } }
                            } label: {
                                Image(systemName: "arrow.up").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44).foregroundColor(Palette.ink).background(Palette.paper, in: Circle())
                            }.disabled(store.busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送提示词并生成")
                        }.padding(.horizontal, 14).padding(.vertical, 6).glass(28)
                    }.padding(.horizontal, 22).padding(.bottom, 14)
                }
                .offset(x: clean ? geo.size.width + 30 : max(0, drag))
                .opacity(clean ? 0 : 1 - Double(max(0, drag) / (geo.size.width * 1.4)))
                .allowsHitTesting(!clean).accessibilityHidden(clean)
                if clean {
                    VStack { Spacer(); Button { toggleClean(false) } label: {
                        Label("恢复", systemImage: "chevron.left").font(.caption).padding(.horizontal, 16).frame(height: 44).glass(22)
                    }.padding(.bottom, 22) }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: 28)
                .updating($drag) { value, state, _ in
                    if !focused && !clean && abs(value.translation.width) > abs(value.translation.height) * 1.7 { state = max(0, value.translation.width) }
                }
                .onEnded { value in
                    guard !focused, abs(value.translation.width) > abs(value.translation.height) * 1.7 else { return }
                    if !clean && value.translation.width > 85 { toggleClean(true) }
                    else if clean && value.translation.width < -65 { toggleClean(false) }
                })
        }.sheet(isPresented: $photoPicker) { PhotoPicker { store.setBackground($0) } }
    }
    private func toggleClean(_ value: Bool) {
        focused = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9)) { clean = value }
    }
}

struct JobBubble: View {
    @EnvironmentObject var store: WorkbenchStore
    let job: GenerationJob
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(job.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(); Text(job.date, style: .time).font(.caption2).foregroundColor(.secondary)
            }
            Text(job.message).font(.subheadline).lineLimit(5).textSelection(.enabled)
            Divider().overlay(.white.opacity(0.2))
            HStack {
                if !job.finished { ProgressView().scaleEffect(0.7) }
                Text(job.state).font(.caption)
                Spacer()
                if !job.finished { Button("取消排队") { Task { await store.cancel(job) } }.font(.caption).frame(minHeight: 44) }
            }
            if job.progress > 0 && !job.finished { ProgressView(value: job.progress) }
            ForEach(job.text.indices, id: \.self) { i in Text(job.text[i]).font(.subheadline).textSelection(.enabled) }
            if !job.outputs.isEmpty { OutputStrip(job: job) }
            if let detail = job.detail { Text(detail).font(.caption2).foregroundColor(.white.opacity(0.65)).lineLimit(4) }
        }.padding(17).glass(22)
    }
}

struct ConnectionPage: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var key = UUID().uuidString
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("连接你的 ComfyUI").font(.largeTitle.bold())
                Text("你的创作服务器").font(.title3)
                VStack(alignment: .leading, spacing: 16) {
                    Text("服务器地址").font(.caption).foregroundColor(.secondary)
                    TextField("http://192.168.1.20:8188", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    TextField("Basic Auth 用户名（如有）", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().padding(.vertical, 8)
                    SecureField("密码（如有）", text: $password).padding(.vertical, 8)
                    Button {
                        let config = ServerConfig(baseURL: address, username: username, passwordKey: key)
                        Task { await store.connect(config: config, password: password) }
                    } label: { HStack { if store.busy { ProgressView() }; Text("测试连接并保存").fontWeight(.semibold) }.frame(maxWidth: .infinity).frame(height: 48) }
                        .buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink).disabled(store.busy)
                    Text(store.connectionStatus).font(.caption).foregroundColor(.secondary)
                }.padding(20).glass()
                Text("填写手机可以访问的 ComfyUI 地址。保存前会读取节点定义，为模型列表和参数范围提供依据。").font(.subheadline).foregroundColor(.secondary)
                Text("离开 App 后，已提交的任务继续在服务器上运行。回到 App 会重新查询队列与结果。").font(.subheadline).foregroundColor(.secondary)
                Divider()
                Text("Comfy Workbench for iOS").font(.headline)
                Text("iOS 15.0+ · 原生 SwiftUI\n参考 Mimikkoro1/comfy-workbench-android\nGPL-3.0 · 非官方客户端").font(.caption).foregroundColor(.secondary)
            }.padding(24)
        }.onAppear {
            if let config = store.server { address = config.baseURL; username = config.username; key = config.passwordKey; password = (try? KeychainStore.password(for: key)) ?? "" }
        }
    }
}
