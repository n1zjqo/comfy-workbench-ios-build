import SwiftUI

struct ClipboardPage: View {
    @EnvironmentObject var sync: ClipboardSyncStore
    @EnvironmentObject var store: WorkbenchStore
    @State private var settings = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) { Text("随手同步").font(.system(size: 28, weight: .semibold)); Text("在另一块屏幕接着用").font(.subheadline).foregroundColor(.white.opacity(0.65)) }
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
                            if entry.kind == "image", let data = Data(base64Encoded: entry.data ?? ""), let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12))
                            } else { Text(entry.text ?? "").font(.body).lineLimit(8).textSelection(.enabled) }
                            HStack {
                                Button { sync.copy(entry) } label: { Label("复制", systemImage: "doc.on.doc").frame(minHeight: 44) }
                                Spacer()
                                if let text = entry.text, store.selected != nil {
                                    Button("用作提示词") { store.setChatDraft(text); store.activeTab = 0 }.frame(minHeight: 44)
                                } else if entry.kind == "image", let data = Data(base64Encoded: entry.data ?? ""), let image = UIImage(data: data) {
                                    Button("设为底图") { store.setBackground(image); store.activeTab = 0 }.frame(minHeight: 44)
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

struct ClipboardSettings: View {
    @EnvironmentObject var sync: ClipboardSyncStore
    @Environment(\.dismiss) private var dismiss
    @State private var lan = ""
    @State private var internet = ""
    @State private var name = UIDevice.current.name
    @State private var code = ""
    @State private var browser: VerificationPage?
    @State private var disconnect = false
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("连接同一个同步中心")) {
                    TextField("局域网地址，如 http://192.168.1.20:8899", text: $lan).keyboardType(.URL)
                    TextField("公网 HTTPS 地址（可稍后填写）", text: $internet).keyboardType(.URL)
                    Text("在同一网络先连局域网；无法直连时尝试公网。地址对应的中心不匹配时，不会发送配对凭据。").font(.caption).foregroundColor(.secondary)
                    if sync.archive.profile != nil { Button("保存双地址") { Task { await sync.saveAddresses(lan: lan, internet: internet) } }.disabled(sync.busy) }
                }
                Section(header: Text(sync.archive.profile == nil ? "配对设备" : "重新配对")) {
                    TextField("设备名", text: $name)
                    TextField("电脑上显示的配对码", text: $code).keyboardType(.numberPad)
                    Button { Task { await sync.pair(lan: lan, internet: internet, code: code, name: name); if sync.archive.profile != nil { code = "" } } } label: { HStack { Text("配对并连接"); Spacer(); if sync.busy { ProgressView() } } }.disabled(sync.busy || code.isEmpty)
                    Text("电脑端：连接 → 启动本机中心 → 设备 → 开启配对。配对码限时有效，只能使用一次。").font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("外网验证")) {
                    Button("打开公网验证页面") { if let url = try? ClipboardEndpoint.url(internet, publicAddress: true) { browser = VerificationPage(url: url) } else { sync.notice = "请先填写有效的公网 HTTPS 地址" } }
                    Text("DDNSTO 需要验证时在网页完成，再回来重试。公网转发需保持电脑端运行。").font(.caption).foregroundColor(.secondary)
                }
                Section(header: Text("内容保留")) { Text("支持文字和 PNG 图片。单条文字最多 256 KB，图片最多 5 MB。历史最多 100 条、32 MB；待发送最多 30 条，超过 7 天请重新发送。首次连接只读取历史，不覆盖当前剪贴板。").font(.caption).foregroundColor(.secondary) }
                if sync.archive.profile != nil { Section { Button("断开配对并清除本机同步记录", role: .destructive) { disconnect = true }.disabled(sync.busy) } }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle("同步连接").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("完成") { dismiss() } } }
        }.onAppear { if let profile = sync.archive.profile { lan = profile.lanURL; internet = profile.publicURL; name = profile.deviceName } }
        .sheet(item: $browser, onDismiss: { sync.retry() }) { page in VerificationBrowser(url: page.url) { browser = nil }.ignoresSafeArea() }
        .alert("断开配对？", isPresented: $disconnect) { Button("取消", role: .cancel) {}; Button("断开并清除", role: .destructive) { sync.disconnect() } } message: { Text("将清除本机同步历史和待发送内容。电脑中心上的记录不受影响。") }
        .alert("同步", isPresented: Binding(get: { sync.notice != nil }, set: { if !$0 { sync.notice = nil } })) { Button("知道了") { sync.notice = nil } } message: { Text(sync.notice ?? "") }
    }
}
