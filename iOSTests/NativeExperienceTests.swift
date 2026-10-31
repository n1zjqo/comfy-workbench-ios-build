import XCTest
import SwiftUI
import UIKit
import Combine
import WebKit
import AVFoundation
import CryptoKit
@testable import ComfyWorkbench

final class NativeExperienceTests: XCTestCase {
    @MainActor func testNestedControlsStayPinnedAfterRestartAndUndo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = Data(##"{"nodes":[{"id":150,"type":"sub","pos":[0,0],"size":[200,100]}],"links":[],"definitions":{"subgraphs":[{"id":"sub","nodes":[{"id":501,"type":"Text","pos":[20,40],"size":[100,80],"widgets_values":["example"]},{"id":502,"type":"Fast Groups Muter (rgthree)","pos":[500,0],"size":[200,100],"properties":{"showAllGraphs":false}}],"links":[],"groups":[{"id":8,"title":"Detail","bounding":[0,0,200,200],"color":"#88a"}]}]}}"##.utf8)
        let store = WorkbenchStore(storageURL: folder)
        let workflow = SavedWorkflow(name: "Synthetic nested controls", data: data)
        store.workflows = [workflow]; store.select(workflow.id)
        try store.showNodeInPanel("150", enabled: true)
        let field = try XCTUnwrap(store.canvas?.fields.first)
        XCTAssertEqual(store.panelItems.map(\.id), [field.id])
        try store.edit(field, text: "false")
        let restored = WorkbenchStore(storageURL: folder)
        XCTAssertEqual(restored.panelItems.map(\.id), [field.id])
        XCTAssertFalse(try XCTUnwrap(restored.canvas?.groupSwitches.first).enabled)
        restored.undoEdit(); XCTAssertEqual(restored.canvas?.root, try JSONValue(data: data))
        restored.redoEdit(); XCTAssertFalse(try XCTUnwrap(restored.canvas?.groupSwitches.first).enabled)
        let window = try host(ApplicationPanel { _ in }.environmentObject(restored).padding(20).background(Palette.workspace).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try capturePreview(window, name: "generic-nested-controls")
    }
    @MainActor func testGroupPanelSwitchPersistsAndUndoRestoresMixedModes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let data = Data(##"{"nodes":[{"id":1,"type":"Text","pos":[10,40],"size":[100,80],"widgets_values":["example"]},{"id":2,"type":"Text","pos":[120,40],"size":[100,80],"mode":2,"widgets_values":["other"]},{"id":98,"type":"Fast Groups Bypasser (rgthree)","pos":[-400,0],"size":[200,100]}],"links":[],"groups":[{"id":10,"title":"Refinement","bounding":[0,0,300,200],"color":"#528a9e"}]}"##.utf8)
        let workflow = SavedWorkflow(name: "Synthetic groups", data: data)
        store.workflows = [workflow]; store.select(workflow.id)
        try store.showNodeInPanel("98", enabled: true)
        XCTAssertEqual(store.panelItems.map(\.id), ["98.__group_id_10"])
        let field = try XCTUnwrap(store.canvas?.fields.first { $0.id == "98.__group_id_10" })
        try store.edit(field, text: "false")
        XCTAssertFalse(try XCTUnwrap(store.canvas?.groupSwitches.first).enabled)
        let restored = WorkbenchStore(storageURL: folder)
        XCTAssertFalse(try XCTUnwrap(restored.canvas?.groupSwitches.first).enabled)
        restored.undoEdit()
        XCTAssertEqual(restored.canvas?.root, try JSONValue(data: data))
        XCTAssertTrue(try XCTUnwrap(restored.canvas?.groupSwitches.first).partiallyEnabled)
        restored.redoEdit(); XCTAssertFalse(try XCTUnwrap(restored.canvas?.groupSwitches.first).enabled)
        let window = try host(ApplicationPanel { _ in }.environmentObject(restored).padding(20).background(Palette.workspace).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try capturePreview(window, name: "reference-group-panel")
    }
    @MainActor func testCleanCreationKeepsTheSameFullBleedBackground() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let strata = StrataStore(storage: folder.appendingPathComponent("strata.json"))
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 900)).image { ctx in
            UIColor.cyan.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            UIColor.red.setFill(); ctx.fill(CGRect(x: 120, y: 220, width: 360, height: 420))
        }
        store.background = picture; store.activeTab = 0
        let normal = try host(WorkbenchView().environmentObject(store).environmentObject(strata))
        let normalImage = try XCTUnwrap(descendants(normal).compactMap { $0 as? UIImageView }.first { $0.image === picture })
        let normalFrame = normalImage.convert(normalImage.bounds, to: normal)
        normal.isHidden = true
        let clean = try host(WorkbenchView(initiallyClean: true).environmentObject(store).environmentObject(strata))
        defer { clean.isHidden = true }
        let cleanImage = try XCTUnwrap(descendants(clean).compactMap { $0 as? UIImageView }.first { $0.image === picture })
        XCTAssertEqual(cleanImage.contentMode, .scaleAspectFill)
        XCTAssertEqual(cleanImage.convert(cleanImage.bounds, to: clean), normalFrame)
        let rendered = try capturePreview(clean, name: "reference-clean-creation")
        let expected = try host(ArtworkBackground(image: picture))
        defer { expected.isHidden = true }
        let baseline = try capturePreview(expected, name: "background-only-baseline")
        let actualPixel = try rgba(rendered), expectedPixel = try rgba(baseline)
        for x in stride(from: 30, through: 720, by: 69) {
            for y in stride(from: 80, through: 1510, by: 143) {
                let a = actualPixel(x,y), b = expectedPixel(x,y)
                XCTAssertLessThanOrEqual(abs(Int(a.0)-Int(b.0)) + abs(Int(a.1)-Int(b.1)) + abs(Int(a.2)-Int(b.2)), 6, "Clean mode must contain only the unchanged background")
            }
        }
    }
    @MainActor func testCompactConversationRendersRequestAndResponseSeparately() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        var job = GenerationJob(name: "Synthetic workflow", message: "A quiet shoreline in soft morning light.", promptData: Data("{}".utf8), server: ServerConfig(baseURL: "https://example.com"))
        job.finished = true; job.state = "已完成"; job.text = ["Synthetic generation response."]
        let window = try host(ScrollView { JobBubble(job: job).padding(22) }.background(Palette.workspace).environmentObject(store).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try capturePreview(window, name: "reference-compact-conversation")
    }
    @MainActor func testVideoPosterUsesDecodedFrameAndPreferredRotation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<6 {
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adapter.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixels = try XCTUnwrap(buffer); CVPixelBufferLockBaseAddress(pixels, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            for y in 0..<96 { for x in 0..<160 { let offset = y * stride + x * 4; base[offset] = 0; base[offset+1] = 0; base[offset+2] = 255; base[offset+3] = 255 } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adapter.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)))
        }
        input.markAsFinished(); await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        XCTAssertEqual(writer.status, .completed)
        let poster = try await VideoPoster.image(at: url)
        XCTAssertLessThan(poster.size.width, poster.size.height)
        XCTAssertLessThanOrEqual(max(poster.size.width, poster.size.height), 640)
        let pixel = try rgba(poster)(Int(poster.size.width / 2), Int(poster.size.height / 2))
        XCTAssertGreaterThan(pixel.0, 200); XCTAssertLessThan(pixel.1, 50); XCTAssertLessThan(pixel.2, 50)
        let cached = try await VideoPoster.image(at: url)
        XCTAssertTrue(cached === poster)
        // Exercise the real thumbnail view against the app's local-media cache, without a server.
        let store = WorkbenchStore(storageURL: folder)
        let output = ComfyOutput(filename: "synthetic.mp4", kind: "videos")
        let job = GenerationJob(name: "Synthetic video", message: "Example", promptData: Data("{}".utf8), server: ServerConfig(baseURL: "https://example.com"))
        let mediaFolder = folder.appendingPathComponent("media").appendingPathComponent(job.id.uuidString)
        try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        let digest = SHA256.hash(data: Data(output.id.utf8)).map { String(format: "%02x", $0) }.joined()
        try FileManager.default.copyItem(at: url, to: mediaFolder.appendingPathComponent(digest + ".mp4"))
        let window = try host(OutputThumbnail(output: output, job: job, prominent: true, compact: true).padding(20).background(Palette.workspace).environmentObject(store).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 500_000_000)
        let render = try capturePreview(window, name: "reference-video-poster")
        let renderedPixel = try rgba(render)
        var redSamples = 0
        for y in stride(from: 0, to: 1624, by: 8) { for x in stride(from: 0, to: 750, by: 8) {
            let pixel = renderedPixel(x,y)
            if pixel.0 > 180 && pixel.1 < 70 && pixel.2 < 70 { redSamples += 1 }
        } }
        XCTAssertGreaterThan(redSamples, 1000, "A video result must display its decoded poster rather than the empty tile")
    }
    @MainActor func testInactiveMixedReferencesAreVisibleWithoutFetchingOldMedia() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativeComfyProtocol.reset(); try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder, clientFactory: NativeComfyProtocol.client)
        store.server = ServerConfig(baseURL: "https://example.com")
        let workflow = SavedWorkflow(name: "Synthetic mixed references", data: Data(#"{"nodes":[{"id":1,"type":"LoadImage","mode":4,"widgets_values":["old.png"]},{"id":2,"type":"LoadImage","mode":2,"widgets_values":["second.png"]},{"id":3,"type":"VHS_LoadVideo","mode":4,"widgets_values":{"video":"old.mp4"}},{"id":4,"type":"LoadAudio","mode":4,"widgets_values":{"audio":"old.wav"}}],"links":[]}"#.utf8))
        store.workflows = [workflow]; store.select(workflow.id)
        let window = try host(ScrollView { ReferenceMaterialSection { _ in }.padding(20) }.background(Palette.workspace).environmentObject(store).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(store.canvas?.referenceGroups.map { $0.inputs.count }, [2, 1, 1])
        XCTAssertEqual(store.canvas?.referenceGroups.flatMap(\.inputs).filter(\.enabled).count, 0)
        XCTAssertTrue(NativeComfyProtocol.paths.isEmpty)
        try capturePreview(window, name: "reference-disabled-mixed")
    }
    @MainActor func testCommonParametersAreManualNodeSelectionsWithPersistentUndo() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("synthetic.json")
        try Data(#"{"1":{"class_type":"Sampler","inputs":{"steps":8,"cfg":1}},"2":{"class_type":"LoadImage","inputs":{"image":"synthetic.png"}}}"#.utf8).write(to: url)
        let store = WorkbenchStore(storageURL: folder)
        await store.importWorkflow(url)
        XCTAssertNil(store.error); XCTAssertTrue(store.panelItems.isEmpty)
        store.workflows[0].panelItems = nil; store.workflows[0].pinned = ["1.steps", "1.cfg"]
        XCTAssertTrue(store.panelItems.isEmpty) // Legacy automatic inference is no longer the panel.
        var manual = PanelFieldConfiguration(id: "1.steps"); manual.label = "采样步数"
        try store.configurePanel([manual])
        try store.showNodeInPanel("1", enabled: true)
        XCTAssertEqual(store.panelItems.first, manual)
        XCTAssertEqual(Set(store.panelItems.map(\.id)), ["1.steps", "1.cfg"])
        try store.showNodeInPanel("2", enabled: true)
        XCTAssertTrue(store.panelItems.contains { $0.id == "2.image" })
        let restored = WorkbenchStore(storageURL: folder)
        XCTAssertEqual(restored.panelItems, store.panelItems)
        restored.undoEdit(); XCTAssertFalse(restored.panelItems.contains { $0.id == "2.image" })
        restored.redoEdit(); XCTAssertTrue(restored.panelItems.contains { $0.id == "2.image" })
        try restored.showNodeInPanel("1", enabled: false)
        XCTAssertEqual(restored.panelItems.map(\.id), ["2.image"])
        restored.undoEdit(); XCTAssertEqual(restored.panelItems.first, manual)
        let window = try host(WorkflowPage().environmentObject(restored).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try capturePreview(window, name: "reference-manual-common-parameters")
    }
    @MainActor func testReferenceSaveAndEnableAreOneUndoableEdit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let workflow = SavedWorkflow(name: "Synthetic references", data: Data(#"{"nodes":[{"id":1,"type":"LoadImage","mode":4,"widgets_values":["old.png"],"outputs":[{"name":"IMAGE","type":"IMAGE"}]}],"links":[]}"#.utf8))
        store.workflows = [workflow]; store.select(workflow.id)
        let field = try XCTUnwrap(store.canvas?.fields.first)
        XCTAssertThrowsError(try store.editReference(field, text: "", enabled: true))
        XCTAssertEqual(store.canvas?.fields.first?.value, .string("old.png"))
        try store.editReference(field, text: "new.png", enabled: true)
        XCTAssertEqual(store.canvas?.nodes.first?.bypassed, false)
        XCTAssertEqual(store.selected?.journal?.past.count, 1)
        store.undoEdit()
        XCTAssertEqual(store.canvas?.nodes.first?.bypassed, true)
        XCTAssertEqual(store.canvas?.fields.first?.value, .string("old.png"))
        store.redoEdit()
        XCTAssertEqual(store.canvas?.fields.first?.value, .string("new.png"))
        try store.editReference(field, text: "", enabled: false)
        let restored = WorkbenchStore(storageURL: folder)
        XCTAssertEqual(restored.canvas?.nodes.first?.bypassed, true)
        restored.undoEdit()
        XCTAssertEqual(restored.canvas?.nodes.first?.bypassed, false)
        XCTAssertEqual(restored.canvas?.fields.first?.value, .string("new.png"))
    }
    @MainActor func testClearStaleBackgroundKeepsWorkflowAndPersists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let workflow = SavedWorkflow(name: "Synthetic", data: Data(#"{"1":{"class_type":"Text","inputs":{"text":"example"}}}"#.utf8))
        store.workflows = [workflow]; store.select(workflow.id)
        store.setBackground(testImage())
        try store.clearBackground()
        XCTAssertNil(store.background)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("background.jpg").path))
        let restored = WorkbenchStore(storageURL: folder)
        XCTAssertNil(restored.background); XCTAssertEqual(restored.selected?.data, workflow.data)
        let window = try host(ChatView(clean: .constant(false)).environmentObject(restored).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try capturePreview(window, name: "reference-chat-header")
    }
    @MainActor func testComfyConnectionProbeIsLightweightQuietAndReusesClient() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativeComfyProtocol.reset(); try? FileManager.default.removeItem(at: folder) }
        var creations = 0
        let store = WorkbenchStore(storageURL: folder, clientFactory: { config in
            creations += 1; return NativeComfyProtocol.client(config)
        })
        store.server = ServerConfig(baseURL: "https://example.com")
        await store.refreshConnectionStatus(force: true)
        XCTAssertEqual(store.connectionStatus, "已连接")
        var publications = 0
        let observation = store.objectWillChange.sink { publications += 1 }; defer { observation.cancel() }
        await store.refreshConnectionStatus(force: true)
        await store.refreshConnectionStatus() // Recent success needs no extra request.
        XCTAssertEqual(creations, 1); XCTAssertEqual(publications, 0)
        XCTAssertEqual(NativeComfyProtocol.paths, ["/system_stats", "/system_stats"])
    }

    @MainActor func testCompletedGenerationUpdatesConnectionAndRejectsOldProbeFailure() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativeComfyProtocol.reset(); try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder, clientFactory: NativeComfyProtocol.client)
        let config = ServerConfig(baseURL: "https://example.com"); store.server = config
        NativeComfyProtocol.holdStats = true
        let check = Task { await store.refreshConnectionStatus(force: true) }
        for _ in 0..<100 {
            if NativeComfyProtocol.hasPending { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(NativeComfyProtocol.hasPending)
        var job = GenerationJob(name: "Synthetic", message: "Synthetic", promptData: Data("{}".utf8), server: config)
        job.promptID = "synthetic-job"; store.jobs = [job]
        await store.poll()
        XCTAssertTrue(store.jobs[0].finished); XCTAssertEqual(store.connectionStatus, "已连接")
        NativeComfyProtocol.failOldProbe()
        await check.value
        XCTAssertEqual(store.connectionStatus, "已连接")
        XCTAssertFalse(NativeComfyProtocol.paths.contains("/object_info"))
        _ = store.noteVerification(ComfyAPIError(message: "old server", requiresBrowserVerification: true), config: ServerConfig(baseURL: "https://old.example.com"))
        XCTAssertEqual(store.connectionStatus, "已连接"); XCTAssertNil(store.verificationRequired)
    }

    @MainActor func testPhotoUploadIsDraftOnlyAndClearingOneReferenceCanBeUndone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativeComfyProtocol.reset(); try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder, clientFactory: NativeComfyProtocol.client)
        store.server = ServerConfig(baseURL: "https://example.com")
        let workflow = SavedWorkflow(name: "Two references", data: Data(#"{"1":{"class_type":"LoadImage","inputs":{"image":"first.png"}},"2":{"class_type":"LoadImage","inputs":{"image":"second.png"}}}"#.utf8))
        store.workflows = [workflow]; store.select(workflow.id)
        let background = testImage(); store.background = background
        let before = store.selected?.data
        let filename = try await store.uploadReference(image: background)
        XCTAssertEqual(filename, "references/uploaded.png")
        XCTAssertEqual(store.selected?.data, before); XCTAssertTrue(store.background === background); XCTAssertTrue(store.jobs.isEmpty)
        let first = try XCTUnwrap(store.canvas?.fields.first { $0.id == "1.image" })
        try store.edit(first, text: filename)
        try store.edit(first, text: "")
        XCTAssertEqual(store.canvas?.fields.first { $0.id == "1.image" }?.value, .string(""))
        XCTAssertEqual(store.canvas?.fields.first { $0.id == "2.image" }?.value, .string("second.png"))
        store.undoEdit()
        XCTAssertEqual(store.canvas?.fields.first { $0.id == "1.image" }?.value, .string(filename))
        XCTAssertEqual(NativeComfyProtocol.paths, ["/upload/image"])
    }

    @MainActor func testReferenceCardsRenderPortraitLandscapeAndMixedInputs() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { NativeComfyProtocol.reset(); try? FileManager.default.removeItem(at: folder) }
        let portrait = UIGraphicsImageRenderer(size: CGSize(width: 90, height: 160)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 90, height: 160))
        }
        NativeComfyProtocol.previewData = portrait.pngData()!
        NativeComfyProtocol.landscapeData = testImage().pngData()!
        let store = WorkbenchStore(storageURL: folder, clientFactory: NativeComfyProtocol.client)
        store.server = ServerConfig(baseURL: "https://example.com")
        let workflow = SavedWorkflow(name: "Mixed references", data: Data(#"{"1":{"class_type":"LoadImage","inputs":{"image":"portrait.png"}},"2":{"class_type":"LoadImage","inputs":{"image":""}},"3":{"class_type":"LoadAudio","inputs":{"audio":""}},"4":{"class_type":"VHS_LoadVideo","inputs":{"video":""}},"5":{"class_type":"MiniMaxH3ImageToVideo","inputs":{"first_frame":["1",0],"last_frame":["2",0]}}}"#.utf8))
        store.workflows = [workflow]; store.select(workflow.id)
        let window = try host(ScrollView { ReferenceMaterialSection { _ in }.padding(20) }.background(Palette.workspace).environmentObject(store).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try await Task.sleep(nanoseconds: 300_000_000)
        window.layoutIfNeeded()
        XCTAssertEqual(store.canvas?.referenceGroups.map(\.kind), [.image, .video, .audio])
        XCTAssertEqual(store.canvas?.referenceGroups.first?.inputs.first?.role, "首帧")
        XCTAssertTrue(store.jobs.isEmpty)
        try capturePreview(window, name: "reference-materials-portrait-mixed")
        var loadedSize: CGSize?
        let preview = try host(ReferenceMaterialPreview(field: try XCTUnwrap(store.canvas?.fields.first), value: "landscape.png") { loadedSize = $0 }
            .padding(20).environmentObject(store).preferredColorScheme(.dark))
        defer { preview.isHidden = true }
        for _ in 0..<100 { if loadedSize != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let dimensions = try XCTUnwrap(loadedSize)
        XCTAssertEqual(dimensions.width / dimensions.height, 2, accuracy: 0.01)
        let rendered = try capturePreview(preview, name: "reference-materials-landscape")
        let pixel = try rgba(rendered)
        let width = try XCTUnwrap(rendered.cgImage).width
        let height = try XCTUnwrap(rendered.cgImage).height
        var left = width, right = -1, bottom = height, top = -1
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                if color.0 > 240 && color.1 < 15 && color.2 < 15 {
                    left = min(left, x); right = max(right, x)
                    bottom = min(bottom, y); top = max(top, y)
                }
            }
        }
        // Measure the rendered image, not the flexible container or a deferred preference.
        XCTAssertGreaterThan(right - left, 600)
        XCTAssertEqual(Double(right - left + 1) / Double(max(1, top - bottom + 1)), 2, accuracy: 0.02)
    }

    @MainActor func testReleaseResultCannotBeOverwrittenByAnOlderStatusPoll() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { DelayedStrataProtocol.reset(); try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("strata.json")
        let saved: [String: Any] = ["profile": ["lanURL": "", "publicURL": "https://example.com", "serverID": DelayedStrataProtocol.identity, "tokenKey": "synthetic-test"], "messages": [], "tasks": [], "draft": ""]
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DelayedStrataProtocol.self]
        let strata = StrataStore(storage: file, client: StrataClient(configuration: config), credentialReader: { _ in "synthetic-token" })
        let refresh = Task { await strata.refresh() }
        for _ in 0..<100 {
            if DelayedStrataProtocol.hasPending { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(DelayedStrataProtocol.hasPending)
        await strata.control("release")
        XCTAssertEqual(strata.status?.loaded, false)
        XCTAssertTrue(strata.controlNotice?.contains("已卸载") == true)
        XCTAssertNil(strata.notice)
        DelayedStrataProtocol.releaseOldStatus()
        await refresh.value
        XCTAssertEqual(strata.status?.loaded, false)
        XCTAssertFalse(strata.busy)
        XCTAssertEqual(DelayedStrataProtocol.postCount, 1)
    }

    @MainActor func testVerificationPageKeepsProviderContentAndNativeRecoveryControls() throws {
        let controller = VerificationBrowserController(url: URL(string: "https://example.com/workbench/info")!, onFinish: {})
        controller.startsAutomatically = false
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        controller.view.layoutIfNeeded()
        XCTAssertTrue(controller.webView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(controller.webView.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(controller.webView.url) // Rendering alone must not contact a real service in tests.
        XCTAssertGreaterThan(controller.webView.bounds.height, 350)
        let titles = descendants(controller.view).compactMap { ($0 as? UIButton)?.title(for: .normal) }
        XCTAssertTrue(titles.contains("分享验证页")); XCTAssertTrue(titles.contains("Safari 打开")); XCTAssertTrue(titles.contains("完成检查"))
        XCTAssertTrue(VerificationBrowserController.isSecureWebURL(URL(string: "https://example.com/verify")!))
        for text in ["http://example.com", "https://user:secret@example.com", "file:///etc/passwd", "javascript:alert(1)"] {
            XCTAssertFalse(VerificationBrowserController.isSecureWebURL(URL(string: text)!))
        }
    }
    @MainActor func testNativeMessageSelectionKeepsSelectedTextDuringStreaming() throws {
        let window = try host(SelectableMessageText(text: "测试文字 hello world").padding(24).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        let view = try XCTUnwrap(descendants(window).compactMap { $0 as? SelectionTextView }.first)
        XCTAssertFalse(view.isEditable); XCTAssertTrue(view.isSelectable); XCTAssertFalse(view.isScrollEnabled)
        XCTAssertTrue(view.becomeFirstResponder())
        view.selectedRange = NSRange(location: 0, length: 4)
        view.pendingText = "测试文字 hello world\n后续的流式回答"
        view.applyPendingText()
        XCTAssertEqual(view.text, "测试文字 hello world")
        XCTAssertEqual(view.selectedRange, NSRange(location: 0, length: 4))
        view.selectedRange = NSRange(location: 0, length: 0)
        view.applyPendingText()
        XCTAssertEqual(view.text, view.pendingText)
        view.resignFirstResponder()
    }

    @MainActor func testLongSelectableMessageGrowsToFitAtPhoneWidth() throws {
        let content = String(repeating: "雨后海岸，柔和的自然光。A quiet coastline after rain.\n", count: 25)
        let window = try host(ScrollView { SelectableMessageText(text: content).padding(24) }.preferredColorScheme(.dark))
        defer { window.isHidden = true }
        let view = try XCTUnwrap(descendants(window).compactMap { $0 as? SelectionTextView }.first)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        window.layoutIfNeeded()
        let needed = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        XCTAssertGreaterThan(view.bounds.width, 100)
        XCTAssertGreaterThan(view.bounds.height, 400)
        XCTAssertGreaterThanOrEqual(view.bounds.height + 1, needed)
    }

    @MainActor func testExpandedInputKeepsMultilineDraftAndDoesNotSend() throws {
        var draft = "第一行\nsecond line"
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let window = try host(ExpandedComposer(title: "编辑消息", text: binding).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextView }.first)
        XCTAssertTrue(editor.isEditable); XCTAssertTrue(editor.isSelectable)
        XCTAssertEqual(editor.text, draft)
        editor.text = "修改后的第一行\n完整保留的第二行"
        editor.delegate?.textViewDidChange?(editor)
        XCTAssertEqual(draft, editor.text)
        try capturePreview(window, name: "expanded-composer")
    }

    @MainActor func testOpeningStrataToComfyHandoffDoesNotSubmitOrOverwriteDraft() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let workflow = SavedWorkflow(name: "文生图", data: Data(#"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"original"}}}"#.utf8))
        store.workflows = [workflow]; store.select(workflow.id); store.setChatDraft("尚未发送的原稿")
        let strata = StrataStore(storage: folder.appendingPathComponent("strata.json"))
        let window = try host(ComfyPromptHandoff(initialText: "A quiet coastline after rain.")
            .environmentObject(store).environmentObject(strata).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(store.selected?.chatDraft, "尚未发送的原稿")
        XCTAssertEqual(store.currentPromptField?.name, "text")
        let editor = try XCTUnwrap(descendants(window).compactMap { $0 as? UITextView }.first)
        XCTAssertEqual(editor.text, "A quiet coastline after rain.")
        try capturePreview(window, name: "strata-comfy-handoff")
    }

    @MainActor func testStrataPlacesAndConversationRenderWithoutArtworkLeak() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let clipboard = ClipboardSyncStore(storageURL: folder.appendingPathComponent("clipboard.json"))
        let strata = StrataStore(storage: folder.appendingPathComponent("strata.json"))
        store.background = testImage()
        store.activeTab = 3
        let places = try host(WorkbenchView().environmentObject(store).environmentObject(clipboard).environmentObject(strata).preferredColorScheme(.dark))
        XCTAssertTrue(descendants(places).compactMap { $0 as? UIImageView }.allSatisfy { $0.image !== store.background })
        try capturePreview(places, name: "strata-places")
        places.isHidden = true
        store.activeTab = 0; strata.assistantSelected = true
        let chat = try host(WorkbenchView().environmentObject(store).environmentObject(clipboard).environmentObject(strata).preferredColorScheme(.dark))
        XCTAssertTrue(descendants(chat).compactMap { $0 as? UIImageView }.allSatisfy { $0.image !== store.background })
        try capturePreview(chat, name: "strata-chat")
        chat.isHidden = true
    }

    @MainActor func testClipboardRefreshKeepsFollowingContentAtTheSamePosition() throws {
        let state = RefreshLayoutState()
        var cardFrame = CGRect.zero
        let window = try host(RefreshLayoutFixture(state: state) { cardFrame = $0 }.preferredColorScheme(.dark))
        defer { window.isHidden = true }
        let original = cardFrame
        XCTAssertGreaterThan(original.minY, 0)
        for refreshing in [true, false, true, false] {
            state.refreshing = refreshing
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
            XCTAssertEqual(cardFrame.minY, original.minY, accuracy: 0.5, "Refresh state must not move the card below it")
            XCTAssertEqual(cardFrame.size.height, original.size.height, accuracy: 0.5)
            XCTAssertEqual(cardFrame.size.width, original.size.width, accuracy: 0.5)
        }
    }

    @MainActor func testAutomaticClipboardPollingIsVisuallyQuietAndManualRefreshFinishes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = folder.appendingPathComponent("clipboard.json")
        let profile = ClipboardProfile(lanURL: "", publicURL: "https://example.com", deviceName: "Synthetic phone", hubId: "layout-test", deviceId: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder); QuietClipboardProtocol.fail = false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var archive = ClipboardArchive(); archive.profile = profile
        try JSONEncoder().encode(archive).write(to: storage)
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [QuietClipboardProtocol.self]
        let sync = ClipboardSyncStore(storageURL: storage, client: ClipboardClient(configuration: configuration), credentialReader: { _ in String(repeating: "a", count: 64) })
        await sync.tick(force: true)
        XCTAssertEqual(sync.status, "已同步"); XCTAssertFalse(sync.refreshing); XCTAssertFalse(sync.busy)
        var publications = 0
        let observation = sync.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }
        for _ in 0..<4 { await sync.tick(force: true) }
        XCTAssertEqual(publications, 0, "Unchanged automatic polls must not publish loading or identical status changes")
        sync.retry(); XCTAssertTrue(sync.refreshing)
        await sync.tick(force: true)
        XCTAssertFalse(sync.refreshing); XCTAssertEqual(sync.status, "已同步")
        QuietClipboardProtocol.fail = true
        sync.retry(); await sync.tick(force: true)
        XCTAssertFalse(sync.refreshing); XCTAssertTrue(sync.route.contains("离线"))
        publications = 0; await sync.tick(force: true)
        XCTAssertEqual(publications, 0, "An unchanged reconnect failure must not redraw the page repeatedly")
        QuietClipboardProtocol.fail = false
        sync.retry(); await sync.tick(force: true)
        XCTAssertFalse(sync.refreshing); XCTAssertEqual(sync.status, "已同步")
        let store = WorkbenchStore(storageURL: folder.appendingPathComponent("workbench"))
        let window = try host(ClipboardPage().environmentObject(sync).environmentObject(store).preferredColorScheme(.dark))
        defer { window.isHidden = true }
        try capturePreview(window, name: "clipboard-stable")
    }

    @MainActor func testWorkspaceTabsNeverRenderChatPhotoAndCaptureNativeLayout() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let sync = ClipboardSyncStore(storageURL: folder.appendingPathComponent("clipboard.json"))
        let workflow = SavedWorkflow(name: "双采样文生图 · 4K", data: Data(#"{"1":{"class_type":"KSampler","inputs":{"steps":28,"seed":123456,"cfg":7}},"2":{"class_type":"CLIPTextEncode","inputs":{"text":"雨后的海岸，远处的山峰，柔和的自然光"}}}"#.utf8))
        store.workflows = [workflow]; store.select(workflow.id)
        var prompt = PanelFieldConfiguration(id: "2.text"); prompt.label = "画面描述"; prompt.control = .multiline
        var steps = PanelFieldConfiguration(id: "1.steps"); steps.label = "采样步数"
        var seed = PanelFieldConfiguration(id: "1.seed"); seed.label = "种子"
        try store.configurePanel([prompt, steps, seed])
        store.background = testImage()
        store.canvasRunIssue = nil
        for tab in [1, 2, 4, 3] {
            store.activeTab = tab
            let window = try host(WorkbenchView().environmentObject(store).environmentObject(sync).environmentObject(StrataStore(storage: folder.appendingPathComponent("strata.json"))).preferredColorScheme(.dark))
            XCTAssertTrue(descendants(window).compactMap { $0 as? UIImageView }.allSatisfy { $0.image !== store.background }, "Chat photo leaked into tab \(tab)")
            if tab == 1 { try capturePreview(window, name: "application") }
            if tab == 4 { try capturePreview(window, name: "clipboard") }
            if tab == 3 { try capturePreview(window, name: "places") }
            window.isHidden = true
        }
    }
    @MainActor func testPairingScreenRendersNativeGuidanceWithoutEmbeddedWebview() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sync = ClipboardSyncStore(storageURL: folder.appendingPathComponent("clipboard.json"))
        let window = try host(ClipboardSettings().environmentObject(sync))
        defer { window.isHidden = true }
        XCTAssertFalse(descendants(window).contains { String(describing: type(of: $0)).contains("WebView") })
        try capturePreview(window, name: "pairing")
    }
    @MainActor @discardableResult private func capturePreview(_ window: UIWindow, name: String) throws -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let render = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: render); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard name.hasPrefix("strata-") || name.hasPrefix("reference-") else { return render }
        // Synthetic fixtures only. Export the native render through the CI log for visual review.
        let encoded = Array(try XCTUnwrap(render.pngData()).base64EncodedString().utf8)
        let count = (encoded.count + 4095) / 4096
        for index in 0..<count {
            let chunk = String(decoding: encoded[(index * 4096)..<min(encoded.count, (index + 1) * 4096)], as: UTF8.self)
            print("NATIVE_PREVIEW \(name) \(index)/\(count) \(chunk)")
        }
        return render
    }
    @MainActor func testClipboardHistoryCopiesAndPersistsWithoutEcho() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("clipboard.json")
        let entry = try JSONDecoder().decode(ClipboardEntry.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"sequence\":1,\"deviceId\":\"test-computer\",\"deviceName\":\"Test computer\",\"kind\":\"text\",\"text\":\"Synthetic clipboard\",\"createdAt\":1700000000000}".utf8))
        let sync = ClipboardSyncStore(storageURL: storage)
        sync.setAutomatic(send: true, receive: true); sync.copy(entry)
        XCTAssertEqual(UIPasteboard.general.string, "Synthetic clipboard")
        let restored = ClipboardSyncStore(storageURL: storage)
        XCTAssertTrue(restored.archive.autoSend); XCTAssertTrue(restored.archive.autoReceive)
        XCTAssertEqual(restored.archive.lastDigest, entry.input.digest)
        XCTAssertTrue(restored.archive.outbox.isEmpty)
        XCTAssertEqual(sync.notice, "已复制")
    }

    @MainActor func testClipboardFileProtectionOnSupportedDevice() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let storage = folder.appendingPathComponent("clipboard.json")
        let sync = ClipboardSyncStore(storageURL: storage)
        sync.setAutomatic(send: true)
        // Foundation returns this attribute as NSString, not the Swift RawRepresentable wrapper.
        let protection = try FileManager.default.attributesOfItem(atPath: storage.path)[.protectionKey] as? String
        #if targetEnvironment(simulator)
        if protection == nil { throw XCTSkip("This simulator does not expose file protection attributes; verify complete protection on physical iOS hardware.") }
        #endif
        XCTAssertEqual(protection, FileProtectionType.complete.rawValue)
    }

    @MainActor func testClipboardPageRendersOnXSViewport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sync = ClipboardSyncStore(storageURL: folder.appendingPathComponent("clipboard.json"))
        let store = WorkbenchStore(storageURL: folder)
        let window = try host(ZStack { ArtworkBackground(image: nil); ClipboardPage().environmentObject(sync).environmentObject(store) }.preferredColorScheme(.dark))
        defer { window.isHidden = true }
        XCTAssertFalse(descendants(window).compactMap { $0 as? UIVisualEffectView }.isEmpty)
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(rendered)
        let attachment = XCTAttachment(image: image); attachment.name = "Clipboard XS viewport"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testBackgroundDoesNotMultiplyPixelsByRetinaScale() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2600, height: 1300), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2600, height: 1300))
        }
        let store = WorkbenchStore(storageURL: folder); store.setBackground(image)
        let background = try XCTUnwrap(store.background?.cgImage)
        XCTAssertEqual(background.width, 2400); XCTAssertEqual(background.height, 1200)
        XCTAssertNil(store.error)
        let restored = WorkbenchStore(storageURL: folder)
        XCTAssertEqual(restored.background?.cgImage?.width, 2400)
    }

    @MainActor func testStoreEditsUndoRedoAndDraftsSurviveRelaunch() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WorkbenchStore(storageURL: folder)
        let data = Data(#"{"1":{"class_type":"Sampler","inputs":{"steps":20,"seed":18446744073709551615,"text":"example"}}}"#.utf8)
        let workflow = SavedWorkflow(name: "Synthetic test", data: data)
        store.workflows = [workflow]; store.select(workflow.id)
        let seed = try XCTUnwrap(store.canvas?.fields.first { $0.id == "1.seed" })
        try store.edit(seed, text: "42")
        XCTAssertEqual(store.canvas?.fields.first { $0.id == seed.id }?.value.uint64Value, 42)
        store.undoEdit()
        XCTAssertEqual(store.canvas?.fields.first { $0.id == seed.id }?.value.uint64Value, UInt64.max)
        store.redoEdit()
        XCTAssertEqual(store.canvas?.fields.first { $0.id == seed.id }?.value.uint64Value, 42)
        var item = PanelFieldConfiguration(id: "1.steps")
        item.label = "Quality"; item.group = "Image"; item.control = .slider
        item.minimum = 1; item.maximum = 60; item.step = 1
        try store.configurePanel([item])
        store.saveEditorDraft("1.text", text: "unfinished parameter")
        store.setChatDraft("unfinished chat")
        let viewport = CanvasViewport(x: 320, y: -100, zoom: 0.7)
        store.saveViewport(viewport, workflowID: workflow.id); store.saveDraftsNow()
        XCTAssertNil(store.error)
        let restored = WorkbenchStore(storageURL: folder)
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.editorDraft("1.text"), "unfinished parameter")
        XCTAssertEqual(restored.selected?.chatDraft, "unfinished chat")
        XCTAssertEqual(restored.selected?.viewport, viewport)
        XCTAssertEqual(restored.panelItems, [item])
        restored.undoEdit(); XCTAssertTrue(restored.panelItems.isEmpty)
        restored.undoEdit()
        XCTAssertEqual(restored.canvas?.fields.first { $0.id == seed.id }?.value.uint64Value, UInt64.max)
        restored.redoEdit(); restored.redoEdit()
        XCTAssertEqual(restored.panelItems, [item])
        XCTAssertEqual(restored.canvas?.nodes.first?.type, "Sampler")
    }

    @MainActor func testChatImageUsesClippedAspectFillAcrossEntireViewport() throws {
        let window = try host(ArtworkBackground(image: testImage()))
        defer { window.isHidden = true }
        let image = try XCTUnwrap(descendants(window).compactMap { $0 as? UIImageView }.first { $0.image != nil })
        XCTAssertEqual(image.contentMode, .scaleAspectFill)
        XCTAssertTrue(image.clipsToBounds)
        let frame = image.convert(image.bounds, to: window)
        XCTAssertEqual(frame.width, window.bounds.width, accuracy: 1)
        XCTAssertEqual(frame.height, window.bounds.height, accuracy: 1)
        XCTAssertEqual(frame.midY, window.bounds.midY, accuracy: 1)
    }

    @MainActor func testFittedPictureKeepsLandscapeRatioAndFrameFollowsPicture() throws {
        let window = try host(FittedArtwork(image: testImage()).ignoresSafeArea())
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        var rendered = false
        let render = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered, "The foreground test window must render before inspecting its pixels")
        let pixels = try rgba(render)
        // A 2:1 picture must remain centered, with black outside its fitted bounds.
        let width = window.bounds.width, height = window.bounds.height
        let pictureHeight = (width - 28) / 2
        let x = Int(width / 2), y = Int(height / 2)
        XCTAssertGreaterThan(pixels(x, y).0, 200)
        XCTAssertLessThan(pixels(x, Int((height - pictureHeight) / 2 - 20)).0, 20)
        XCTAssertLessThan(pixels(x, Int((height + pictureHeight) / 2 + 20)).0, 20)
        XCTAssertLessThan(pixels(5, y).0, 20)
        XCTAssertGreaterThan(pixels(30, y).0, 200)
        let attachment = XCTAttachment(image: render); attachment.name = "Native fitted artwork"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testGlassUsesRealBlurAndCapsulePathStaysWithinBounds() throws {
        XCTAssertFalse(UIAccessibility.isReduceTransparencyEnabled, "Blur checks require the default simulator accessibility setting")
        let window = try host(ZStack {
            ArtworkBackground(image: testImage())
            Text("Test").foregroundColor(.white).frame(width: 330, height: 54).glass(30)
        })
        defer { window.isHidden = true }
        let blur = try XCTUnwrap(descendants(window).compactMap { $0 as? UIVisualEffectView }.first)
        XCTAssertNotNil(blur.effect)
        XCTAssertEqual(blur.bounds.width, 330, accuracy: 1)
        XCTAssertEqual(blur.bounds.height, 54, accuracy: 1)
        let rect = CGRect(x: 0, y: 0, width: 330, height: 54)
        let path = GlassContour(radius: 30).path(in: rect)
        XCTAssertEqual(path.boundingRect, rect)
        XCTAssertFalse(path.contains(CGPoint(x: 0, y: 5)))
        XCTAssertTrue(path.contains(CGPoint(x: 1, y: 27)))
    }

    @MainActor private func testImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
    }
    @MainActor private func host<V: View>(_ view: V) throws -> UIWindow {
        let controller = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }, "Native rendering needs the test host's foreground scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return window
    }
    @MainActor private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func rgba(_ image: UIImage) throws -> (Int, Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return { x, y in let index = (y * width + x) * 4; return (bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]) }
    }
}

