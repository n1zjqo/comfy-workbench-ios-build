import XCTest
@testable import ComfyWorkbenchCore
@testable import ComfyWorkbenchNetworking

final class WorkflowExperienceTests: XCTestCase {
    func testArtworkFrameFitsLandscapeAndPortraitWithoutDistorting() {
        let screen = CGSize(width: 347, height: 700)
        let landscape = ArtworkMetrics.fittedSize(image: CGSize(width: 1600, height: 900), available: screen)
        XCTAssertEqual(landscape.width, 347, accuracy: 0.001)
        XCTAssertEqual(landscape.width / landscape.height, 16.0 / 9, accuracy: 0.001)
        let portrait = ArtworkMetrics.fittedSize(image: CGSize(width: 900, height: 1800), available: screen)
        XCTAssertLessThanOrEqual(portrait.height, 700)
        XCTAssertEqual(portrait.height / portrait.width, 2, accuracy: 0.001)
        XCTAssertEqual(ArtworkMetrics.fittedSize(image: .zero, available: screen), .zero)
    }
    func testCapsuleCornersStayWithinShortControlBounds() {
        XCTAssertEqual(ArtworkMetrics.radius(30, size: CGSize(width: 330, height: 54)), 27)
        XCTAssertEqual(ArtworkMetrics.radius(30, size: CGSize(width: 330, height: 54), inset: 0.5), 26.5)
        XCTAssertEqual(ArtworkMetrics.radius(12, size: CGSize(width: 300, height: 170)), 12)
        XCTAssertEqual(ArtworkMetrics.radius(22, size: CGSize(width: 0, height: 0)), 0)
    }
    func testLegacyWorkflowDecodesWithoutNewDraftProperties() throws {
        let old = #"{"id":"00000000-0000-0000-0000-000000000001","name":"Example","data":"e30=","pinned":["1.text"],"randomSeedFields":[]}"#
        let workflow = try JSONDecoder().decode(SavedWorkflow.self, from: Data(old.utf8))
        XCTAssertEqual(workflow.pinned, ["1.text"])
        XCTAssertNil(workflow.journal); XCTAssertNil(workflow.panelItems); XCTAssertNil(workflow.editorDrafts)
    }
    func testDraftsCameraPanelAndUndoSurviveRelaunchEncoding() throws {
        var workflow = SavedWorkflow(name: "Example", data: Data("{}".utf8))
        workflow.chatDraft = "unfinished chat"
        workflow.editorDrafts = ["1.text": "unfinished parameter"]
        workflow.viewport = CanvasViewport(x: -130, y: 440, zoom: 0.7)
        var item = PanelFieldConfiguration(id: "1.text"); item.label = "描述"; item.group = "画面"
        workflow.panelItems = [item]
        var journal = WorkflowJournal()
        journal.record(WorkflowChange(kind: .parameter, fieldID: "1.seed", label: "seed", before: .unsignedInteger(UInt64.max), after: .integer(123)))
        workflow.journal = journal
        let restored = try JSONDecoder().decode(SavedWorkflow.self, from: JSONEncoder().encode(workflow))
        XCTAssertEqual(restored.chatDraft, workflow.chatDraft)
        XCTAssertEqual(restored.editorDrafts, workflow.editorDrafts)
        XCTAssertEqual(restored.viewport, workflow.viewport)
        XCTAssertEqual(restored.panelItems, workflow.panelItems)
        XCTAssertEqual(restored.journal?.past.first?.before.uint64Value, UInt64.max)
    }
    func testUndoRedoKeepsFullSeedAndBranchesInvalidateRedo() throws {
        var graph = try WorkflowCanvas(data: Data(#"{"1":{"class_type":"Seed","inputs":{"seed":18446744073709551615}}}"#.utf8))
        let change = WorkflowChange(kind: .parameter, fieldID: "1.seed", label: "seed", before: .unsignedInteger(UInt64.max), after: .integer(42))
        var history = WorkflowJournal(); history.record(change)
        try graph.update(fieldID: "1.seed", value: change.after)
        let undo = try XCTUnwrap(history.undo()); try graph.update(fieldID: "1.seed", value: undo.before)
        XCTAssertEqual(graph.fields.first?.value.uint64Value, UInt64.max)
        history = try JSONDecoder().decode(WorkflowJournal.self, from: JSONEncoder().encode(history))
        let redo = try XCTUnwrap(history.redo()); try graph.update(fieldID: "1.seed", value: redo.after)
        XCTAssertEqual(graph.fields.first?.value.integerValue, 42)
        _ = history.undo()
        history.record(WorkflowChange(kind: .parameter, fieldID: "1.seed", label: "seed", before: .unsignedInteger(UInt64.max), after: .integer(9)))
        XCTAssertNil(history.redo())
    }
    func testHistoryIsBoundedAndDoesNotRecordNoOpChanges() {
        var history = WorkflowJournal()
        for n in 0..<80 { history.record(WorkflowChange(kind: .parameter, fieldID: "1.steps", label: "steps", before: .integer(Int64(n)), after: .integer(Int64(n + 1)))) }
        XCTAssertEqual(history.past.count, 40)
        history.record(WorkflowChange(kind: .parameter, fieldID: "1.steps", label: "steps", before: .integer(80), after: .integer(80)))
        XCTAssertEqual(history.past.count, 40)
    }
    func testPanelAliasDoesNotChangeWorkflowNodeNameOrInputKey() throws {
        let data = Data(#"{"1":{"class_type":"CLIPTextEncode","inputs":{"text":"sample"}}}"#.utf8)
        let graph = try WorkflowCanvas(data: data)
        let field = try XCTUnwrap(graph.fields.first)
        var config = PanelFieldConfiguration(id: field.id); config.label = "画面描述"; config.group = "基础"; config.control = .multiline
        try config.validate(for: field)
        XCTAssertEqual(config.title(for: field), "画面描述")
        XCTAssertEqual(graph.nodes.first?.type, "CLIPTextEncode")
        XCTAssertEqual(graph.fields.first?.name, "text")
        XCTAssertEqual(try WorkflowCanvas(data: graph.data()).fields.first?.value, .string("sample"))
    }
    func testSliderHonorsServerLimitsAndIntegerPrecision() throws {
        let schema = WorkflowFieldSchema(kind: .integer, minimumValue: .integer(1), maximumValue: .integer(100), step: 1)
        let field = WorkflowField(nodeID: "1", nodeType: "Sampler", name: "steps", value: .integer(20), schema: schema)
        var config = PanelFieldConfiguration(id: field.id); config.control = .slider; config.minimum = 1; config.maximum = 50; config.step = 1
        XCTAssertNoThrow(try config.validate(for: field))
        config.minimum = 0; XCTAssertThrowsError(try config.validate(for: field))
        config.minimum = 1; config.step = 0.5; XCTAssertThrowsError(try config.validate(for: field))
        config.step = 1; config.maximum = .infinity; XCTAssertThrowsError(try config.validate(for: field))
        let seed = WorkflowField(nodeID: "1", nodeType: "Sampler", name: "seed", value: .unsignedInteger(UInt64.max), schema: .inferred(name: "seed", value: .unsignedInteger(UInt64.max)))
        config.id = seed.id; config.minimum = 0; config.maximum = 100
        XCTAssertThrowsError(try config.validate(for: seed))
    }
    func testCustomChoicesCannotBypassServerChoicesOrRanges() throws {
        let field = WorkflowField(nodeID: "1", nodeType: "Sampler", name: "method", value: .string("euler"), schema: WorkflowFieldSchema(kind: .choice, options: [.string("euler"), .string("heun")]))
        var config = PanelFieldConfiguration(id: field.id); config.control = .choices; config.choices = ["euler", "heun"]
        XCTAssertNoThrow(try config.validate(for: field))
        config.choices = ["not installed"]; XCTAssertThrowsError(try config.validate(for: field))
        config.choices = ["euler", "euler"]; XCTAssertThrowsError(try config.validate(for: field))
    }
    func testExecutionUsesNodeTransitionsAndMarksCachedSeparately() {
        var trace = ExecutionTrace()
        trace.receive(type: "execution_start", node: nil)
        trace.receive(type: "execution_cached", node: nil, nodes: ["1", "2"])
        trace.receive(type: "executing", node: "3")
        trace.receive(type: "progress", node: "3", value: 5, maximum: 20)
        XCTAssertEqual(trace.activeNode, "3"); XCTAssertEqual(trace.fraction, 0.25)
        trace.receive(type: "executing", node: "4")
        XCTAssertEqual(trace.completedNodes, ["3"]); XCTAssertEqual(trace.cachedNodes, ["1", "2"])
        XCTAssertNil(trace.fraction)
        trace.receive(type: "execution_success", node: nil)
        XCTAssertEqual(trace.phase, .completed); XCTAssertNil(trace.activeNode)
        XCTAssertEqual(trace.completedNodes, ["3", "4"])
        trace.receive(type: "progress", node: "3", value: 1, maximum: 2)
        XCTAssertEqual(trace.phase, .completed)
    }
    func testDisconnectClearsStaleRunningNodeAndHistoryCanFinishIt() {
        var trace = ExecutionTrace(); trace.receive(type: "executing", node: "1")
        trace.disconnect(); XCTAssertEqual(trace.phase, .disconnected); XCTAssertNil(trace.activeNode)
        trace.receive(type: "execution_success", node: nil)
        XCTAssertEqual(trace.phase, .completed); XCTAssertTrue(trace.completedNodes.isEmpty)
    }
    func testFailureLocatesNodeAndRejectsInvalidProgress() {
        var trace = ExecutionTrace(); trace.receive(type: "executing", node: "7")
        trace.receive(type: "progress", node: "7", value: .infinity, maximum: 100)
        XCTAssertNil(trace.fraction)
        trace.receive(type: "execution_error", node: "7", message: "Example error")
        XCTAssertEqual(trace.phase, .failed); XCTAssertEqual(trace.failedNode, "7"); XCTAssertNil(trace.activeNode)
        XCTAssertEqual(trace.detail, "Example error")
    }
    func testWebsocketParsesCachedNodesNumericIDsAndCompletion() throws {
        let cached = try XCTUnwrap(ComfyClient.parseEvent(.string(#"{"type":"execution_cached","data":{"prompt_id":"run-a","nodes":["1",2]}}"#)))
        XCTAssertEqual(cached.promptID, "run-a"); XCTAssertEqual(cached.nodes, ["1", "2"])
        let numeric = try XCTUnwrap(ComfyClient.parseEvent(.string(#"{"type":"progress","data":{"prompt_id":"run-a","node":7,"value":2,"max":10}}"#)))
        XCTAssertEqual(numeric.nodeID, "7"); XCTAssertEqual(numeric.value, 2)
        let done = try XCTUnwrap(ComfyClient.parseEvent(.string(#"{"type":"executing","data":{"prompt_id":"run-a","node":null}}"#)))
        XCTAssertNil(done.nodeID); XCTAssertEqual(done.promptID, "run-a")
    }
    func testViewportRejectsNonFiniteOrExtremeValues() {
        XCTAssertTrue(CanvasViewport(x: -100, y: 400, zoom: 0.1).valid)
        XCTAssertFalse(CanvasViewport(x: .infinity, y: 0, zoom: 1).valid)
        XCTAssertFalse(CanvasViewport(x: 0, y: 0, zoom: 0).valid)
        XCTAssertFalse(CanvasViewport(x: 0, y: 0, zoom: 10).valid)
    }
}
