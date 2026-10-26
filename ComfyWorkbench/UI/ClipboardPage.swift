import SwiftUI
import ImageIO

struct ClipboardPage: View {
    @EnvironmentObject var sync: ClipboardSyncStore
    @EnvironmentObject var store: WorkbenchStore
    @State private var settings = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    Text("剪贴板").font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Button { settings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44).glass(16) }.accessibilityLabel("同步连接设置")
                }
                HStack(spacing: 9) {
                    Circle().fill(sync.route.contains("直连") || sync.route.contains("HTTPS") ? Color(red: 0.53, green: 0.83, blue: 0.8) : .gray).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 4) { Text(sync.route).font(.subheadline.weight(.medium)); Text(sync.status).font(.caption).foregroundColor(.white.opacity(0.65)) }
                    Spacer()
                    if sync.busy { ProgressView().scaleEffect(0.8) }
                    else { Button { sync.retry() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }.accessibilityLabel("重新连接") }
                }
                if sync.archive.profile == nil {
                    VStack(alignment: .leading, spacing: 15) {
                        Image(systemName: "laptopcomputer.and.iphone").font(.system(size: 34, weight: .light))
                        Text("先连接你的电脑").font(.title3.weight(.semibold))
                        Text("在电脑伴侣中启动同步中心、开启配对，然后在这里输入地址和配对码。").font(.subheadline).foregroundColor(.white.opacity(0.7))
                        Button("配对电脑") { settings = true }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading).glass()
                } else {
                    VStack(spacing: 17) {
                        Button { sync.sendCurrent() } label: { Label("发送当前剪贴板", systemImage: "paperplane").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48) }
                            .buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink)
                        Toggle("自动发送", isOn: Binding(get: { sync.archive.autoSend }, set: { sync.setAutomatic(send: $0) })).font(.subheadline)
                        Toggle("自动接收并复制", isOn: Binding(get: { sync.archive.autoReceive }, set: { sync.setAutomatic(receive: $0) })).font(.subheadline)
                        Text("自动同步仅在 App 前台运行。回到 App 后补同步；处理密码等内容时可关闭自动发送。").font(.caption).foregroundColor(.white.opacity(0.65)).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(20).glass()
                }
                if !sync.archive.outbox.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("待发送 \(sync.archive.outbox.count)").font(.headline)
                        ForEach(sync.archive.outbox) { input in
                            HStack { Text(input.kind == "image" ? "图片" : input.text ?? "").lineLimit(2).font(.subheadline); Spacer(); Button("移除") { sync.removePending(input.id) }.font(.caption).frame(minHeight: 44) }
                        }
                    }.padding(18).glass()
                }
                if !sync.archive.history.isEmpty { Text("最近同步").font(.subheadline.weight(.semibold)).foregroundColor(.white.opacity(0.65)) }
                LazyVStack(spacing: 14) {
                    ForEach(sync.archive.history) { entry in
                        VStack(alignment: .leading, spacing: 15) {
                            HStack { Text(entry.deviceName).lineLimit(1); Spacer(); Text(entry.date, style: .time) }.font(.caption).foregroundColor(.white.opacity(0.65))
                            if entry.kind == "image" {
                                ClipboardThumbnail(entry: entry)
                            } else { Text(entry.text ?? "").font(.body).lineLimit(8).textSelection(.enabled) }
                            HStack {
                                Button { sync.copy(entry) } label: { Label("复制", systemImage: "doc.on.doc").frame(minHeight: 44) }
                                Spacer()
                                if let text = entry.text, store.selected != nil {
                                    Button("用作提示词") { store.setChatDraft(text); store.activeTab = 0 }.frame(minHeight: 44)
                                } else if entry.kind == "image" {
                                    Button("设为底图") { if let image = ClipboardThumbnail.image(entry, maximum: 2400) { store.setBackground(image); store.activeTab = 0 } }.frame(minHeight: 44)
                                }
                            }.font(.caption.weight(.medium))
                        }.padding(20).glass()
                    }
                }
            }.padding(22)
        }
        .sheet(isPresented: $settings) { ClipboardSettings().environmentObject(sync) }
        .alert("同步", isPresented: Binding(get: { sync.notice != nil }, set: { if !$0 { sync.notice = nil } })) { Button("知道了") { sync.notice = nil } } message: { Text(sync.notice ?? "") }
    }
}

