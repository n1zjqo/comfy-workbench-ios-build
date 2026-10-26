import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SafariServices

struct VerificationPage: Identifiable {
    let id = UUID()
    let url: URL
}

struct VerificationBrowser: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        // Authentication stays in the system browser; no password or cookie is read by this app.
        let browser = SFSafariViewController(url: url)
        browser.delegate = context.coordinator
        return browser
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let finish: () -> Void
        init(_ finish: @escaping () -> Void) { self.finish = finish }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { finish() }
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
