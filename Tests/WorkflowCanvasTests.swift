import XCTest
@testable import ComfyWorkbenchCore

final class WorkflowCanvasTests: XCTestCase {
    private func groupFixture(restriction: String = "default", type: String = "Fast Groups Bypasser (rgthree)") throws -> WorkflowCanvas {
        let raw: [String: Any] = ["nodes": [
            ["id": 1, "type": "Text", "pos": [10, 40], "size": [100, 80], "widgets_values": ["example"]],
            ["id": 2, "type": "Text", "pos": [120, 40], "size": [100, 80], "mode": 2, "widgets_values": ["other"]],
            ["id": 3, "type": "Text", "pos": [10, 350], "size": [100, 80], "mode": 4, "widgets_values": ["third"]],
            ["id": 98, "type": type, "pos": [-400, 0], "size": [200, 120], "properties": ["matchTitle": "^0", "toggleRestriction": restriction]]
        ], "links": [], "groups": [
            ["id": 10, "title": "01 First", "bounding": [0, 0, 300, 200], "color": "#3f789e"],
            ["id": 20, "title": "02 Second", "bounding": [0, 300, 300, 200], "color": "#a08020"],
            ["id": 30, "title": "Decoration", "bounding": [500, 0, 300, 200]]
        ]]
        return try WorkflowCanvas(data: JSONSerialization.data(withJSONObject: raw))
    }
    func testGroupSwitchDiscoveryAndExactModeUndo() throws {
        var canvas = try groupFixture()
        XCTAssertTrue(canvas.groupSwitchIssues.isEmpty)
        XCTAssertEqual(canvas.groupSwitches.map(\.title), ["01 First", "02 Second"])
        XCTAssertEqual(canvas.groupSwitches[0].nodeIDs, ["1", "2"])
        XCTAssertTrue(canvas.groupSwitches[0].partiallyEnabled)
        let original = canvas.root
        let change = try canvas.groupModeChange(fieldID: "98.__group_id_10", enabled: false)
        try canvas.restoreGroupModes(change.after)
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[0]["mode"], .integer(4))
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[1]["mode"], .integer(4))
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[2], original["nodes"]?.arrayValue?[2])
        XCTAssertEqual(canvas.root["links"], original["links"])
        try canvas.restoreGroupModes(change.before)
        XCTAssertEqual(canvas.root, original) // Missing mode and mixed muted state both survive.
        XCTAssertEqual(canvas.nodes.first { $0.id == "98" }?.fields.first?.title, "01 First")
        XCTAssertThrowsError(try canvas.update(fieldID: "98.__group_id_10", value: .string("false")))
        XCTAssertEqual(canvas.root, original)
    }
    func testGroupRestrictionsAndMuterAreAppliedToActualNodes() throws {
        var canvas = try groupFixture(restriction: "always one", type: "Fast Groups Muter (rgthree)")
        try canvas.update(fieldID: "98.__group_id_20", value: .bool(true))
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[0]["mode"], .integer(2))
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[1]["mode"], .integer(2))
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[2]["mode"], .integer(0))
        try canvas.update(fieldID: "98.__group_id_20", value: .bool(false))
        XCTAssertTrue(canvas.groupSwitches[1].enabled)
        var maxOne = try groupFixture(restriction: "max one")
        try maxOne.update(fieldID: "98.__group_id_20", value: .bool(true))
        try maxOne.update(fieldID: "98.__group_id_20", value: .bool(false))
        XCTAssertTrue(maxOne.groupSwitches.allSatisfy { !$0.enabled })
    }
    func testGroupExportRetainsFunctionalMetadataAndStablePanelIDs() throws {
        let canvas = try groupFixture()
        let imported = try WorkflowCanvas(data: canvas.exportData())
        XCTAssertEqual(imported.root["groups"], canvas.root["groups"])
        XCTAssertEqual(imported.groupSwitches, canvas.groupSwitches)
        XCTAssertEqual(imported.fields.map(\.id), canvas.fields.map(\.id))
        XCTAssertFalse(try imported.exportData().isEmpty)
    }
    func testGroupInvalidRulesFailClosedAndSnapshotValidationIsAtomic() throws {
        var canvas = try groupFixture()
        let before = canvas.root
        XCTAssertThrowsError(try canvas.restoreGroupModes(.object(["1": .integer(4), "missing": .integer(0)])))
        XCTAssertEqual(canvas.root, before)
        var raw = try XCTUnwrap(before.objectValue)
        var nodes = try XCTUnwrap(raw["nodes"]?.arrayValue)
        var controller = try XCTUnwrap(nodes[3].objectValue)
        controller["properties"] = .object(["matchTitle": .string("[")]); nodes[3] = .object(controller)
        raw["nodes"] = .array(nodes)
        let invalid = try WorkflowCanvas(data: JSONValue.object(raw).data())
        XCTAssertNotNil(invalid.groupSwitchIssues["98"]); XCTAssertTrue(invalid.groupSwitches.isEmpty)
        raw.removeValue(forKey: "groups")
        let missing = try WorkflowCanvas(data: JSONValue.object(raw).data())
        XCTAssertNotNil(missing.groupSwitchIssues["98"])
    }
    func testGroupSwitchChangesTheRunnablePromptThroughBypass() throws {
        let input = #"{"nodes":[{"id":1,"type":"Source","pos":[400,50],"size":[100,80],"outputs":[{"type":"IMAGE","name":"IMAGE"}]},{"id":2,"type":"Filter","pos":[40,50],"size":[100,80],"inputs":[{"name":"image","type":"IMAGE","link":1}],"outputs":[{"type":"IMAGE","name":"IMAGE"}]},{"id":3,"type":"Sink","pos":[400,250],"size":[100,80],"inputs":[{"name":"image","type":"IMAGE","link":2}],"outputs":[]},{"id":98,"type":"Fast Groups Bypasser (rgthree)","pos":[-400,0],"size":[200,100]}],"links":[[1,1,0,2,0,"IMAGE"],[2,2,0,3,0,"IMAGE"]],"groups":[{"id":1,"title":"Refinement","bounding":[0,0,200,200]}]}"#
        let definitions = Data(#"{"Source":{"input":{"required":{}},"output":["IMAGE"]},"Filter":{"input":{"required":{"image":["IMAGE"]}},"output":["IMAGE"]},"Sink":{"input":{"required":{"image":["IMAGE"]}},"output":[],"output_node":true}}"#.utf8)
        var canvas = try graph(input)
        let active = try JSONValue(data: UIWorkflowConverter.convert(data: canvas.data(), objectInfoData: definitions))
        XCTAssertNotNil(active["2"]); XCTAssertNil(active["98"])
        try canvas.update(fieldID: "98.__group_id_1", value: .bool(false))
        let bypassed = try JSONValue(data: UIWorkflowConverter.convert(data: canvas.data(), objectInfoData: definitions))
        XCTAssertNil(bypassed["2"]); XCTAssertNil(bypassed["98"])
        XCTAssertEqual(bypassed["3"]?["inputs"]?["image"], .array([.string("1"), .integer(0)]))
    }
    func testGroupDuplicateTitlesColorFilterAndNestedMembership() throws {
        var raw = try XCTUnwrap(groupFixture().root.objectValue)
        raw["groups"] = .array([
            .object(["id": .integer(10), "title": .string("Same"), "bounding": .array([0,0,300,200].map { .integer(Int64($0)) }), "color": .string("#abc")]),
            .object(["id": .integer(20), "title": .string("Same"), "bounding": .array([0,0,110,200].map { .integer(Int64($0)) }), "color": .string("#AABBCC")]),
            .object(["id": .integer(30), "title": .string("Other"), "bounding": .array([0,300,300,200].map { .integer(Int64($0)) }), "color": .string("#fff")])
        ])
        var nodes = try XCTUnwrap(raw["nodes"]?.arrayValue)
        var controller = try XCTUnwrap(nodes[3].objectValue)
        controller["properties"] = .object(["matchColors": .string("#aabbcc"), "sort": .string("alphanumeric")])
        nodes[3] = .object(controller); raw["nodes"] = .array(nodes)
        var canvas = try WorkflowCanvas(data: JSONValue.object(raw).data())
        XCTAssertEqual(canvas.groupSwitches.count, 2)
        XCTAssertEqual(Set(canvas.groupSwitches.map(\.id)).count, 2)
        XCTAssertEqual(canvas.groupSwitches[0].nodeIDs, ["1", "2"])
        XCTAssertEqual(canvas.groupSwitches[1].nodeIDs, ["1"])
        try canvas.update(fieldID: "98.__group_id_20", value: .bool(false))
        XCTAssertFalse(canvas.groupSwitches[0].enabled) // Shared member state must propagate.
        XCTAssertEqual(canvas.root["nodes"]?.arrayValue?[1]["mode"], .integer(2))
    }
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
