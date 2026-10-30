import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import WebKit

struct VerificationPage: Identifiable {
    let id = UUID()
    let url: URL
}

struct VerificationBrowser: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void
    func makeUIViewController(context: Context) -> VerificationBrowserController {
        VerificationBrowserController(url: url, onFinish: onFinish)
    }
    func updateUIViewController(_ controller: VerificationBrowserController, context: Context) {}
}

/// The provider renders its own live QR challenge. No scripts, credentials or cookies are extracted.
final class VerificationBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    let initialURL: URL
    let onFinish: () -> Void
    let webView: WKWebView
    private let domain = UILabel()
    private let statusLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let shareButton = UIButton(type: .system)
    private var observation: NSKeyValueObservation?
    private var hasPage = false
    private var started = false
    var startsAutomatically = true

    init(url: URL, onFinish: @escaping () -> Void) {
        initialURL = url; self.onFinish = onFinish
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 17/255, green: 30/255, blue: 39/255, alpha: 1)
        let title = UILabel(); title.text = "网页验证"; title.font = .systemFont(ofSize: 20, weight: .semibold); title.textColor = .white
        let done = button("完成检查", action: #selector(finish))
        let close = button("关闭", action: #selector(finish))
        let header = UIStackView(arrangedSubviews: [close, title, done]); header.axis = .horizontal; header.distribution = .equalSpacing; header.alignment = .center
        domain.font = .systemFont(ofSize: 13); domain.textColor = .lightGray; domain.numberOfLines = 2
        domain.text = initialURL.host; domain.accessibilityIdentifier = "verification-domain"
        statusLabel.font = .systemFont(ofSize: 14); statusLabel.textColor = .white; statusLabel.numberOfLines = 0
        statusLabel.text = "二维码由 DDNSTO 官方网页提供。可分享页面截图，再用微信扫一扫识别。"
        statusLabel.accessibilityIdentifier = "verification-status"
        let top = UIStackView(arrangedSubviews: [header, domain, statusLabel, progress]); top.axis = .vertical; top.spacing = 10
        let reload = button("刷新", action: #selector(reloadPage))
        let safari = button("Safari 打开", action: #selector(openSafari))
        shareButton.setTitle("分享验证页", for: .normal); shareButton.addTarget(self, action: #selector(sharePage), for: .touchUpInside); shareButton.isEnabled = false
        let actions = UIStackView(arrangedSubviews: [reload, safari, shareButton]); actions.axis = .horizontal; actions.distribution = .fillEqually
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.backgroundColor = .white; webView.isOpaque = true
        webView.allowsBackForwardNavigationGestures = true
        for item in [top, webView, actions] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), top.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: 44),
            webView.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12), webView.leadingAnchor.constraint(equalTo: view.leadingAnchor), webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: actions.topAnchor),
            actions.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10), actions.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            actions.heightAnchor.constraint(equalToConstant: 52), actions.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] web, _ in
            self?.progress.progress = Float(web.estimatedProgress)
        }
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard startsAutomatically, !started else { return }; started = true; reloadPage()
    }
    private func button(_ title: String, action: Selector) -> UIButton {
        let item = UIButton(type: .system); item.setTitle(title, for: .normal); item.addTarget(self, action: action, for: .touchUpInside); return item
    }
    static func isSecureWebURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }
    @objc private func finish() { onFinish() }
    @objc private func reloadPage() {
        let url = webView.url.flatMap { Self.isSecureWebURL($0) ? $0 : nil } ?? initialURL
        guard Self.isSecureWebURL(url) else { showError("验证入口必须是没有内嵌密码的 HTTPS 地址。"); return }
        hasPage = false; shareButton.isEnabled = false
        statusLabel.text = "正在加载官方验证页…"; progress.isHidden = false
        // Plain navigation only: no app API token or Authorization header accompanies this request.
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
    }
    @objc private func openSafari() {
        let url = webView.url.flatMap { Self.isSecureWebURL($0) ? $0 : nil } ?? initialURL
        guard Self.isSecureWebURL(url) else { return }
        UIApplication.shared.open(url)
    }
    @objc private func sharePage() {
        guard hasPage else { return }
        let snapshot = WKSnapshotConfiguration(); snapshot.rect = webView.bounds
        webView.takeSnapshot(with: snapshot) { [weak self] image, error in
            guard let self = self else { return }
            guard error == nil, let image = image else { self.showError("页面截图未成功，可直接使用手机截屏。"); return }
            let sheet = UIActivityViewController(activityItems: [image], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = self.shareButton
            sheet.popoverPresentationController?.sourceRect = self.shareButton.bounds
            self.present(sheet, animated: true)
        }
    }
    private func showError(_ text: String) { statusLabel.text = text; progress.isHidden = true }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.isHidden = false; hasPage = false; shareButton.isEnabled = false
        domain.text = webView.url?.host ?? initialURL.host
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        domain.text = webView.url?.host ?? initialURL.host; progress.isHidden = true; hasPage = true; shareButton.isEnabled = true
        statusLabel.text = "在下方完成官方验证。若有二维码，可分享页面截图供微信识别；完成后点“完成检查”。"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        showError("网页未能加载：\(error.localizedDescription)。可刷新或在 Safari 打开。")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { showError("验证页面已停止，请点刷新重新打开。"); hasPage = false; shareButton.isEnabled = false }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if Self.isSecureWebURL(url) || (url.absoluteString == "about:blank" && navigationAction.targetFrame?.isMainFrame == false) { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, url.scheme?.lowercased() == "weixin" { UIApplication.shared.open(url) }
        else { showError("此跳转无法在验证页中打开，可使用 Safari 继续。"); }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, Self.isSecureWebURL(url) { webView.load(URLRequest(url: url)) }
        return nil
    }
}

