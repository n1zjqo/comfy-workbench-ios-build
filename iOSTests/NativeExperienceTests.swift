import XCTest
import SwiftUI
import UIKit
import Combine
import WebKit
@testable import ComfyWorkbench

final class NativeExperienceTests: XCTestCase {
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
    @MainActor private func capturePreview(_ window: UIWindow, name: String) throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let render = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: render); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        guard name.hasPrefix("strata-") else { return }
        // Synthetic fixtures only. Export the native render through the CI log for visual review.
        let encoded = Array(try XCTUnwrap(render.pngData()).base64EncodedString().utf8)
        let count = (encoded.count + 4095) / 4096
        for index in 0..<count {
            let chunk = String(decoding: encoded[(index * 4096)..<min(encoded.count, (index + 1) * 4096)], as: UTF8.self)
            print("NATIVE_PREVIEW \(name) \(index)/\(count) \(chunk)")
        }
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

