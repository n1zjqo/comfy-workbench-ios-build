import SwiftUI
import UniformTypeIdentifiers

struct WorkbenchView: View {
    @EnvironmentObject var store: WorkbenchStore
    @EnvironmentObject var strata: StrataStore
    @State private var clean = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    init(initiallyClean: Bool = false) { _clean = State(initialValue: initiallyClean) }
    var body: some View {
        ZStack {
            if store.activeTab == 0 && !strata.assistantSelected {
                ArtworkBackground(image: store.background)
            } else {
                Palette.workspace.ignoresSafeArea()
            }
            VStack(spacing: 0) {
                if let config = store.verificationRequired, [0, 1, 3].contains(store.activeTab) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("需要网页验证").font(.subheadline.weight(.semibold))
                            Text("验证后自动重新连接").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("去验证") { store.beginVerification(config: config) }.frame(minHeight: 44).disabled(store.busy)
                    }.padding(14).glass(20).padding(.horizontal, 18).padding(.top, 8)
                }
                Group {
                    switch store.activeTab {
                    case 0: CreationPage(clean: $clean)
                    case 1: WorkflowPage()
                    case 2: GalleryPage()
                    case 4: ClipboardPage()
                    default: PlacesConnectionPage()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Group {
                    HStack(spacing: 0) {
                        tab(0, "创作", "bubble.left.and.bubble.right")
                        tab(1, "应用", "slider.horizontal.3")
                        tab(2, "作品", "square.stack")
                        tab(4, "同步", "doc.on.clipboard")
                        tab(3, "连接", "network")
                    }.padding(.vertical, 5).glass(25).padding(.horizontal, 16).padding(.bottom, 6)
                }
            }
            .offset(x: clean ? UIScreen.main.bounds.width + 40 : 0).opacity(clean ? 0 : 1)
            .allowsHitTesting(!clean).accessibilityHidden(clean)
            if clean {
                Color.clear.contentShape(Rectangle()).ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 25).onEnded { value in
                        if value.translation.width < -65 && abs(value.translation.width) > abs(value.translation.height) * 1.7 { restoreChat() }
                    })
                    .onTapGesture(count: 2, perform: restoreChat)
                    .accessibilityLabel("聊天背景，向左滑动或双击恢复聊天")
                    .accessibilityAction(.escape) { restoreChat() }
                    .accessibilityIdentifier("clean-chat-background")
            }
        }
        .statusBar(hidden: clean)
        .tint(Palette.paper)
        .alert("提示", isPresented: Binding(get: { !clean && (store.error != nil || strata.notice != nil) }, set: { if !$0 && !clean { store.error = nil; strata.notice = nil } })) {
            Button("知道了", role: .cancel) { store.error = nil; strata.notice = nil }
        } message: { Text(store.error ?? strata.notice ?? "") }
        .onChange(of: store.activeTab) { _ in clean = false }
        .sheet(item: Binding(get: { store.verificationInSettings ? nil : store.verificationPage }, set: { store.verificationPage = $0 }), onDismiss: { Task { await store.finishVerification() } }) { page in
            VerificationBrowser(url: page.url) { store.verificationPage = nil }.ignoresSafeArea()
        }
    }
    private func restoreChat() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9)) { clean = false }
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
    @State private var expandedInput = false
    @GestureState private var drag: CGFloat = 0
    @FocusState private var focused: Bool
    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("创作").font(.system(size: 22, weight: .semibold))
                            Text(store.selected?.name ?? "选择一个工作流开始").font(.caption).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                        }
                        Spacer()
                        Button { toggleClean(true) } label: { Image(systemName: "viewfinder").frame(width: 44, height: 44).glass(16) }.accessibilityLabel("清屏")
                            .accessibilityIdentifier("creation-fullscreen")
                            .accessibilityHint("长按可恢复生成图或清除背景")
                            .contextMenu {
                                Button("恢复最新生成图背景") { Task { do { try await store.restoreLatestGeneratedBackground() } catch { store.error = error.localizedDescription } } }
                                Button("清除聊天背景", role: .destructive) { do { try store.clearBackground() } catch { store.error = error.localizedDescription } }
                            }
                    }.padding(.horizontal, 24).padding(.top, 18)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                Spacer(minLength: 70)
                                if store.jobs.isEmpty && store.background == nil {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("输入提示词，开始创作").font(.system(size: 22, weight: .medium))
                                        Text("生成图片将自动成为背景。\n右滑清屏，左滑回来。").font(.subheadline).foregroundColor(.white.opacity(0.75)).lineSpacing(5)
                                    }.padding(24).padding(.top, 100)
                                }
                                ForEach(store.jobs) { job in JobBubble(job: job).id(job.id) }
                            }.padding(.horizontal, 22).padding(.bottom, 10)
                        }.onChange(of: store.jobs.count) { _ in
                            if let last = store.jobs.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .bottom, spacing: 10) {
                            TextField("描述你想生成的画面…", text: $message).font(.body).focused($focused).padding(.vertical, 13)
                            Button { focused = false; expandedInput = true } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 44, height: 44)
                            }.accessibilityLabel("展开输入框")
                            Button {
                                let text = message, workflowID = store.selectedID; focused = false
                                Task { await store.submit(message: text); if store.error == nil && message == text && store.selectedID == workflowID { message = "" } }
                            } label: {
                                Image(systemName: "arrow.up").font(.system(size: 19, weight: .semibold)).frame(width: 44, height: 44).foregroundColor(Palette.ink).background(Palette.paper, in: Circle())
                            }.disabled(store.busy || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("发送提示词并生成")
                        }.padding(.horizontal, 14).padding(.vertical, 6).glass(28)
                    }.padding(.horizontal, 22).padding(.bottom, 14)
                }
                .offset(x: clean ? geo.size.width + 30 : max(0, drag))
                .opacity(clean ? 0 : 1 - Double(max(0, drag) / (geo.size.width * 1.4)))
                .allowsHitTesting(!clean).accessibilityHidden(clean)
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
        }
        .sheet(isPresented: $expandedInput) { ExpandedComposer(title: "编辑提示词", text: $message) }
        .onAppear { message = store.selected?.chatDraft ?? "" }
        .onChange(of: store.selectedID) { _ in message = store.selected?.chatDraft ?? "" }
        .onChange(of: message) { store.setChatDraft($0) }
    }
    private func toggleClean(_ value: Bool) {
        focused = false
        withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9)) { clean = value }
    }
}

