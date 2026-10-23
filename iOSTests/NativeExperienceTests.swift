import XCTest
import SwiftUI
import UIKit
@testable import ComfyWorkbench

final class NativeExperienceTests: XCTestCase {
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
        let window = host(ArtworkBackground(image: testImage()))
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
        let window = host(FittedArtwork(image: testImage()).ignoresSafeArea())
        defer { window.isHidden = true }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let render = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let pixels = try rgba(render)
        // A 2:1 red test picture fits to 347 x 173.5 in a 375 x 812 viewport.
        XCTAssertGreaterThan(pixels(187, 406).0, 200)
        XCTAssertLessThan(pixels(187, 250).0, 20)
        XCTAssertLessThan(pixels(187, 560).0, 20)
        XCTAssertLessThan(pixels(5, 406).0, 20)
        XCTAssertGreaterThan(pixels(30, 406).0, 200)
        let attachment = XCTAttachment(image: render); attachment.name = "Native fitted artwork"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testGlassUsesRealBlurAndCapsulePathStaysWithinBounds() throws {
        XCTAssertFalse(UIAccessibility.isReduceTransparencyEnabled, "Blur checks require the default simulator accessibility setting")
        let window = host(ZStack {
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
    @MainActor private func host<V: View>(_ view: V) -> UIWindow {
        let controller = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
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
