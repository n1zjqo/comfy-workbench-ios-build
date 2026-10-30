import Foundation
import XCTest
@testable import ComfyWorkbenchCore

final class WorkflowCoreTests: XCTestCase {
    private func bytes(_ value: String) -> Data { Data(value.utf8) }
    private let sample = #"{"1":{"class_type":"PrimitiveInt","inputs":{"value":1024},"_meta":{"title":"custom"},"custom":{"enabled":true}},"2":{"class_type":"KSampler","inputs":{"seed":18446744073709551615,"steps":20,"cfg":7.5,"enabled":true,"model":["1",0],"literal":["red",0],"extra":{"keep":[1,true,null]}}}}"#

    func testImportReadsBOMAndUTF16WithoutLosingLargeSeeds() throws {
        let bom = Data([0xEF, 0xBB, 0xBF]) + bytes(sample)
        for data in [bom, try XCTUnwrap(sample.data(using: .utf16))] {
            let normalized = try WorkflowImportData.normalized(data)
            let document = try WorkflowDocument(data: normalized)
            XCTAssertEqual(document.prompt["2"]?["inputs"]?["seed"]?.uint64Value, UInt64.max)
        }
    }
    func testImportRejectsEmptyHTMLArraysAndOversizedFiles() {
        for data in [Data(), bytes("<html>download</html>"), bytes("[]"), Data(repeating: 32, count: 12_000_001)] {
            XCTAssertThrowsError(try WorkflowImportData.normalized(data))
        }
    }

    func testRoundTripPreservesUnknownValuesAndUInt64() throws {
        let original = try JSONValue(data: bytes(sample))
        let document = try WorkflowDocument(data: bytes(sample))
        XCTAssertEqual(try JSONValue(data: document.data()), original)
        XCTAssertEqual(document.fields.first { $0.name == "seed" }?.value, .unsignedInteger(UInt64.max))
        XCTAssertEqual(document.nodes.first?.classType, "PrimitiveInt")
        XCTAssertEqual(document.connections.count, 1)
        XCTAssertFalse(document.fields.contains { $0.name == "model" || $0.name == "literal" || $0.name == "extra" })
    }

    func testEditsPreserveLinksAndExactSeeds() throws {
        var document = try WorkflowDocument(data: bytes(sample))
        let links = document.connections
        try document.update(fieldID: "2.seed", fromText: "18446744073709551614")
        try document.update(fieldID: "2.steps", fromText: "24")
        try document.update(fieldID: "2.enabled", value: .bool(false))
        XCTAssertEqual(document.prompt["2"]?["inputs"]?["seed"], .unsignedInteger(UInt64.max - 1))
        XCTAssertEqual(document.connections, links)
        XCTAssertEqual(document.prompt["2"]?["inputs"]?["model"], .array([.string("1"), .integer(0)]))
        XCTAssertEqual(document.prompt["1"]?["custom"], .object(["enabled": .bool(true)]))
        XCTAssertThrowsError(try document.update(fieldID: "2.model", value: .string("broken")))
        XCTAssertThrowsError(try document.update(fieldID: "2.seed", fromText: "18446744073709551616"))
        XCTAssertThrowsError(try document.update(fieldID: "2.steps", value: .string("24")))
    }

    func testWrappedPromptExportsAndSubmitsCorrectly() throws {
        let wrapped = "{\"prompt\":\(sample),\"client_id\":\"keep-me\",\"extra_data\":{\"hello\":true}}"
        var document = try WorkflowDocument(data: bytes(wrapped))
        try document.update(fieldID: "1.value", fromText: "2048")
        XCTAssertEqual(try JSONValue(data: document.data())["client_id"], .string("keep-me"))
        let submission = try JSONValue(data: document.promptData())
        XCTAssertNil(submission["prompt"])
        XCTAssertEqual(submission["1"]?["inputs"]?["value"], .integer(2048))
    }