struct WorkflowPicker: UIViewControllerRepresentable {
    var onResult: (Result<URL, Error>?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onResult) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let result: (Result<URL, Error>?) -> Void
        init(_ result: @escaping (Result<URL, Error>?) -> Void) { self.result = result }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { result(nil); return }
            result(.success(url))
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { result(nil) }
    }
}

enum Palette {
    static let workspace = Color(red: 17/255, green: 28/255, blue: 38/255)
    static let surface = Color(red: 27/255, green: 45/255, blue: 58/255)
    static let ink = Color(red: 0.09, green: 0.17, blue: 0.23)
    static let paper = Color(red: 0.93, green: 0.95, blue: 0.96)
    static let sea = Color(red: 0.25, green: 0.42, blue: 0.48)
    static let rose = Color(red: 0.73, green: 0.57, blue: 0.61)
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    func body(content: Content) -> some View {
        let shape = GlassContour(radius: radius)
        content.background {
            ZStack {
                if reduceTransparency { Palette.ink }
                else { NativeFrost(); Color.white.opacity(0.025) }
                LinearGradient(colors: [.white.opacity(0.055), .clear, Color(red: 0.78, green: 0.91, blue: 0.96).opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }.clipShape(shape)
        }
        .overlay(shape.inset(by: 0.45).stroke(LinearGradient(colors: [.white.opacity(0.44), .white.opacity(0.035), .white.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6).clipShape(shape))
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
    }
}
extension View { func glass(_ radius: CGFloat = 22) -> some View { modifier(GlassSurface(radius: radius)) } }

/// One bounded, closed path for both the blur and its reflection. Oversized
/// continuous corners on short controls can produce protruding edge segments.
struct GlassContour: InsettableShape {
    var radius: CGFloat
    var amount: CGFloat = 0
    func path(in rect: CGRect) -> Path {
        let bounded = rect.insetBy(dx: amount, dy: amount)
        guard bounded.width > 0, bounded.height > 0 else { return Path() }
        let corner = ArtworkMetrics.radius(radius, size: rect.size, inset: amount)
        return Path(roundedRect: bounded, cornerRadius: corner)
    }
    func inset(by amount: CGFloat) -> GlassContour { var result = self; result.amount += amount; return result }
}

struct NativeFrost: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView { UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark)) }
    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}

struct ArtworkBackground: View {
    var image: UIImage?
    var clean = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = image {
                    if clean { FittedArtwork(image: image, margin: CGSize(width: 28, height: 112)) }
                    else {
                        ArtworkImageSurface(image: image).frame(width: geo.size.width, height: geo.size.height).clipped()
                        LinearGradient(stops: [.init(color: .black.opacity(0.18), location: 0), .init(color: .clear, location: 0.22), .init(color: .clear, location: 0.72), .init(color: .black.opacity(0.13), location: 1)], startPoint: .top, endPoint: .bottom)
                    }
                } else {
                    LinearGradient(colors: [Color(red: 0.34, green: 0.48, blue: 0.56), Palette.ink, Color(red: 0.29, green: 0.25, blue: 0.33)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Ellipse().fill(Palette.paper.opacity(0.24)).frame(width: geo.size.width * 0.9, height: geo.size.height * 0.75).rotationEffect(.degrees(-32)).blur(radius: 40).offset(x: -90, y: -140)
                    Ellipse().fill(Palette.rose.opacity(0.5)).frame(width: 260, height: 420).blur(radius: 55).offset(x: 170, y: 180)
                }
            }
        }.ignoresSafeArea()
    }
}