private struct ClipboardThumbnail: View {
    let entry: ClipboardEntry
    @State private var thumbnail: UIImage?
    var body: some View {
        Group {
            if let thumbnail = thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12)) }
            else { Image(systemName: "photo").frame(height: 100).frame(maxWidth: .infinity).foregroundColor(.secondary) }
        }.onAppear { thumbnail = Self.image(entry, maximum: 640) }.onDisappear { thumbnail = nil }
    }
    static func image(_ entry: ClipboardEntry, maximum: Int) -> UIImage? {
        guard let data = Data(base64Encoded: entry.data ?? ""), let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct ClipboardSettings: View {
    @EnvironmentObject var sync: ClipboardSyncStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var lan = ""
    @State private var internet = ""
    @State private var name = UIDevice.current.name
    @State private var code = ""
    @State private var useInternet = true
    @State private var checking = false
    @State private var connection: ClipboardConnection?
    @State private var connectionError: String?
    @State private var verificationPending = false
    @State private var loaded = false
    @State private var disconnect = false
    var body: some View {
        NavigationView {
            ZStack {
                Palette.workspace.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sync.archive.profile == nil ? "把电脑连到手机" : "连接设置").font(.system(size: 24, weight: .semibold))
                            Text("先确认地址可用，再输入电脑上的配对码。").font(.subheadline).foregroundColor(.secondary)
                        }
                        addressSection
                        if sync.archive.profile == nil {
                            pairingSection
                        } else {
                            Button {
                                Task { await sync.saveAddresses(lan: lan, internet: internet) }
                            } label: { Text("保存连接地址").fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 48) }
                                .buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink)
                                .disabled(sync.busy || checking || connection == nil)
                            DisclosureGroup("重新配对") { pairingSection.padding(.top, 16) }.font(.subheadline)
                            Button("断开配对", role: .destructive) { disconnect = true }.frame(minHeight: 44).disabled(sync.busy)
                        }
                        Text("电脑同步中心需要保持运行。首次连接只读取历史；自动发送与接收可在同步页单独开启。").font(.caption).foregroundColor(.secondary).lineSpacing(4)
                    }.padding(20)
                }
            }.navigationTitle("连接电脑").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() }.disabled(checking) } }
        }.navigationViewStyle(.stack).preferredColorScheme(.dark)
        .onAppear {
            guard !loaded else { return }; loaded = true
            if let profile = sync.archive.profile { lan = profile.lanURL; internet = profile.publicURL; name = profile.deviceName; useInternet = !internet.isEmpty }
        }
        .onChange(of: lan) { _ in invalidateConnection() }
        .onChange(of: internet) { _ in invalidateConnection() }
        .onChange(of: scenePhase) { phase in
            if phase == .active && verificationPending {
                verificationPending = false
                Task { await checkConnection() }
            }
        }
        .confirmationDialog("断开配对？", isPresented: $disconnect, titleVisibility: .visible) { Button("断开并清除", role: .destructive) { sync.disconnect() }; Button("取消", role: .cancel) {} } message: { Text("将清除本机同步历史和待发送内容。电脑中心上的记录不受影响。") }
        .alert("同步", isPresented: Binding(get: { sync.notice != nil }, set: { if !$0 { sync.notice = nil } })) { Button("知道了") { sync.notice = nil } } message: { Text(sync.notice ?? "") }
    }

    private var addressSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("1  电脑地址", systemImage: "network").font(.headline)
            Picker("当前网络", selection: $useInternet) { Text("外网").tag(true); Text("局域网").tag(false) }
                .pickerStyle(.segmented).disabled(checking || sync.busy)
            addressField(useInternet ? "公网 HTTPS 地址" : "局域网地址", placeholder: useInternet ? "https://你的域名" : "http://192.168.1.20:8899", text: useInternet ? $internet : $lan)
            DisclosureGroup(useInternet ? "添加局域网地址（可选）" : "添加公网地址（可选）") {
                addressField(useInternet ? "局域网地址" : "公网 HTTPS 地址", placeholder: useInternet ? "http://192.168.1.20:8899" : "https://你的域名", text: useInternet ? $lan : $internet).padding(.top, 12)
                Text("同时填写后，优先局域网，无法直连时尝试公网。").font(.caption).foregroundColor(.secondary).padding(.top, 8)
            }.font(.caption).disabled(checking || sync.busy)
            Button { Task { await checkConnection() } } label: {
                HStack { if checking { ProgressView() }; Text(checking ? "正在检测…" : "检测连接"); Spacer(); Image(systemName: "arrow.clockwise") }.frame(minHeight: 44)
            }.disabled(checking || sync.busy || (lan.isEmpty && internet.isEmpty))
            if let connection = connection {
                VStack(alignment: .leading, spacing: 5) {
                    Label("已连接电脑", systemImage: "checkmark.circle.fill").foregroundColor(.mint).font(.subheadline.weight(.medium))
                    Text(connection.route).font(.caption).foregroundColor(.secondary)
                }.accessibilityIdentifier("clipboard.connection.ready")
            }
            if let connectionError = connectionError {
                Label(connectionError, systemImage: "exclamationmark.circle").font(.subheadline).foregroundColor(Color(red: 0.96, green: 0.75, blue: 0.56)).fixedSize(horizontal: false, vertical: true)
            }
            if !internet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                Button(action: verifyInBrowser) { Label("打开系统浏览器验证", systemImage: "safari").font(.subheadline).frame(minHeight: 44) }.disabled(checking || sync.busy)
                Text("DDNSTO 需要验证时使用。验证后返回此处，会自动重新检测；若浏览器仍是空白，先确认域名正确并刷新。").font(.caption).foregroundColor(.secondary).lineSpacing(3)
            }
        }.padding(18).background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("2  配对电脑", systemImage: "link").font(.headline)
            if connection == nil { Text("检测连接成功后，即可输入配对码。").font(.subheadline).foregroundColor(.secondary) }
            VStack(alignment: .leading, spacing: 7) {
                Text("手机名称").font(.caption).foregroundColor(.secondary)
                TextField("我的 iPhone", text: $name).padding(12).background(Palette.workspace, in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("电脑上的配对码").font(.caption).foregroundColor(.secondary)
                TextField("输入配对码", text: $code).keyboardType(.numberPad).font(.system(size: 22, weight: .medium, design: .monospaced)).padding(12).background(Palette.workspace, in: RoundedRectangle(cornerRadius: 10))
            }
            Button {
                guard let connection = connection else { return }
                Task { await sync.pair(lan: lan, internet: internet, code: code, name: name, expectedHubID: connection.hubId); if sync.archive.profile != nil { code = "" } }
            } label: {
                HStack { if sync.busy { ProgressView() }; Text("配对并连接").fontWeight(.semibold) }.frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.borderedProminent).tint(Palette.paper).foregroundColor(Palette.ink)
                .disabled(connection == nil || sync.busy || checking || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("电脑端进入“设备”，点击“开启配对”。配对码限时有效，仅可使用一次。").font(.caption).foregroundColor(.secondary)
        }.disabled(checking || sync.busy).textInputAutocapitalization(.never).autocorrectionDisabled()
    }

    private func addressField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundColor(.secondary)
            TextField(placeholder, text: text).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.subheadline).padding(12).background(Palette.workspace, in: RoundedRectangle(cornerRadius: 10))
                .disabled(checking || sync.busy)
        }
    }
    private func invalidateConnection() { connection = nil; connectionError = nil }
    @MainActor private func checkConnection() async {
        guard !checking else { return }
        checking = true; connection = nil; connectionError = nil
        defer { checking = false }
        do { connection = try await sync.checkConnection(lan: lan, internet: internet) }
        catch { connectionError = error.localizedDescription }
    }
    private func verifyInBrowser() {
        do {
            let url = try ClipboardEndpoint.verificationURL(internet)
            verificationPending = true
            openURL(url) { accepted in
                if !accepted { verificationPending = false; connectionError = "无法打开浏览器，请在 Safari 手动打开已填写的域名后加 /v1/info" }
            }
        } catch { connectionError = error.localizedDescription }
    }
}