struct JobBubble: View {
    @EnvironmentObject var store: WorkbenchStore
    let job: GenerationJob
    @State private var expandedPrompt = false
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text("你").font(.caption2.weight(.semibold)); Spacer(); Text(job.date, style: .time).font(.caption2).foregroundColor(.secondary) }
                    Text(job.message).font(.subheadline).lineLimit(expandedPrompt ? nil : 3).textSelection(.enabled)
                    if job.message.count > 110 {
                        Button(expandedPrompt ? "收起" : "展开全文") { expandedPrompt.toggle() }.font(.caption).frame(minHeight: 32)
                    }
                }.padding(12).background(Color(red: 0.32, green: 0.59, blue: 0.59).opacity(0.22), in: RoundedRectangle(cornerRadius: 17)).glass(17)
                    .contextMenu { Button("复制完整提示词") { UIPasteboard.general.string = job.message } }
            }
            HStack {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Text("ComfyUI").font(.caption2.weight(.semibold))
                        if !job.finished { ProgressView().scaleEffect(0.7) }
                        Text(job.state).font(.caption2).foregroundColor(.secondary)
                        Spacer(minLength: 0)
                        if !job.finished { Button("取消排队") { Task { await store.cancel(job) } }.font(.caption2).frame(minHeight: 32) }
                    }
                    Text(job.name).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    if job.progress > 0 && !job.finished { ProgressView(value: job.progress) }
                    ForEach(job.text.indices, id: \.self) { i in Text(job.text[i]).font(.subheadline).textSelection(.enabled) }
                    if !job.outputs.isEmpty { OutputStrip(job: job, compact: true) }
                    if let detail = job.detail { Text(detail).font(.caption2).foregroundColor(.white.opacity(0.65)).lineLimit(4) }
                }.padding(12).glass(17)
                Spacer(minLength: 48)
            }
        }.accessibilityIdentifier("generation-exchange")
    }
}