struct ArtworkImageSurface: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> UIImageView { let view = UIImageView(); view.contentMode = .scaleAspectFill; view.clipsToBounds = true; view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal); view.setContentCompressionResistancePriority(.defaultLow, for: .vertical); return view }
    func updateUIView(_ view: UIImageView, context: Context) { view.image = image }
}

struct FittedArtwork: View {
    let image: UIImage
    var margin = CGSize(width: 28, height: 112)
    @Binding var isZoomed: Bool
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    @GestureState private var pinch: CGFloat = 1
    @GestureState private var drag = CGSize.zero
    init(image: UIImage, margin: CGSize = CGSize(width: 28, height: 112), isZoomed: Binding<Bool> = .constant(false)) {
        self.image = image; self.margin = margin; _isZoomed = isZoomed
    }
    var body: some View {
        GeometryReader { geo in
            let size = ArtworkMetrics.fittedSize(image: image.size, available: CGSize(width: max(1, geo.size.width - margin.width), height: max(1, geo.size.height - margin.height)))
            let scale = min(8, max(1, zoom * pinch))
            let offset = ArtworkMetrics.constrainedPan(CGSize(width: pan.width + drag.width, height: pan.height + drag.height), image: size, viewport: geo.size, zoom: scale)
            ZStack {
                Color.black
                Image(uiImage: image).resizable().frame(width: size.width, height: size.height)
                    .clipShape(GlassContour(radius: 12 / scale)).scaleEffect(scale)
                    .overlay(CrystalFrame().frame(width: size.width * scale, height: size.height * scale))
                    .offset(offset)
            }.frame(width: geo.size.width, height: geo.size.height).clipped().contentShape(Rectangle())
                .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        zoom = min(8, max(1, zoom * value))
                        pan = ArtworkMetrics.constrainedPan(pan, image: size, viewport: geo.size, zoom: zoom)
                    })
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .updating($drag) { value, state, _ in if zoom > 1 { state = value.translation } }
                    .onEnded { value in
                        if zoom > 1 { pan = ArtworkMetrics.constrainedPan(CGSize(width: pan.width + value.translation.width, height: pan.height + value.translation.height), image: size, viewport: geo.size, zoom: zoom) }
                    })
                .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : min(8, max(2, max(geo.size.height / max(1, size.height), geo.size.width / max(1, size.width)))); pan = .zero }
                .accessibilityLabel("图片，可双指缩放、双击放大或还原")
                .accessibilityAction(named: "放大") { zoom = min(8, zoom * 2) }
                .accessibilityAction(named: "还原") { zoom = 1; pan = .zero }
                .onChange(of: geo.size) { _ in pan = .zero }
                .onChange(of: zoom) { isZoomed = $0 > 1 }
        }
    }
}

struct CrystalFrame: View {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    var body: some View {
        GlassContour(radius: 12).inset(by: 1.25)
            .stroke(reduceTransparency ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.ultraThinMaterial), lineWidth: 2.5)
            .overlay(GlassContour(radius: 12).inset(by: 0.4).stroke(LinearGradient(stops: [.init(color: .white.opacity(0.75), location: 0), .init(color: .white.opacity(0.08), location: 0.38), .init(color: Color(red: 0.78, green: 0.91, blue: 0.96).opacity(0.38), location: 0.72), .init(color: .white.opacity(0.65), location: 1)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6))
            .clipShape(GlassContour(radius: 12)).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    @Environment(\.presentationMode) var presentation
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(); config.filter = .images; config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentation.wrappedValue.dismiss()
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else { return }
            let onPick = parent.onPick
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                guard let image = image as? UIImage else { return }
                DispatchQueue.main.async { onPick(image) }
            }
        }
    }
}

struct ReferenceVideoPicker: UIViewControllerRepresentable {
    var onPick: (Result<URL, Error>) -> Void
    @Environment(\.presentationMode) private var presentation
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(); config.filter = .videos; config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ReferenceVideoPicker
        init(_ parent: ReferenceVideoPicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.presentation.wrappedValue.dismiss()
            guard let provider = results.first?.itemProvider else { return }
            let callback = parent.onPick
            // The provider removes its URL after this callback; retain our own bounded copy.
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                let result: Result<URL, Error> = Result {
                    if let error = error { throw error }
                    guard let url = url else { throw WorkflowError.invalid("无法读取所选视频，请先在相册下载后重试。") }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 150_000_000 else { throw WorkflowError.invalid("视频为空或超过 150 MB，请先压缩。") }
                    let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent("reference-" + UUID().uuidString).appendingPathExtension(ext)
                    try FileManager.default.copyItem(at: url, to: target)
                    return target
                }
                DispatchQueue.main.async { callback(result) }
            }
        }
    }
}

struct WorkflowFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
