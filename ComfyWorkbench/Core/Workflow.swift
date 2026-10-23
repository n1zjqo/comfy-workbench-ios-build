import Foundation

public enum WorkflowError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct WorkflowNode: Identifiable, Equatable {
    public let id: String
    public let classType: String
    public let inputs: [String: JSONValue]
    public let raw: [String: JSONValue]
}

public struct WorkflowConnection: Identifiable, Equatable {
    public var id: String { "\(targetNodeID).\(targetInputName)" }
    public let sourceNodeID: String
    public let sourceOutputIndex: Int
    public let targetNodeID: String
    public let targetInputName: String
}

public struct WorkflowField: Identifiable, Equatable {
    public typealias ID = String
    public var id: String { "\(nodeID).\(name)" }
    public let nodeID: String
    public let nodeType: String
    public let name: String
    public let value: JSONValue
    public let schema: WorkflowFieldSchema

    public func parsedValue(from text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch schema.kind {
        case .integer:
            if let value = Int64(trimmed) { return .integer(value) }
            if let value = UInt64(trimmed) { return .unsignedInteger(value) }
            throw WorkflowError.invalid("\(name) 需要有效整数，种子支持完整 UInt64 范围。")
        case .decimal:
            guard let value = Double(trimmed), value.isFinite else { throw WorkflowError.invalid("\(name) 需要有效数字。") }
            return .decimal(value)
        case .boolean:
            if trimmed.lowercased() == "true" { return .bool(true) }
            if trimmed.lowercased() == "false" { return .bool(false) }
            throw WorkflowError.invalid("\(name) 需要 true 或 false。")
        case .choice:
            if schema.isUpload { return .string(text) }
            guard let value = schema.options.first(where: { $0.displayValue == text }) else { throw WorkflowError.invalid("请选择服务器提供的 \(name) 选项。") }
            return value
        case .text: return .string(text)
        }
    }
}

/// Editing touches only the chosen input. Unknown node properties and wrapper data survive export.
public struct WorkflowDocument: Equatable {
    private var root: [String: JSONValue]
    private let wrapped: Bool
    public private(set) var objectInfo: ObjectInfo?

    public init(data: Data, objectInfo: ObjectInfo? = nil) throws {
        let json: JSONValue
        do { json = try JSONValue(data: data) }
        catch { throw WorkflowError.invalid("无法读取 JSON：\(error.localizedDescription)") }
        guard let root = json.objectValue else { throw WorkflowError.invalid("工作流应是 JSON 对象。") }
        self.root = root
        self.wrapped = root["prompt"]?.objectValue != nil && root["prompt"]?["class_type"] == nil
        self.objectInfo = objectInfo
        try validate()
    }

    public var prompt: [String: JSONValue] { wrapped ? root["prompt"]?.objectValue ?? [:] : root }
    public var json: JSONValue { .object(root) }

    public var nodes: [WorkflowNode] {
        prompt.compactMap { id, value in
            guard let object = value.objectValue, let classType = object["class_type"]?.stringValue,
                  let inputs = object["inputs"]?.objectValue else { return nil }
            return WorkflowNode(id: id, classType: classType, inputs: inputs, raw: object)
        }.sorted { Self.nodeIDLessThan($0.id, $1.id) }
    }

    public var connections: [WorkflowConnection] {
        nodes.flatMap { node in
            node.inputs.keys.sorted().compactMap { name in
                guard let value = node.inputs[name], let link = try? connection(value, node: node, name: name) else { return nil }
                return link
            }
        }
    }

    public var fields: [WorkflowField] {
        nodes.flatMap { node in
            node.inputs.keys.sorted().compactMap { name in
                guard let value = node.inputs[name], value.isScalar else { return nil }
                let inferred = WorkflowFieldSchema.inferred(name: name, value: value)
                let schema = objectInfo?.schema(for: node.classType, input: name) ?? inferred
                return WorkflowField(nodeID: node.id, nodeType: node.classType, name: name, value: value, schema: schema)
            }
        }
    }

    public func applicationFields(pinnedIDs: Set<String> = []) -> [WorkflowField] {
        if !pinnedIDs.isEmpty { return fields.filter { pinnedIDs.contains($0.id) } }
        let preferred = Set(["text", "prompt", "prompts", "positive", "negative", "seed", "noise_seed", "base_seed", "steps", "cfg", "width", "height", "batch_size", "denoise", "image", "video", "audio", "ckpt_name", "lora_name"])
        let picks = fields.filter { field in
            if ["easy showAnything", "ShowText|pysssss"].contains(field.nodeType) { return false }
            return preferred.contains(field.name.lowercased()) || field.schema.isUpload ||
            (field.nodeType.hasPrefix("Primitive") && field.name == "value")
        }
        return picks.isEmpty ? fields : picks
    }

    public func data(prettyPrinted: Bool = true) throws -> Data { try json.data(prettyPrinted: prettyPrinted) }
    public func promptData(prettyPrinted: Bool = false) throws -> Data {
        var exported = prompt
        for (id, value) in prompt {
            guard var node = value.objectValue else { continue }
            node.removeValue(forKey: "title")
            if var metadata = node["_meta"]?.objectValue {
                metadata.removeValue(forKey: "title")
                node["_meta"] = .object(metadata)
            }
            exported[id] = .object(node)
        }
        return try JSONValue.object(exported).data(prettyPrinted: prettyPrinted)
    }