struct ConnectionPage: View {
    @EnvironmentObject var store: WorkbenchStore
    @State private var address = ""
    @State private var internet = ""
    @State private var username = ""
    @State private var password = ""
    @State private var key = UUID().uuidString
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("连接 ComfyUI").font(.system(size: 24, weight: .semibold))
                Text("你的创作服务器").font(.title3)
                VStack(alignment: .leading, spacing: 16) {
                    Text("服务器地址").font(.caption).foregroundColor(.secondary)
                    TextField("http://192.168.1.20:8188", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    TextField("公网 HTTPS（选填，自动切换）", text: $internet).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    TextField("Basic Auth 用户名（如有）", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().padding(.vertical, 8)
                    SecureField("密码（如有）", text: $password).padding(.vertical, 8)
                    Button {
                        let config = ServerConfig(baseURL: address, username: username, passwordKey: key, publicURL: internet.isEmpty ? nil : internet, serviceID: store.server?.serviceID)
                        Task { await store.connect(config: config, password: password) }
                    } label: { HStack { if store.busy { ProgressView() }; Text("测试连接并保存").fontWeight(.semibold) }.frame(maxWidth: .infinity).frame(height: 48) }
                        .buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink).disabled(store.busy)
                    Text(store.connectionStatus).font(.caption).foregroundColor(.secondary)
                }.padding(20).glass()
                Text("只填一个地址可继续使用现有服务。填写内外网双地址后，需服务器身份节点确认两条线路属于同一台电脑，才会自动切换。").font(.subheadline).foregroundColor(.secondary)
                Text("离开 App 后，已提交的任务继续在服务器上运行。回到 App 会重新查询队列与结果。").font(.subheadline).foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Label("外网访问 · DDNSTO", systemImage: "globe").font(.headline)
                    Text("打开官方验证页查看二维码；验证完成后点“完成检查”返回。").font(.subheadline).foregroundColor(.secondary)
                    Button {
                        store.beginVerification(config: ServerConfig(baseURL: address, username: username, passwordKey: key, publicURL: internet.isEmpty ? nil : internet, serviceID: store.server?.serviceID), password: password, inSettings: true)
                    } label: { Label("打开网页验证", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.bordered).disabled(store.busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("返回后只检查连接和查询任务。更换网络后可能需要再次验证；网页和 App 应使用相同网络出口。").font(.caption).foregroundColor(.secondary)
                }.padding(20).glass()
                Divider()
                Text("Comfy Workbench for iOS").font(.headline)
                Text("\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · iOS 15.0+\n参考 Mimikkoro1/comfy-workbench-android\nGPL-3.0 · 非官方客户端").font(.caption).foregroundColor(.secondary)
            }.padding(24)
        }.onAppear {
            if let config = store.server { address = config.baseURL; internet = config.publicURL ?? ""; username = config.username; key = config.passwordKey; password = (try? KeychainStore.password(for: key)) ?? "" }
        }
        .task { await store.refreshConnectionStatus() }
        .sheet(item: Binding(get: { store.verificationInSettings ? store.verificationPage : nil }, set: { store.verificationPage = $0 }), onDismiss: { Task { await store.finishVerification() } }) { page in
            VerificationBrowser(url: page.url) { store.verificationPage = nil }
        }
    }
}
