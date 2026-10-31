import SwiftUI
import AVKit
import ImageIO

func downsampledImage(_ url: URL, maxPixelSize: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixelSize] as CFDictionary) else { return nil }
    return UIImage(cgImage: image)
}

struct MediaSelection: Identifiable { let id = UUID(); let output: ComfyOutput; let job: GenerationJob }

struct GalleryPage: View {
    @EnvironmentObject var store: WorkbenchStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("作品").font(.system(size: 24, weight: .semibold))
                if store.jobs.allSatisfy({ $0.outputs.isEmpty && $0.text.isEmpty }) {
                    VStack(alignment: .leading, spacing: 14) { Image(systemName: "photo.on.rectangle.angled").font(.largeTitle); Text("生成的作品会出现在这里").font(.title3); Text("图片可设为聊天底图，视频可播放，也可以分享或保存到系统相册。").font(.subheadline).foregroundColor(.secondary) }.padding(24).glass()
                }
                ForEach(store.jobs.reversed()) { job in
                    if !job.outputs.isEmpty || !job.text.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(job.name).font(.headline)
                            Text(job.date, style: .date).font(.caption).foregroundColor(.secondary)
                            if !job.outputs.isEmpty { OutputStrip(job: job) }
                            ForEach(job.text.indices, id: \.self) { i in Text(job.text[i]).font(.body).textSelection(.enabled) }
                        }.padding(18).glass()
                    }
                }
            }.padding(24)
        }
    }
}

struct OutputStrip: View {
    let job: GenerationJob
    var compact = false
    @State private var selection: MediaSelection?
    var body: some View {
        let displayed = job.displayedOutputs
        VStack(alignment: .leading, spacing: 12) {
            if displayed.primary.count == 1, let output = displayed.primary.first {
                Button { selection = MediaSelection(output: output, job: job) } label: {
                    OutputThumbnail(output: output, job: job, prominent: true, compact: compact)
                }.buttonStyle(.plain)
            } else { row(displayed.primary) }
            if !displayed.other.isEmpty {
                DisclosureGroup("中间预览与其他输出（\(displayed.other.count)）") { row(displayed.other).padding(.top, 10) }
                    .font(.caption).foregroundColor(.secondary)
            }
        }.fullScreenCover(item: $selection) { MediaDetail(output: $0.output, job: $0.job) }
    }
    private func row(_ outputs: [ComfyOutput]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(outputs) { output in
                    Button { selection = MediaSelection(output: output, job: job) } label: { OutputThumbnail(output: output, job: job) }.buttonStyle(.plain)
                }
            }
        }
    }
}

func isVideo(_ output: ComfyOutput) -> Bool {
    ["mp4", "mov", "webm", "mkv", "m4v"].contains((output.filename as NSString).pathExtension.lowercased()) || output.kind == "videos"
}

struct OutputThumbnail: View {
    @EnvironmentObject var store: WorkbenchStore
    let output: ComfyOutput
    let job: GenerationJob
    var prominent = false
    var compact = false
    @State private var image: UIImage?
    @State private var failed = false
    private var previewHeight: CGFloat {
        if compact {
            let ratio = image.map { $0.size.width / max(1, $0.size.height) } ?? 1.33
            return min(230, max(100, 208 / ratio))
        }
        return prominent ? 280 : 164
    }
    var body: some View {
        ZStack {
            Palette.ink
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
                if isVideo(output) { Image(systemName: "play.fill").font(.system(size: 19, weight: .semibold)).frame(width: 46, height: 46).background(.black.opacity(0.35), in: Circle()).foregroundColor(.white) }
            } else {
                VStack(spacing: 8) {
                    if !failed { ProgressView() }
                    Image(systemName: isVideo(output) ? "play.circle" : "photo").font(.title)
                    Text(failed ? "封面暂不可用，点开查看" : "正在读取封面…").font(.caption2).lineLimit(2)
                }.padding(10)
            }
        }.frame(width: compact ? 208 : (prominent ? nil : 132), height: previewHeight)
            .frame(maxWidth: prominent && !compact ? .infinity : nil).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityLabel("查看 \(output.filename)")
            .task(id: job.id.uuidString + output.id) {
                image = nil; failed = false
                do {
                    let url = try await store.localMedia(output, job: job)
                    try Task.checkCancellation()
                    let preview: UIImage?
                    if isVideo(output) { preview = try await VideoPoster.image(at: url) }
                    else { preview = downsampledImage(url, maxPixelSize: 640) }
                    try Task.checkCancellation()
                    image = preview; failed = preview == nil
                } catch is CancellationError { }
                catch { if !Task.isCancelled { failed = true } }
            }
    }
}