    func testNodeNamedPromptIsNotMistakenForWrapper() throws {
        let document = try WorkflowDocument(data: bytes(#"{"prompt":{"class_type":"Text","inputs":{"text":"hello"}}}"#))
        XCTAssertEqual(document.nodes.first?.id, "prompt")
        XCTAssertEqual(document.fields.first?.value, .string("hello"))
    }

    func testRejectsCanvasDanglingAndMalformedReferences() throws {
        XCTAssertThrowsError(try WorkflowDocument(data: bytes(#"{"nodes":[],"links":[]}"#))) { error in
            XCTAssertTrue(error.localizedDescription.contains("API"))
        }
        XCTAssertThrowsError(try WorkflowDocument(data: bytes(#"{"2":{"class_type":"Test","inputs":{"source":["999",0]}}}"#)))
        XCTAssertThrowsError(try WorkflowDocument(data: bytes(#"{"2":{"class_type":"Test","inputs":{"source":["2",-1]}}}"#)))
        XCTAssertThrowsError(try WorkflowDocument(data: bytes(#"{"2":{"class_type":"Test","inputs":{"source":["2",0.5]}}}"#)))
    }

    func testSchemaRangesEnumsUploadAndMultiline() throws {
        let info = try ObjectInfo(data: bytes(#"{"KSampler":{"input":{"required":{"seed":["INT",{"min":0,"max":18446744073709551615}],"steps":["INT",{"min":1,"max":100,"step":1}],"cfg":["FLOAT",{"min":0,"max":30}]},"optional":{"sampler_name":[["euler","dpmpp_2m"]],"image":[["a.png","b.png"],{"image_upload":true}],"text":["STRING",{"multiline":true}]}}}}"#))
        var document = try WorkflowDocument(data: bytes(sample), objectInfo: info)
        try document.update(fieldID: "2.seed", fromText: "18446744073709551615")
        XCTAssertThrowsError(try document.update(fieldID: "2.steps", fromText: "101"))
        XCTAssertThrowsError(try document.update(fieldID: "2.steps", fromText: "0"))
        XCTAssertEqual(info.schema(for: "KSampler", input: "steps")?.step, 1)
        XCTAssertEqual(info.schema(for: "KSampler", input: "sampler_name")?.options, [.string("euler"), .string("dpmpp_2m")])
        XCTAssertEqual(info.schema(for: "KSampler", input: "image")?.isUpload, true)
        XCTAssertEqual(info.schema(for: "KSampler", input: "text")?.multiline, true)
    }

    func testLiteralArraySchemaDisambiguatesExistingNodeIDPair() throws {
        let raw = #"{"1":{"class_type":"Custom","inputs":{"palette":["1",0],"text":"hello"}}}"#
        let info = try ObjectInfo(data: bytes(#"{"Custom":{"input":{"required":{"palette":[[["1",0],["red",0]]]}}}}"#))
        let document = try WorkflowDocument(data: bytes(raw), objectInfo: info)
        XCTAssertTrue(document.connections.isEmpty)
        XCTAssertEqual(try JSONValue(data: document.data()), try JSONValue(data: bytes(raw)))
    }

    func testApplicationPinsAndPrimitiveDimensions() throws {
        let document = try WorkflowDocument(data: bytes(sample))
        XCTAssertTrue(document.applicationFields().contains { $0.id == "1.value" })
        XCTAssertEqual(document.applicationFields(pinnedIDs: ["2.cfg"]).map(\.id), ["2.cfg"])
        XCTAssertEqual(document.fields.count, 5)
    }

    func testDynamicComboUsesSelectorKeys() throws {
        let info = try ObjectInfo(data: bytes(#"{"Custom":{"input":{"required":{"method":["COMFY_DYNAMICCOMBO_V3",{"options":[{"key":"sol-attn","inputs":{}},{"key":"sdpa","inputs":{}}]}]}}}}"#))
        XCTAssertEqual(info.schema(for: "Custom", input: "method")?.options, [.string("sol-attn"), .string("sdpa")])
    }

    func testUploadKindsFollowServerMetadataAndVHSUploadLoadersOnly() throws {
        let metadata = #"{"LoadImage":{"input":{"required":{"image":[["old.png"],{"image_upload":true}]}}},"LoadVideo":{"input":{"required":{"file":[["old.mov"],{"video_upload":true}]}}},"LoadAudio":{"input":{"required":{"audio":[["old.wav"],{"audio_upload":true}]}}},"VHS_LoadVideo":{"input":{"required":{"video":[["old.mp4"]]}}},"VHS_LoadAudioUpload":{"input":{"required":{"audio":[["old.wav"]]}}},"VHS_LoadAudio":{"input":{"required":{"audio_file":["STRING"]}}},"VHS_LoadVideoPath":{"input":{"required":{"video":["STRING"]}}}}"#
        let info = try ObjectInfo(data: bytes(metadata))
        for (type, input, kind) in [("LoadImage", "image", WorkflowFieldSchema.UploadKind.image), ("LoadVideo", "file", .video), ("LoadAudio", "audio", .audio), ("VHS_LoadVideo", "video", .video), ("VHS_LoadAudioUpload", "audio", .audio)] {
            XCTAssertEqual(info.schema(for: type, input: input)?.uploadKind, kind)
        }
        XCTAssertFalse(try XCTUnwrap(info.schema(for: "VHS_LoadVideoPath", input: "video")).isUpload)
        XCTAssertFalse(try XCTUnwrap(info.schema(for: "VHS_LoadAudio", input: "audio_file")).isUpload)
    }

    func testReferenceGroupsAdaptToWorkflowAndPreserveInputBindings() throws {
        let raw = #"{"1":{"class_type":"LoadImage","inputs":{"image":"first.png"}},"2":{"class_type":"LoadImage","inputs":{"image":"last.png"}},"3":{"class_type":"LoadAudio","inputs":{"audio":"voice.wav"}},"4":{"class_type":"VHS_LoadVideo","inputs":{"video":"motion.mp4"}},"5":{"class_type":"MiniMaxH3ImageToVideo","inputs":{"first_frame":["1",0],"last_frame":["2",0],"ref_audio":["3",0],"ref_video":["4",0]}}}"#
        var canvas = try WorkflowCanvas(data: bytes(raw))
        let groups = canvas.referenceGroups
        XCTAssertEqual(groups.map(\.kind), [.image, .video, .audio])
        XCTAssertEqual(groups.map { $0.inputs.count }, [2, 1, 1])
        XCTAssertEqual(groups[0].inputs.map(\.role), ["首帧", "尾帧"])
        XCTAssertEqual(groups[0].mediaRows(aspectRatios: ["1.image": 9.0/16, "2.image": 9.0/16]).map { $0.map(\.id) }, [["1.image", "2.image"]])
        XCTAssertEqual(groups[0].mediaRows(aspectRatios: ["1.image": 16.0/9, "2.image": 9.0/16]).map { $0.map(\.id) }, [["1.image"], ["2.image"]])
        let links = canvas.links
        try canvas.update(fieldID: "1.image", fromText: "new.png")
        try canvas.update(fieldID: "2.image", fromText: "")
        XCTAssertEqual(canvas.links, links)
        XCTAssertEqual(canvas.fields.first { $0.id == "3.audio" }?.value, .string("voice.wav"))
        XCTAssertEqual(canvas.fields.first { $0.id == "4.video" }?.value, .string("motion.mp4"))
        XCTAssertEqual(canvas.referenceGroups[0].inputs.map(\.id), ["1.image", "2.image"])
        let single = try WorkflowCanvas(data: bytes(#"{"1":{"class_type":"LoadImage","inputs":{"image":""}}}"#))
        XCTAssertEqual(single.referenceGroups.count, 1)
        XCTAssertEqual(single.referenceGroups.first?.layout, .hero)
        let textOnly = try WorkflowCanvas(data: bytes(#"{"1":{"class_type":"Text","inputs":{"text":"synthetic"}}}"#))
        XCTAssertTrue(textOnly.referenceGroups.isEmpty)
    }

    func testReferenceGroupsDoNotInventSlotsForUnconnectedH3Inputs() throws {
        let raw = #"{"nodes":[{"id":1,"type":"LoadImage","widgets_values":["disabled.png"],"mode":2},{"id":2,"type":"MiniMaxH3ImageToVideo","widgets_values":[],"inputs":[{"name":"first_frame","type":"IMAGE","link":null},{"name":"last_frame","type":"IMAGE","link":null}]}],"links":[]}"#
        let canvas = try WorkflowCanvas(data: bytes(raw))
        XCTAssertTrue(canvas.referenceGroups.isEmpty)
    }
}
