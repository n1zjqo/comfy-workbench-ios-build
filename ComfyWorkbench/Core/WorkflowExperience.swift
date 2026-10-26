import Foundation
import CoreGraphics

struct SavedWorkflow: Codable, Identifiable {
    var id = UUID()
    var name: String
    var data: Data
    var pinned: Set<String> = []
    var promptField: String?
    var randomSeedFields: Set<String> = []
    var canvasWidgetOrder: [String: [String]]?
    var panelItems: [PanelFieldConfiguration]?
    var journal: WorkflowJournal?
    var editorDrafts: [String: String]?
    var chatDraft: String?
    var viewport: CanvasViewport?
    var editedAt: Date?
}


public struct CanvasViewport: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var zoom: Double
    public var valid: Bool { x.isFinite && y.isFinite && abs(x) < 100_000_000 && abs(y) < 100_000_000 && zoom.isFinite && zoom >= 0.000005 && zoom <= 3 }
}

public enum ArtworkMetrics {
    public static func constrainedPan(_ proposed: CGSize, image: CGSize, viewport: CGSize, zoom: CGFloat) -> CGSize {
        let x = max(0, (image.width * zoom - viewport.width) / 2)
        let y = max(0, (image.height * zoom - viewport.height) / 2)
        return CGSize(width: min(x, max(-x, proposed.width)), height: min(y, max(-y, proposed.height)))
    }
    public static func fittedSize(image: CGSize, available: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, available.width > 0, available.height > 0,
              image.width.isFinite, image.height.isFinite, available.width.isFinite, available.height.isFinite else { return .zero }
        let scale = min(available.width / image.width, available.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    public static func radius(_ desired: CGFloat, size: CGSize, inset: CGFloat = 0) -> CGFloat {
        max(0, min(desired - inset, min(size.width, size.height) / 2 - inset))
    }
}

public struct PanelFieldConfiguration: Codable, Identifiable, Equatable {
    public enum Control: String, Codable, CaseIterable { case automatic, text, multiline, slider, choices, toggle }
    public var id: String
    public var label = ""
    public var group = ""
    public var control: Control = .automatic
    public var minimum: Double?
    public var maximum: Double?
    public var step: Double?
    public var choices: [String] = []
    public init(id: String) { self.id = id }
    public func title(for field: WorkflowField) -> String { label.isEmpty ? field.name : label }
    public func sliderRange(for field: WorkflowField) -> ClosedRange<Double>? {
        guard field.schema.kind == .integer || field.schema.kind == .decimal,
              !field.name.lowercased().contains("seed"),
              let low = minimum ?? field.schema.minimum, let high = maximum ?? field.schema.maximum,
              low.isFinite, high.isFinite, low < high,
              abs(low) <= 9_007_199_254_740_991, abs(high) <= 9_007_199_254_740_991 else { return nil }
        return low...high
    }
    public func validate(for field: WorkflowField) throws {
        guard id == field.id else { throw WorkflowError.invalid("面板参数与节点不匹配。") }
        switch control {
        case .slider:
            guard let range = sliderRange(for: field) else { throw WorkflowError.invalid("滑块需要有效的最小值和最大值；种子请保留整数输入。") }
            let increment = step ?? field.schema.step ?? (field.schema.kind == .integer ? 1 : 0.1)
            guard increment.isFinite, increment > 0, increment <= range.upperBound - range.lowerBound else { throw WorkflowError.invalid("滑块步长必须大于 0，且不超过范围。") }
            if field.schema.kind == .integer {
                guard range.lowerBound.rounded() == range.lowerBound, range.upperBound.rounded() == range.upperBound, increment.rounded() == increment else { throw WorkflowError.invalid("整数参数的滑块范围与步长必须是整数。") }
            }
            if let bound = field.schema.minimum, range.lowerBound < bound { throw WorkflowError.invalid("滑块最小值低于服务器允许范围。") }
            if let bound = field.schema.maximum, range.upperBound > bound { throw WorkflowError.invalid("滑块最大值超过服务器允许范围。") }
        case .choices:
            guard !choices.isEmpty, choices.count <= 100, Set(choices).count == choices.count else { throw WorkflowError.invalid("请填写 1–100 个不重复的选项，每行一个。") }
            for option in choices {
                let parsed = try field.parsedValue(from: option)
                if let number = parsed.doubleValue {
                    if let low = field.schema.minimum, number < low { throw WorkflowError.invalid("选项低于服务器最小值。") }
                    if let high = field.schema.maximum, number > high { throw WorkflowError.invalid("选项超过服务器最大值。") }
                }
            }
        case .toggle: guard field.schema.kind == .boolean else { throw WorkflowError.invalid("开关只用于布尔参数。") }
        case .multiline: guard field.schema.kind == .text else { throw WorkflowError.invalid("多行输入只用于文本参数。") }
        case .automatic, .text: break
        }
    }
}

public struct WorkflowChange: Codable, Equatable {
    public enum Kind: String, Codable { case parameter, panel, prompt, randomSeeds }
    public var kind: Kind
    public var fieldID: String?
    public var label: String
    public var before: JSONValue
    public var after: JSONValue
}

/// Small value changes only: never retain forty copies of a large workflow or media.
public struct WorkflowJournal: Codable, Equatable {
    public private(set) var past: [WorkflowChange] = []
    public private(set) var future: [WorkflowChange] = []
    public init() {}
    public mutating func record(_ change: WorkflowChange) {
        guard change.before != change.after else { return }
        future = []; past.append(change)
        while past.count > 40 || ((try? JSONEncoder().encode(past).count) ?? 0) > 2_000_000 {
            guard !past.isEmpty else { break }; past.removeFirst()
        }
    }
    public mutating func undo() -> WorkflowChange? {
        guard let change = past.popLast() else { return nil }; future.append(change); return change
    }
    public mutating func redo() -> WorkflowChange? {
        guard let change = future.popLast() else { return nil }; past.append(change); return change
    }
}

public struct ExecutionTrace: Codable, Equatable {
    public enum Phase: String, Codable { case queued, running, completed, failed, interrupted, disconnected }
    public var phase: Phase = .queued
    public var activeNode: String?
    public var completedNodes: Set<String> = []
    public var cachedNodes: Set<String> = []
    public var failedNode: String?
    public var fraction: Double?
    public var detail: String?
    public init() {}
    public mutating func receive(type: String, node: String?, nodes: [String] = [], value: Double? = nil, maximum: Double? = nil, message: String? = nil) {
        guard ![Phase.completed, .failed, .interrupted].contains(phase) else { return }
        switch type {
        case "execution_start": phase = .running; activeNode = nil; fraction = nil
        case "execution_cached": cachedNodes.formUnion(nodes)
        case "executing":
            // The server signals the next node, not a completion event for every node.
            if let active = activeNode, active != node { completedNodes.insert(active) }
            activeNode = node; fraction = nil; phase = .running
        case "progress":
            guard let node = node ?? activeNode else { return }
            if let previous = activeNode, previous != node { completedNodes.insert(previous) }
            activeNode = node; phase = .running
            if let value = value, let maximum = maximum, value.isFinite, maximum.isFinite, maximum > 0 { fraction = max(0, min(1, value / maximum)) }
        case "executed": if let node = node { completedNodes.insert(node) }
        case "execution_success":
            if let active = activeNode { completedNodes.insert(active) }
            activeNode = nil; fraction = nil; phase = .completed
        case "execution_error", "execution_interrupted":
            failedNode = node ?? activeNode; completedNodes.formUnion(nodes)
            if let failed = failedNode { completedNodes.remove(failed) }
            activeNode = nil; fraction = nil; detail = message
            phase = type == "execution_error" ? .failed : .interrupted
        default: break
        }
    }
    public mutating func disconnect() {
        guard phase == .running || phase == .queued else { return }
        phase = .disconnected; activeNode = nil; fraction = nil
    }
}