/// Decode a bounded poster asynchronously, using the same authenticated local media as playback.
@MainActor enum VideoPoster {
    private static let cache: NSCache<NSURL, UIImage> = { let cache = NSCache<NSURL, UIImage>(); cache.countLimit = 32; cache.totalCostLimit = 24 * 1024 * 1024; return cache }()
    static func image(at url: URL) async throws -> UIImage {
        try Task.checkCancellation()
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        var lastError: Error = WorkflowError.invalid("无法读取视频封面。")
        // A short offset avoids common black lead-in frames; zero also handles very short clips.
        for seconds in [0.2, 0.0] {
            do {
                try Task.checkCancellation()
                let frame: CGImage = try await withCheckedThrowingContinuation { continuation in
                    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: seconds, preferredTimescale: 600))]) { _, image, _, result, error in
                        if result == .succeeded, let image = image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? WorkflowError.invalid("系统无法解码视频封面。")) }
                    }
                }
                try Task.checkCancellation()
                let image = UIImage(cgImage: frame)
                cache.setObject(image, forKey: url as NSURL, cost: frame.width * frame.height * 4)
                return image
            } catch is CancellationError { generator.cancelAllCGImageGeneration(); throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }
}

struct MediaDetail: View {
    @EnvironmentObject var store: WorkbenchStore
    @Environment(\.presentationMode) private var presentation
    let output: ComfyOutput
    let job: GenerationJob
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var share = false
    @State private var attempt = 0
    @State private var controls = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = player { VideoPlayer(player: player) }
            else if let image = image {
                FittedArtwork(image: image).ignoresSafeArea().contentShape(Rectangle()).onTapGesture { controls.toggle() }
                    .accessibilityLabel("生成图片，轻触显示操作").accessibilityAddTraits(.isButton)
            } else if let error = error {
                VStack(spacing: 18) { Text(error).font(.subheadline); Button("重试") { attempt += 1 } }.padding(24)
            } else { ProgressView("正在读取作品…") }
            VStack {
                HStack {
                    Button { presentation.wrappedValue.dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44).glass(22) }.accessibilityLabel("关闭图片")
                    Spacer()
                    if controls || image == nil { Button { share = true } label: { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44).glass(22) }.accessibilityLabel("分享或保存").disabled(url == nil) }
                }
                Spacer()
                if controls, let image = image {
                    Button("设为聊天背景") { store.setBackground(image); presentation.wrappedValue.dismiss(); store.activeTab = 0 }.padding(.horizontal, 22).frame(height: 44).glass(22)
                }
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }.statusBar(hidden: true).preferredColorScheme(.dark)
        .task(id: attempt) {
            error = nil
            do {
                let local = try await store.localMedia(output, job: job); url = local
                if isVideo(output) || ["mp3", "wav", "m4a", "flac", "ogg"].contains(local.pathExtension.lowercased()) {
                    if ["webm", "mkv", "ogg"].contains(local.pathExtension.lowercased()) { error = "iOS 15 无法预览此媒体格式，请点分享在其他应用打开。" }
                    else { player = AVPlayer(url: local) }
                } else { image = downsampledImage(local, maxPixelSize: 2400); if image == nil { error = "系统无法预览此格式，可以通过分享在其他应用打开。" } }
            } catch { self.error = error.localizedDescription }
        }.onDisappear { player?.pause() }
        .sheet(isPresented: $share) { if let url = url { ShareSheet(items: [url]) } }
    }
}
