import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum Palette {
    static let ink = Color(red: 0.09, green: 0.17, blue: 0.23)
    static let paper = Color(red: 0.93, green: 0.95, blue: 0.96)
    static let sea = Color(red: 0.25, green: 0.42, blue: 0.48)
    static let rose = Color(red: 0.73, green: 0.57, blue: 0.61)
}

struct GlassSurface: ViewModifier {
    var radius: CGFloat = 22
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            if reduceTransparency { RoundedRectangle(cornerRadius: radius).fill(Palette.ink) }
            else { RoundedRectangle(cornerRadius: radius).fill(.ultraThinMaterial) }
        }
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(LinearGradient(colors: [.white.opacity(0.6), .white.opacity(0.08), .white.opacity(0.32)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }
}
extension View { func glass(_ radius: CGFloat = 22) -> some View { modifier(GlassSurface(radius: radius)) } }

struct ArtworkBackground: View {
    var image: UIImage?
    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.34, green: 0.48, blue: 0.56), Palette.ink, Color(red: 0.29, green: 0.25, blue: 0.33)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let image = image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                } else {
                    Ellipse().fill(Palette.paper.opacity(0.24)).frame(width: geo.size.width * 0.9, height: geo.size.height * 0.75).rotationEffect(.degrees(-32)).blur(radius: 40).offset(x: -90, y: -140)
                    Ellipse().fill(Palette.rose.opacity(0.5)).frame(width: 260, height: 420).blur(radius: 55).offset(x: 170, y: 180)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.08), .black.opacity(0.48)], startPoint: .top, endPoint: .bottom)
            }
        }.ignoresSafeArea()
    }
}

struct CrystalFrame: View {
    @Environment(\.accessibilityReduceTransparency) var reduceTransparency
    var body: some View {
        RoundedRectangle(cornerRadius: 35, style: .continuous)
            .strokeBorder(reduceTransparency ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.ultraThinMaterial), lineWidth: 12)
            .overlay(RoundedRectangle(cornerRadius: 35, style: .continuous).strokeBorder(LinearGradient(colors: [.white.opacity(0.85), .white.opacity(0.1), .white.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).strokeBorder(.white.opacity(0.17), lineWidth: 0.6).padding(10))
            .padding(.horizontal, 9).padding(.vertical, 7).allowsHitTesting(false).accessibilityHidden(true)
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
