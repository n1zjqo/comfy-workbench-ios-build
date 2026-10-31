import Foundation
import XCTest
@testable import ComfyWorkbenchCore

final class WorkflowControlTests: XCTestCase {
    private func value(_ text: String) throws -> JSONValue { try JSONValue(data: Data(text.utf8)) }
    private func canvas(_ text: String) throws -> WorkflowCanvas { try WorkflowCanvas(data: Data(text.utf8)) }
    private func node(_ id: Int, _ type: String, x: Int = 20, mode: Int64? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .integer(Int64(id)), "type": .string(type), "pos": .array([.integer(Int64(x)), .integer(40)]), "size": .array([.integer(100), .integer(80)]), "inputs": .array([]), "outputs": .array([])]
        if let mode = mode { object["mode"] = .integer(mode) }
        return .object(object)
    }
    private func root(_ nodes: [JSONValue], groups: [JSONValue] = [], definitions: [JSONValue] = []) -> JSONValue {
        .object(["nodes": .array(nodes), "links": .array([]), "groups": .array(groups), "definitions": .object(["subgraphs": .array(definitions)])])
    }
    private var group: JSONValue { .object(["id": .integer(7), "title": .string("Branch"), "color": .string("#88a"), "bounding": .array([0,0,200,200].map { .integer(Int64($0)) })]) }

    func testGroupControlsAreIndependentOfWorkflowAndNodeNumbers() throws {
        for number in [3, 61, 506, 1703, 90999] {
            let original = root([node(number, "Model", mode: 0), node(number + 1, "Fast Groups Bypasser (rgthree)", x: 500)], groups: [group])
            var graph = try WorkflowCanvas(data: original.data())
            let control = try XCTUnwrap(graph.groupSwitches.first)
            XCTAssertEqual(control.nodeIDs, [String(number)])
            let change = try graph.groupModeChange(fieldID: control.id, enabled: false)
            try graph.restoreGroupModes(change.after)
            XCTAssertEqual(graph.root["nodes"]?.arrayValue?[0]["mode"], .integer(4))
            try graph.restoreGroupModes(change.before)
            XCTAssertEqual(graph.root, original)
        }
    }
    func testSharedNestedDefinitionsUseScopeKeysAndRestoreSparseModes() throws {
        var inner = root([node(5, "Model"), node(6, "Fast Groups Muter (rgthree)", x: 500)], groups: [group]).objectValue!
        inner["id"] = .string("inner")
        var outer = root([node(5, "inner")]).objectValue!; outer["id"] = .string("outer")
        let original = root([node(5, "RootModel"), node(20, "outer"), node(21, "outer")], definitions: [.object(inner), .object(outer)])
        var graph = try WorkflowCanvas(data: original.data())
        let controls = graph.groupSwitches.filter { $0.title == "Branch" }
        XCTAssertEqual(Set(controls.map(\.ownerID)), Set(["20", "21"]))
        let control = try XCTUnwrap(controls.first)
        XCTAssertNotNil(control.scopeCaption)
        let change = try graph.groupModeChange(fieldID: control.id, enabled: false)
        XCTAssertEqual(change.before.objectValue?.count, 1)
        try graph.restoreGroupModes(change.after)
        XCTAssertTrue(graph.groupSwitches.allSatisfy { !$0.enabled })
        XCTAssertNil(graph.root["nodes"]?.arrayValue?[0]["mode"])
        XCTAssertEqual(graph.root["definitions"]?["subgraphs"]?.arrayValue?[0]["nodes"]?.arrayValue?[0]["mode"], .integer(2))
        try graph.restoreGroupModes(change.before); XCTAssertEqual(graph.root, original)
        let saved = try WorkflowCanvas(data: graph.exportData())
        XCTAssertEqual(saved.groupSwitches, graph.groupSwitches)
    }
    func testCrossGraphGroupIDsDoNotCollideAndLocalFilterRespectsScope() throws {
        var inner = root([node(5, "Child")], groups: [group]).objectValue!; inner["id"] = .string("sub")
        var controller = node(700, "Fast Groups Muter (rgthree)", x: 500).objectValue!
        controller["properties"] = .object(["matchColors": .string("blue")])
        let original = root([node(5, "Root"), .object(controller)], groups: [group], definitions: [.object(inner)])
        var graph = try WorkflowCanvas(data: original.data())
        XCTAssertEqual(graph.groupSwitches.count, 2)
        XCTAssertEqual(Set(graph.fields.map(\.id)).count, 2)
        let nested = try XCTUnwrap(graph.groupSwitches.first { $0.scopeCaption != nil })
        try graph.update(fieldID: nested.id, value: .bool(false))
        XCTAssertNil(graph.root["nodes"]?.arrayValue?[0]["mode"])
        controller["properties"] = .object(["showAllGraphs": .bool(false)])
        let local = try WorkflowCanvas(data: root([node(5, "Root"), .object(controller)], groups: [group], definitions: [.object(inner)]).data())
        XCTAssertEqual(local.groupSwitches.count, 1)
    }
    func testGroupContainingSubgraphChangesAllDescendantsAndUndoesExactly() throws {
        var inner = root([node(5, "Model", mode: 2)]).objectValue!; inner["id"] = .string("sub")
        let original = root([node(10, "sub"), node(900, "Fast Groups Bypasser (rgthree)", x: 500)], groups: [group], definitions: [.object(inner)])
        var graph = try WorkflowCanvas(data: original.data())
        let change = try graph.groupModeChange(fieldID: graph.groupSwitches[0].id, enabled: false)
        XCTAssertEqual(change.after.objectValue?.count, 2)
        try graph.restoreGroupModes(change.after)
        XCTAssertEqual(graph.root["definitions"]?["subgraphs"]?.arrayValue?[0]["nodes"]?.arrayValue?[0]["mode"], .integer(4))
        try graph.restoreGroupModes(change.before); XCTAssertEqual(graph.root, original)
    }
    func testConnectedSwitchTraversesCollectorAndRetainsRestriction() throws {
        var graph = try canvas(#"{"nodes":[{"id":11,"type":"A","mode":0},{"id":12,"type":"B","mode":4},{"id":13,"type":"Node Collector (rgthree)","inputs":[{"link":2},{"link":1}]},{"id":900,"type":"Fast Bypasser (rgthree)","properties":{"toggleRestriction":"always one"},"inputs":[{"link":3}]}],"links":[[1,11,0,13,1,"*"],[2,12,0,13,0,"*"],[3,13,0,900,0,"*"]]}"#)
        XCTAssertEqual(graph.groupSwitches.map(\.nodeIDs), [["12"], ["11"]])
        let selected = graph.groupSwitches[0].id
        try graph.update(fieldID: selected, value: .bool(true))
        XCTAssertEqual(graph.root["nodes"]?.arrayValue?[0]["mode"], .integer(4))
        XCTAssertEqual(graph.root["nodes"]?.arrayValue?[1]["mode"], .integer(0))
        try graph.update(fieldID: selected, value: .bool(false))
        XCTAssertTrue(graph.groupSwitches.first { $0.id == selected }!.enabled)
    }
    private let relayGraph = #"{"nodes":[{"id":1,"type":"Source"},{"id":2,"type":"Mute / Bypass Relay (rgthree)","inputs":[{"link":1}]},{"id":3,"type":"Mute / Bypass Repeater (rgthree)","inputs":[{"link":2},{"link":3}]},{"id":4,"type":"Destination"}],"links":[[1,1,0,2,0,"*"],[2,2,0,3,0,"*"],[3,4,0,3,1,"*"]]}"#
    func testRelayRepeaterPropagatesMuteBypassAndUndo() throws {
        for mode in [Int64(2), 4] {
            var graph = try canvas(relayGraph); let original = graph.root
            let change = try graph.nodeModeChange(nodeID: "1", mode: mode)
            try graph.restoreGroupModes(change.after)
            XCTAssertEqual(graph.root["nodes"]?.arrayValue?[2]["mode"], .integer(mode))
            XCTAssertEqual(graph.root["nodes"]?.arrayValue?[3]["mode"], .integer(mode))
            XCTAssertNil(graph.root["nodes"]?.arrayValue?[1]["mode"])
            try graph.restoreGroupModes(change.before); XCTAssertEqual(graph.root, original)
        }
    }
    func testRelayNothingDoesNotChangeDestination() throws {
        let input = relayGraph.replacingOccurrences(of: #""id":2,"type":"Mute / Bypass Relay (rgthree)""#, with: #""id":2,"type":"Mute / Bypass Relay (rgthree)","properties":{"on_muted_inputs":"NOTHING"}"#)
        let graph = try canvas(input)
        let change = try graph.nodeModeChange(nodeID: "1", mode: 2)
        XCTAssertEqual(change.after, .object(["1": .integer(2)]))
    }
    func testRepeaterWithoutInputsControlsItsContainingGroup() throws {
        var graph = try WorkflowCanvas(data: root([node(14, "Mute / Bypass Repeater (rgthree)"), node(15, "Model"), node(16, "Outside", x: 500)], groups: [group]).data())
        let change = try graph.nodeModeChange(nodeID: "14", mode: 4)
        try graph.restoreGroupModes(change.after)
        XCTAssertEqual(graph.root["nodes"]?.arrayValue?[1]["mode"], .integer(4))
        XCTAssertNil(graph.root["nodes"]?.arrayValue?[2]["mode"])
    }
    func testRelayFeedbackCycleFailsWithoutPartialEdits() throws {
        let text = #"{"nodes":[{"id":1,"type":"Mute / Bypass Repeater (rgthree)","inputs":[{"link":2}]},{"id":2,"type":"Mute / Bypass Relay (rgthree)","properties":{"on_any_active_inputs":"MUTE","on_muted_inputs":"ACTIVE"},"inputs":[{"link":1}]}],"links":[[1,1,0,2,0,"*"],[2,2,0,1,0,"*"]]}"#
        let graph = try canvas(text), before = graph.root
        XCTAssertThrowsError(try graph.nodeModeChange(nodeID: "1", mode: 2))
        XCTAssertEqual(graph.root, before)
    }
    func testCollectorCycleIsReportedInsteadOfHanging() throws {
        let graph = try canvas(#"{"nodes":[{"id":1,"type":"Node Collector (rgthree)","inputs":[{"link":1}]},{"id":2,"type":"Fast Muter (rgthree)","inputs":[{"link":2}]}],"links":[[1,1,0,1,0,"*"],[2,1,0,2,0,"*"]]}"#)
        XCTAssertNotNil(graph.groupSwitchIssues["2"]); XCTAssertTrue(graph.groupSwitches.isEmpty)
    }
    func testStaleControlWireIsReportedInsteadOfTargetingAnotherNode() throws {
        let graph = try canvas(#"{"nodes":[{"id":1,"type":"Source"},{"id":2,"type":"Fast Muter (rgthree)","inputs":[{"link":99}]}],"links":[[1,1,0,2,0,"*"]]}"#)
        XCTAssertNotNil(graph.groupSwitchIssues["2"]); XCTAssertTrue(graph.groupSwitches.isEmpty)
    }
    func testNestedBackendSwitchEditAndExportPreserveWidgetOrder() throws {
        var graph = try canvas(#"{"nodes":[{"id":12,"type":"sub"}],"links":[],"definitions":{"subgraphs":[{"id":"sub","nodes":[{"id":12,"type":"ImpactSwitch","widgets_values_named":{"select":2,"sel_mode":false},"widgets_values":[2,false]}],"links":[]}]}}"#)
        let select = try XCTUnwrap(graph.fields.first { $0.title.hasSuffix("select") })
        try graph.update(fieldID: select.id, value: .integer(3))
        XCTAssertEqual(graph.root["definitions"]?["subgraphs"]?.arrayValue?[0]["nodes"]?.arrayValue?[0]["widgets_values"]?.arrayValue?[0], .integer(3))
        var imported = try WorkflowCanvas(data: graph.exportData())
        try imported.update(fieldID: select.id, value: .integer(4))
        XCTAssertEqual(imported.fields.first { $0.id == select.id }?.value, .integer(4))
    }
    func testManualModeInvalidTargetsFailAtomically() throws {
        var graph = try canvas(#"{"nodes":[{"id":1,"type":"A"}],"links":[]}"#)
        let original = graph.root
        XCTAssertThrowsError(try graph.nodeModeChange(nodeID: "1", mode: 3))
        XCTAssertThrowsError(try graph.restoreGroupModes(.object(["missing": .integer(4), "1": .integer(2)])))
        XCTAssertEqual(graph.root, original)
    }
    func testServerSwitchesKeepSelectionAndOriginalLinks() throws {
        for type in ["LazySwitchKJ", "easy ifElse"] {
            let key = type == "LazySwitchKJ" ? "switch" : "boolean"
            let graph = #"{"nodes":[{"id":1,"type":"Source","outputs":[{"type":"IMAGE"}]},{"id":2,"type":"TYPE","widgets_values":[true],"inputs":[{"name":"on_true","link":1},{"name":"on_false","link":2}],"outputs":[]}],"links":[[1,1,0,2,0,"IMAGE"],[2,1,0,2,1,"IMAGE"]]}"#.replacingOccurrences(of: "TYPE", with: type)
            let schema = #"{"Source":{"input":{}},"TYPE":{"output_node":true,"input":{"required":{"KEY":["BOOLEAN"],"on_true":["*",{"lazy":true}],"on_false":["*",{"lazy":true}]}}}}"#.replacingOccurrences(of: "TYPE", with: type).replacingOccurrences(of: "KEY", with: key)
            let result = try JSONValue(data: UIWorkflowConverter.convert(data: Data(graph.utf8), objectInfoData: Data(schema.utf8)))
            XCTAssertEqual(result["2"]?["class_type"], .string(type))
            XCTAssertEqual(result["2"]?["inputs"]?[key], .bool(true))
            XCTAssertEqual(result["2"]?["inputs"]?["on_false"], .array([.string("1"), .integer(0)]))
        }
    }
    func testImpactDynamicPortsAndUnknownPortsAreNotConfused() throws {
        let graph = #"{"nodes":[{"id":9,"type":"Source","outputs":[{"type":"IMAGE"}]},{"id":20,"type":"ImpactSwitch","widgets_values":[12,false],"inputs":[{"name":"input12","link":1}],"outputs":[]}],"links":[[1,9,0,20,0,"IMAGE"]]}"#
        let schema = #"{"Source":{"input":{}},"ImpactSwitch":{"output_node":true,"input":{"required":{"select":["INT"],"sel_mode":["BOOLEAN"]},"optional":{"input1":["*",{"lazy":true}]}}}}"#
        let result = try JSONValue(data: UIWorkflowConverter.convert(data: Data(graph.utf8), objectInfoData: Data(schema.utf8)))
        XCTAssertEqual(result["20"]?["inputs"]?["select"], .integer(12))
        XCTAssertEqual(result["20"]?["inputs"]?["input12"], .array([.string("9"), .integer(0)]))
        XCTAssertThrowsError(try UIWorkflowConverter.convert(data: Data(graph.replacingOccurrences(of: "input12", with: "input12_extra").utf8), objectInfoData: Data(schema.utf8)))
    }
    func testLegacyImpactAliasUsesCurrentServerPortsWithoutEditingSource() throws {
        let text = #"{"nodes":[{"id":1,"type":"Source","outputs":[{"type":"LATENT"}]},{"id":2,"type":"LatentSwitch","widgets_values":[3],"inputs":[{"name":"latent3","link":1}],"outputs":[]}],"links":[[1,1,0,2,0,"LATENT"]]}"#
        let schema = #"{"Source":{"input":{}},"LatentSwitch":{"output_node":true,"input":{"required":{"select":["INT"],"sel_mode":["BOOLEAN",{"default":false}]},"optional":{"input1":["*",{"lazy":true}]}}}}"#
        let data = Data(text.utf8)
        let result = try JSONValue(data: UIWorkflowConverter.convert(data: data, objectInfoData: Data(schema.utf8)))
        XCTAssertEqual(result["2"]?["inputs"]?["input3"], .array([.string("1"), .integer(0)]))
        XCTAssertEqual(result["2"]?["inputs"]?["sel_mode"], .bool(false))
        XCTAssertNil(result["2"]?["inputs"]?["latent3"])
        XCTAssertEqual(String(data: data, encoding: .utf8), text)
    }
    func testServerOrderedWidgetsDoNotDependOnJSONDictionaryOrder() throws {
        let graph = #"{"nodes":[{"id":101,"type":"PluginSwitch","widgets_values":[4,true],"outputs":[]}],"links":[]}"#
        let schema = #"{"PluginSwitch":{"output_node":true,"input":{"required":{"enabled":["BOOLEAN"],"choice":["INT"]}},"input_order":{"required":["choice","enabled"]}}}"#
        let result = try JSONValue(data: UIWorkflowConverter.convert(data: Data(graph.utf8), objectInfoData: Data(schema.utf8)))
        XCTAssertEqual(result["101"]?["inputs"]?["choice"], .integer(4))
        XCTAssertEqual(result["101"]?["inputs"]?["enabled"], .bool(true))
        XCTAssertThrowsError(try UIWorkflowConverter.convert(data: Data(graph.utf8), objectInfoData: Data(schema.replacingOccurrences(of: #"["choice","enabled"]"#, with: #"["choice","choice"]"#).utf8)))
    }
    private let interfaceGraph = #"{"nodes":[{"id":10,"type":"sub","widgets_values":[true],"inputs":[{"name":"switch","type":"BOOLEAN","widget":{"name":"switch"},"link":null}],"outputs":[]},{"id":11,"type":"sub","widgets_values":[false],"inputs":[{"name":"switch","type":"BOOLEAN","widget":{"name":"switch"},"link":null}],"outputs":[]}],"links":[],"definitions":{"subgraphs":[{"id":"sub","widgets":[],"inputs":[{"name":"switch","type":"BOOLEAN"}],"outputs":[],"inputNode":{"id":-1},"outputNode":{"id":-2},"nodes":[{"id":6,"type":"Sink","inputs":[{"name":"enabled","type":"BOOLEAN","link":90}],"outputs":[]}],"links":[[90,-1,0,6,0,"BOOLEAN"]]}]}}"#
    func testSubgraphInterfaceValuesAreInstanceLocalAndSourceIsUnchanged() throws {
        let data = Data(interfaceGraph.utf8), original = try value(interfaceGraph)
        let info = Data(#"{"Sink":{"output_node":true,"input":{"required":{"enabled":["BOOLEAN"]}}}}"#.utf8)
        let result = try JSONValue(data: UIWorkflowConverter.convert(data: data, objectInfoData: info))
        XCTAssertEqual(result["10:6"]?["inputs"]?["enabled"], .bool(true))
        XCTAssertEqual(result["11:6"]?["inputs"]?["enabled"], .bool(false))
        XCTAssertEqual(Set(result.objectValue!.keys), Set(["10:6", "11:6"]))
        XCTAssertEqual(try JSONValue(data: data), original)
        let exported = try WorkflowCanvas(data: data).exportData()
        XCTAssertEqual(try JSONValue(data: UIWorkflowConverter.convert(data: exported, objectInfoData: info)), result)
    }
    func testLinkedInterfaceInputWinsOverStaleInstanceWidget() throws {
        var object = try value(interfaceGraph).objectValue!
        var nodes = object["nodes"]!.arrayValue!, first = nodes[0].objectValue!
        first["inputs"] = try value(#"[{"name":"switch","type":"BOOLEAN","widget":{"name":"switch"},"link":9}]"#)
        nodes[0] = .object(first)
        nodes.append(try value(#"{"id":8,"type":"BooleanSource","outputs":[{"type":"BOOLEAN"}]}"#))
        object["nodes"] = .array(nodes); object["links"] = try value(#"[[9,8,0,10,0,"BOOLEAN"]]"#)
        let info = Data(#"{"BooleanSource":{"input":{}},"Sink":{"output_node":true,"input":{"required":{"enabled":["BOOLEAN"]}}}}"#.utf8)
        let result = try JSONValue(data: UIWorkflowConverter.convert(data: JSONValue.object(object).data(), objectInfoData: info))
        XCTAssertEqual(result["10:6"]?["inputs"]?["enabled"], .array([.string("8"), .integer(0)]))
    }
    func testLegacyExplicitProxyMappingPreservesIndependentInstances() throws {
        let text = #"{"nodes":[{"id":10,"type":"sub","properties":{"proxyWidgets":[[6,"switch"]]},"widgets_values":[true],"inputs":[],"outputs":[]},{"id":11,"type":"sub","properties":{"proxyWidgets":[[6,"switch"]]},"widgets_values":[false],"inputs":[],"outputs":[]}],"links":[],"definitions":{"subgraphs":[{"id":"sub","inputs":[],"outputs":[],"inputNode":{"id":-1},"outputNode":{"id":-2},"nodes":[{"id":6,"type":"LazySwitchKJ","widgets_values":[false],"inputs":[],"outputs":[]}],"links":[]}]}}"#
        let info = Data(#"{"LazySwitchKJ":{"output_node":true,"input":{"required":{"switch":["BOOLEAN"]}}}}"#.utf8)
        let result = try JSONValue(data: UIWorkflowConverter.convert(data: Data(text.utf8), objectInfoData: info))
        XCTAssertEqual(result["10:6"]?["inputs"]?["switch"], .bool(true))
        XCTAssertEqual(result["11:6"]?["inputs"]?["switch"], .bool(false))
        let broken = text.replacingOccurrences(of: #"[6,"switch"]"#, with: #"[6,"unknown"]"#)
        XCTAssertThrowsError(try UIWorkflowConverter.convert(data: Data(broken.utf8), objectInfoData: info))
        var graph = try canvas(text)
        let first = try XCTUnwrap(graph.nodes.first { $0.id == "10" }?.fields.first)
        XCTAssertTrue(first.name.hasPrefix("__proxy_"))
        try graph.update(fieldID: first.id, value: .bool(false))
        let edited = try JSONValue(data: UIWorkflowConverter.convert(data: graph.data(), objectInfoData: info))
        XCTAssertEqual(edited["10:6"]?["inputs"]?["switch"], .bool(false))
        XCTAssertEqual(edited["11:6"]?["inputs"]?["switch"], .bool(false))
    }
    func testSupportedPluginWidgetLayoutsRetainParameterTypes() throws {
        for (type, keys) in WorkflowWidgetLayout.switchLayouts {
            var fields: [String: JSONValue] = [:], values: [JSONValue] = []
            for key in keys {
                let isBool = ["boolean", "switch", "sel_mode", "A or B", "continue"].contains(key)
                fields[key] = .array([.string(isBool ? "BOOLEAN" : "INT")])
                values.append(isBool ? .bool(false) : .integer(2))
            }
            var raw = node(712, type).objectValue!; raw["widgets_values"] = .array(values)
            let info = JSONValue.object([type: .object(["output_node": .bool(true), "input": .object(["required": .object(fields)])])])
            let data = try root([.object(raw)]).data()
            var graph = try WorkflowCanvas(data: data, objectInfo: ObjectInfo(data: info.data()))
            XCTAssertEqual(graph.fields.map(\.name), keys, type)
            let field = try XCTUnwrap(graph.fields.first)
            let changed: JSONValue = field.value.boolValue == nil ? .integer(3) : .bool(true)
            try graph.update(fieldID: field.id, value: changed)
            let result = try JSONValue(data: UIWorkflowConverter.convert(data: graph.data(), objectInfoData: info.data()))
            XCTAssertEqual(result["712"]?["inputs"]?[keys[0]], changed, type)
        }
    }
    func testNestedSnapshotSurvivesJournalPersistenceUndoAndRedo() throws {
        var inner = root([node(1, "Source")]).objectValue!; inner["id"] = .string("sub")
        var graph = try WorkflowCanvas(data: root([node(1, "sub")], definitions: [.object(inner)]).data())
        let initial = graph.root, change = try graph.nodeModeChange(nodeID: "1", mode: 4)
        var journal = WorkflowJournal()
        journal.record(WorkflowChange(kind: .groupModes, label: "scope", before: change.before, after: change.after))
        try graph.restoreGroupModes(change.after)
        let updated = graph.root
        journal = try JSONDecoder().decode(WorkflowJournal.self, from: JSONEncoder().encode(journal))
        try graph.restoreGroupModes(XCTUnwrap(journal.undo()).before); XCTAssertEqual(graph.root, initial)
        try graph.restoreGroupModes(XCTUnwrap(journal.redo()).after); XCTAssertEqual(graph.root, updated)
    }
}
