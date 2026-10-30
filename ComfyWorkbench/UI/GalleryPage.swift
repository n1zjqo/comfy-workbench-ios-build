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
    @State private var selection: MediaSelection?
    var body: some View {
        let displayed = job.displayedOutputs
        VStack(alignment: .leading, spacing: 12) {
            if displayed.primary.count == 1, let output = displayed.primary.first {
                Button { selection = MediaSelection(output: output, job: job) } label: {
                    OutputThumbnail(output: output, job: job, prominent: true)
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
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Palette.ink
            if let image = image { Image(uiImage: image).resizable().scaledToFill() }
            else { VStack(spacing: 8) { Image(systemName: isVideo(output) ? "play.circle" : (failed ? "arrow.clockwise" : "photo")).font(.title); Text(output.filename).font(.caption2).lineLimit(2).padding(.horizontal, 8) } }
        }.frame(width: prominent ? nil : 132, height: prominent ? 280 : 164)
            .frame(maxWidth: prominent ? .infinity : nil).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityLabel("查看 \(output.filename)")
            .task(id: output.id) {
                guard !isVideo(output) else { return }
                do { let url = try await store.localMedia(output, job: job); image = downsampledImage(url, maxPixelSize: 420); failed = image == nil }
                catch { failed = true }
            }
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