    public mutating func applyObjectInfo(_ info: ObjectInfo) throws {
        let previous = objectInfo
        objectInfo = info
        do { try validate() } catch { objectInfo = previous; throw error }
    }

    public mutating func update(fieldID: WorkflowField.ID, fromText text: String) throws {
        guard let field = fields.first(where: { $0.id == fieldID }) else { throw WorkflowError.invalid("参数不存在，连接不能作为参数修改。") }
        try update(fieldID: fieldID, value: field.parsedValue(from: text))
    }

    public mutating func update(fieldID: WorkflowField.ID, value: JSONValue) throws {
        guard let field = fields.first(where: { $0.id == fieldID }) else { throw WorkflowError.invalid("参数不存在，连接不能作为参数修改。") }
        guard value.isScalar else { throw WorkflowError.invalid("此参数只接受单个值；节点连接和复杂结构保持原样。") }
        try validate(value: value, for: field)
        var graph = prompt
        guard var node = graph[field.nodeID]?.objectValue, var inputs = node["inputs"]?.objectValue else { throw WorkflowError.invalid("找不到参数所在的节点。") }
        inputs[field.name] = value
        node["inputs"] = .object(inputs)
        graph[field.nodeID] = .object(node)
        if wrapped { root["prompt"] = .object(graph) } else { root = graph }
    }

    private func validate() throws {
        if prompt["nodes"]?.arrayValue != nil {
            throw WorkflowError.invalid("这是 ComfyUI 画布工作流（nodes/links），不能直接运行。请在原 ComfyUI 中导出 API 格式后导入；包含自定义节点、Set/Get 或绕过节点的画布无法安全自动转换。")
        }
        guard !prompt.isEmpty else { throw WorkflowError.invalid("工作流中没有节点。") }
        for (id, value) in prompt {
            guard let node = value.objectValue, let type = node["class_type"]?.stringValue, !type.isEmpty,
                  node["inputs"]?.objectValue != nil else { throw WorkflowError.invalid("节点 \(id) 缺少 class_type 或 inputs；请导入 API 格式工作流。") }
        }
        for node in nodes {
            for (name, value) in node.inputs { _ = try connection(value, node: node, name: name) }
        }
    }

    private func connection(_ value: JSONValue, node: WorkflowNode, name: String) throws -> WorkflowConnection? {
        guard let pair = value.arrayValue, pair.count == 2, let source = pair[0].stringValue else { return nil }
        let schema = objectInfo?.schema(for: node.classType, input: name)
        if schema?.acceptsLiteralArray == true { return nil }
        let exists = prompt[source] != nil
        let looksLikeNodeID = !source.isEmpty && source.allSatisfy { $0.isNumber }
        // ComfyUI references use a node ID and an integral output index. A pair such
        // as ["red", 0] remains a literal unless node/schema evidence identifies it.
        guard exists || looksLikeNodeID || schema?.connectionOnly == true else { return nil }
        guard let slot = pair[1].uint64Value, let index = Int(exactly: slot) else {
            if exists || schema?.connectionOnly == true { throw WorkflowError.invalid("节点 \(node.id) 的 \(name) 连接输出编号必须是非负整数。") }
            return nil
        }
        guard exists else { throw WorkflowError.invalid("节点 \(node.id) 的 \(name) 引用了不存在的节点 \(source)。") }
        return WorkflowConnection(sourceNodeID: source, sourceOutputIndex: index, targetNodeID: node.id, targetInputName: name)
    }

    private func validate(value: JSONValue, for field: WorkflowField) throws {
        let schema = field.schema
        switch schema.kind {
        case .integer:
            guard value.integerValue != nil || value.uint64Value != nil else { throw WorkflowError.invalid("\(field.name) 必须是整数。") }
        case .decimal:
            guard let number = value.doubleValue, number.isFinite else { throw WorkflowError.invalid("\(field.name) 必须是有限数字。") }
        case .boolean:
            guard value.boolValue != nil else { throw WorkflowError.invalid("\(field.name) 必须是布尔值。") }
        case .text:
            guard value.stringValue != nil || (field.value == .null && value == .null) else { throw WorkflowError.invalid("\(field.name) 必须是文本。") }
        case .choice:
            guard schema.options.contains(value) || (schema.isUpload && value.stringValue != nil) else { throw WorkflowError.invalid("\(field.name) 不在服务器提供的选项中。") }
        }
        if value.doubleValue != nil, let number = Decimal(string: value.displayValue, locale: Locale(identifier: "en_US_POSIX")) {
            if let minimum = schema.minimumValue, let bound = Decimal(string: minimum.displayValue, locale: Locale(identifier: "en_US_POSIX")), number < bound {
                throw WorkflowError.invalid("\(field.name) 不能小于 \(minimum.displayValue)。")
            }
            if let maximum = schema.maximumValue, let bound = Decimal(string: maximum.displayValue, locale: Locale(identifier: "en_US_POSIX")), number > bound {
                throw WorkflowError.invalid("\(field.name) 不能大于 \(maximum.displayValue)。")
            }
        }
    }

    private static func nodeIDLessThan(_ lhs: String, _ rhs: String) -> Bool {
        if let a = UInt64(lhs), let b = UInt64(rhs), a != b { return a < b }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