private final class NativeComfyProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var pending: NativeComfyProtocol?
    private static var recorded: [String] = []
    static var holdStats = false
    static var previewData = Data()
    static var landscapeData = Data()
    static var paths: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    static var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    static func client(_ config: ServerConfig) -> ComfyClient {
        let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [NativeComfyProtocol.self]
        return ComfyClient(config: config, sessionConfiguration: session)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock(); Self.recorded.append(path); Self.lock.unlock()
        if path == "/system_stats", Self.holdStats {
            Self.lock.lock(); Self.pending = self; Self.lock.unlock(); return
        }
        switch path {
        case "/system_stats": reply(Data(#"{"system":{},"devices":[]}"#.utf8))
        case "/object_info": reply(Data("{}".utf8))
        case "/history/synthetic-job": reply(Data(#"{"synthetic-job":{"outputs":{},"status":{"completed":true,"status_str":"success","messages":[]}}}"#.utf8))
        case "/upload/image":
            XCTAssertEqual(request.httpMethod, "POST")
            reply(Data(#"{"name":"uploaded.png","subfolder":"references","type":"input"}"#.utf8))
        case "/view": reply(request.url?.query?.contains("landscape.png") == true ? Self.landscapeData : Self.previewData, type: "image/png")
        default: XCTFail("Unexpected synthetic request: \(path)"); client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }
    override func stopLoading() {}
    private func reply(_ body: Data, type: String = "application/json") {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    static func failOldProbe() {
        lock.lock(); let old = pending; pending = nil; lock.unlock()
        if let old = old { old.client?.urlProtocol(old, didFailWithError: URLError(.timedOut)) }
    }
    static func reset() { failOldProbe(); lock.lock(); recorded = []; lock.unlock(); holdStats = false; previewData = Data(); landscapeData = Data() }
}

private final class RefreshLayoutState: ObservableObject { @Published var refreshing = false }
private struct CardFramePreference: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
private struct RefreshLayoutFixture: View {
    @ObservedObject var state: RefreshLayoutState
    let frameChanged: (CGRect) -> Void
    var body: some View {
        VStack(spacing: 22) {
            ClipboardStatusRow(route: "公网 HTTPS", status: "已同步", refreshing: state.refreshing, canRefresh: true, retry: {})
            Color.gray.frame(height: 220).background(GeometryReader { geometry in
                Color.clear.preference(key: CardFramePreference.self, value: geometry.frame(in: .global))
            })
            Spacer()
        }.padding(22).onPreferenceChange(CardFramePreference.self, perform: frameChanged)
    }
}
private final class QuietClipboardProtocol: URLProtocol {
    static var fail = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let json = request.url!.path.hasSuffix("info")
            ? #"{"hubId":"layout-test","protocolVersion":1}"#
            : #"{"items":[],"cursor":0,"hasMore":false,"reset":false}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DelayedStrataProtocol: URLProtocol {
    static let identity = "20dc53dc-5504-4d0d-911e-1b107e886f88"
    private static let lock = NSLock()
    private static var pending: DelayedStrataProtocol?
    private static var posts = 0
    static var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }
    static var postCount: Int { lock.lock(); defer { lock.unlock() }; return posts }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path.hasSuffix("info") {
            reply("{\"protocolVersion\":1,\"service\":\"strata-workbench\",\"serverId\":\"\(Self.identity)\",\"name\":\"Synthetic\"}")
        } else if request.httpMethod == "POST" {
            Self.lock.lock(); Self.posts += 1; Self.lock.unlock()
            reply(Self.state(loaded: false))
        } else {
            Self.lock.lock(); Self.pending = self; Self.lock.unlock()
        }
    }
    override func stopLoading() {}
    static func state(loaded: Bool) -> String {
        "{\"online\":true,\"loaded\":\(loaded),\"paused\":false,\"activeRequests\":0,\"maintenance\":false,\"inFlight\":0,\"model\":\"synthetic\",\"gpu\":{}}"
    }
    private func reply(_ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    static func releaseOldStatus() {
        lock.lock(); let request = pending; pending = nil; lock.unlock()
        request?.reply(state(loaded: true))
    }
    static func reset() { releaseOldStatus(); lock.lock(); posts = 0; lock.unlock() }
}

