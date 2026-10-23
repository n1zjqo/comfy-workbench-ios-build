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
}
