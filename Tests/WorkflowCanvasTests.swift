import XCTest
@testable import ComfyWorkbenchCore

final class WorkflowCanvasTests: XCTestCase {
    func testVideoNamedAndDictionaryWidgetsStayInSync() throws {
        var canvas = try graph(#"{"nodes":[{"id":1,"type":"VHS_LoadVideo","widgets_values_named":{"video":"old.mp4","force_rate":24},"widgets_values":{"video":"old.mp4","force_rate":24},"mode":4}],"links":[]}"#)
        try canvas.update(fieldID: "1.video", fromText: "new.mp4")
        let node = canvas.root["nodes"]?.arrayValue?.first
        XCTAssertEqual(node?["widgets_values_named"]?["video"], .string("new.mp4"))
        XCTAssertEqual(node?["widgets_values"]?["video"], .string("new.mp4"))
        XCTAssertEqual(node?["widgets_values"]?["force_rate"], .integer(24))
        XCTAssertEqual(node?["mode"], .integer(4))
    }
    private func graph(_ json: String, order: [String: [String]] = [:]) throws -> WorkflowCanvas {
        try WorkflowCanvas(data: Data(json.utf8), widgetOrder: order)
    }
    private let named = #"{"nodes":[{"id":7,"type":"CustomNode","title":"Custom caption","pos":[-125.5,900.25],"size":{"0":320,"1":180},"widgets_values_named":{"seed":18446744073709551615,"steps":20,"text":"hello"},"widgets_values":[18446744073709551615,20,"hello"],"inputs":[],"outputs":[{"name":"IMAGE"}]}],"links":[],"groups":[{"title":"Example"}]}"#

    func testOriginalCoordinatesAndDefaultNames() throws {
        let canvas = try graph(named)
        XCTAssertTrue(canvas.originalLayout)
        let node = try XCTUnwrap(canvas.nodes.first)
        XCTAssertEqual(node.type, "CustomNode")
        XCTAssertEqual(node.x, -125.5); XCTAssertEqual(node.y, 900.25)
        XCTAssertEqual(node.width, 320); XCTAssertEqual(node.height, 180)
        XCTAssertEqual(node.fields.first?.value.uint64Value, UInt64.max)
    }
    func testNamedAndPositionalWidgetsUpdateAtomically() throws {
        var canvas = try graph(named)
        try canvas.update(fieldID: "7.steps", fromText: "32")
        let node = canvas.root["nodes"]?.arrayValue?.first
        XCTAssertEqual(node?["widgets_values_named"]?["steps"], .integer(32))
        XCTAssertEqual(node?["widgets_values"]?.arrayValue?[1], .integer(32))
        XCTAssertEqual(node?["widgets_values"]?.arrayValue?[0].uint64Value, UInt64.max)
        XCTAssertEqual(node?["pos"]?.arrayValue?.first, .decimal(-125.5))
        XCTAssertEqual(canvas.widgetOrder["7"], ["seed", "steps", "text"])
    }
    func testSavedWidgetMappingSurvivesSortedJSONAndSecondEdit() throws {
        var canvas = try graph(named)
        try canvas.update(fieldID: "7.text", fromText: "first edit")
        var loaded = try WorkflowCanvas(data: canvas.data(), widgetOrder: canvas.widgetOrder)
        try loaded.update(fieldID: "7.seed", fromText: "18446744073709551614")
        XCTAssertEqual(loaded.root["nodes"]?.arrayValue?.first?["widgets_values"]?.arrayValue?[0].uint64Value, UInt64.max - 1)
        XCTAssertEqual(loaded.fields.first { $0.name == "text" }?.value, .string("first edit"))
    }
    func testExportCanBeReimportedWithoutPrivateMapping() throws {
        var canvas = try graph(named)
        try canvas.update(fieldID: "7.steps", fromText: "28")
        let exported = try canvas.exportData()
        var imported = try WorkflowCanvas(data: exported)
        try imported.update(fieldID: "7.text", fromText: "round trip")
        XCTAssertEqual(imported.root["nodes"]?.arrayValue?.first?["widgets_values"]?.arrayValue?[2], .string("round trip"))
        XCTAssertNil(imported.root["groups"])
        XCTAssertNil(imported.root["nodes"]?.arrayValue?.first?["title"])
    }
    func testAmbiguousMappingRejectsWithoutChangingAnything() throws {
        var canvas = try graph(#"{"nodes":[{"id":1,"type":"Custom","widgets_values_named":{"a":1,"b":2},"widgets_values":[2,1]}],"links":[]}"#)
        let before = canvas.root
        XCTAssertThrowsError(try canvas.update(fieldID: "1.a", fromText: "3"))
        XCTAssertEqual(canvas.root, before)
    }
    func testGenericPositionalWidgetsStayInTheirOwnSlots() throws {
        var canvas = try graph(#"{"nodes":[{"id":1,"type":"Unknown","widgets_values":["value",false,3]}],"links":[]}"#)
        try canvas.update(fieldID: "1.参数 2", fromText: "true")
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?.first?["widgets_values"]?.arrayValue, [.string("value"), .bool(true), .integer(3)])
    }
    func testLegacyAndV1LinksAndDecorations() throws {
        let nodes = #""nodes":[{"id":1,"type":"LoadImage","pos":[0,0],"size":[200,120]},{"id":2,"type":"SaveImage","pos":[350,0],"size":[200,120]},{"id":3,"type":"Note","title":"Hidden"}]"#
        let legacy = try graph("{" + nodes + #", "links":[[9,1,0,2,0,"IMAGE"]]}"#)
        let modern = try graph("{" + nodes + #", "links":[{"id":9,"origin_id":1,"origin_slot":0,"target_id":2,"target_slot":0,"type":"IMAGE"}]}"#)
        XCTAssertEqual(legacy.nodes.count, 2)
        XCTAssertEqual(legacy.links, modern.links)
        let exported = try JSONValue(data: modern.exportData())
        XCTAssertEqual(exported["nodes"]?.arrayValue?.count, 2)
    }
    func testAPIHasDeterministicDirectionalLayoutAndEditableFields() throws {
        let source = #"{"1":{"class_type":"Source","inputs":{"seed":1}},"2":{"class_type":"Destination","inputs":{"image":["1",0],"text":"hello"}}}"#
        var first = try graph(source)
        let second = try graph(source)
        XCTAssertFalse(first.originalLayout)
        XCTAssertEqual(first.nodes, second.nodes)
        XCTAssertGreaterThan(first.nodes[1].x, first.nodes[0].x)
        XCTAssertEqual(first.links.count, 1)
        try first.update(fieldID: "2.text", fromText: "changed")
        XCTAssertEqual(first.root["2"]?["inputs"]?["image"], .array([.string("1"), .integer(0)]))
        XCTAssertThrowsError(try first.update(fieldID: "2.image", fromText: "broken"))
    }
    func testAPICycleAndDisconnectedNodesRemainFinite() throws {
        let canvas = try graph(#"{"1":{"class_type":"A","inputs":{"x":["2",0]}},"2":{"class_type":"B","inputs":{"x":["1",0]}},"3":{"class_type":"C","inputs":{}}}"#)
        XCTAssertEqual(canvas.nodes.count, 3)
        XCTAssertTrue(canvas.nodes.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(Set(canvas.nodes.map(\.y)).count, 3)
    }
    func testBadInputsAndDuplicateIDsFail() throws {
        XCTAssertThrowsError(try graph(#"{"nodes":[{"id":1,"type":"A"},{"id":1,"type":"B"}]}"#))
        XCTAssertThrowsError(try graph(#"{"nodes":[{"id":1,"type":"A","size":[-1,10]}]}"#))
        XCTAssertThrowsError(try graph(#"{"nodes":[{"id":1,"type":"A"},{"id":2,"type":"B"}],"links":[[1,1,-1,2,0,"IMAGE"]]}"#))
    }
    func testSchemaRangeValidationIsSharedWithAPIEditor() throws {
        let info = try ObjectInfo(data: Data(#"{"CustomNode":{"input":{"required":{"steps":["INT",{"min":1,"max":50}]}}}}"#.utf8))
        var canvas = try WorkflowCanvas(data: Data(named.utf8), objectInfo: info)
        let before = canvas.root
        XCTAssertThrowsError(try canvas.update(fieldID: "7.steps", fromText: "51"))
        XCTAssertEqual(canvas.root, before)
    }
    func testKnownPositionalPromptMapsToRunnableAPI() throws {
        let info = Data(#"{"CLIPTextEncode":{"input":{"required":{"text":["STRING",{"multiline":true}]}},"output":["CONDITIONING"],"output_node":true}}"#.utf8)
        var canvas = try graph(#"{"nodes":[{"id":1,"type":"CLIPTextEncode","widgets_values":["before"],"inputs":[],"outputs":[]}],"links":[]}"#)
        try canvas.update(fieldID: "1.text", fromText: "after")
        let api = try UIWorkflowConverter.convert(data: canvas.data(), objectInfoData: info)
        XCTAssertEqual(try WorkflowDocument(data: api).fields.first?.value, .string("after"))
    }
    func testConnectedWidgetsAndFrontendButtonsAreNotPresentedAsEditableInputs() throws {
        var canvas = try graph(#"{"nodes":[{"id":1,"type":"Source"},{"id":2,"type":"Custom","inputs":[{"name":"text","link":9}],"widgets_values_named":{"text":"stale","upload":"button","steps":12}}],"links":[[9,1,0,2,0,"STRING"]]}"#)
        XCTAssertEqual(canvas.fields.map(\.name), ["steps"])
        XCTAssertThrowsError(try canvas.update(fieldID: "2.text", fromText: "unused"))
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[1]["widgets_values_named"]?["text"], .string("stale"))
    }
}
