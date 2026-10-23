import Foundation

public struct CanvasNode: Identifiable, Equatable {
    public let id: String
    public let type: String
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let inputs: [String]
    public let outputs: [String]
    public let fields: [WorkflowField]
    public let bypassed: Bool
}

public struct CanvasLink: Identifiable, Equatable {
    public let id: String
    public let source: String
    public let sourceSlot: Int
    public let target: String
    public let targetSlot: Int
    public let type: String
}

/// The source remains canonical. A runnable API document is derived separately.
public struct WorkflowCanvas {
    public private(set) var root: JSONValue
    public private(set) var nodes: [CanvasNode] = []
    public private(set) var links: [CanvasLink] = []
    public private(set) var widgetOrder: [String: [String]]
    public let originalLayout: Bool
    private let info: ObjectInfo?
    private static let decorations: Set<String> = ["Note", "MarkdownNote", "忽略多组孤海"]

    public init(data: Data, objectInfo: ObjectInfo? = nil, widgetOrder: [String: [String]] = [:]) throws {
        let normalized = try WorkflowImportData.normalized(data)
        root = try JSONValue(data: normalized)
        info = objectInfo
        originalLayout = root["nodes"]?.arrayValue != nil
        self.widgetOrder = widgetOrder
        if originalLayout {
            // JSON object iteration is unordered. Capture names before canonical serialization.
            var scanner = JSONKeyOrderScanner(data: normalized)
            let orders = scanner.scan()
            for (index, node) in (root["nodes"]?.arrayValue ?? []).enumerated() {
                guard let id = node["id"]?.displayValue, self.widgetOrder[id] == nil,
                      let names = orders["nodes/\(index)/widgets_values_named"],
                      let named = node["widgets_values_named"]?.objectValue,
                      let array = node["widgets_values"]?.arrayValue,
                      names.count == array.count, names.map({ named[$0] ?? .null }) == array else { continue }
                self.widgetOrder[id] = names
            }
            try loadUI()
        } else { try loadAPI() }
    }

    public func data() throws -> Data { try root.data(prettyPrinted: true) }
    public func exportData() throws -> Data {
        if !originalLayout { return try WorkflowDocument(data: data(), objectInfo: info).promptData(prettyPrinted: true) }
        // Retain the named-widget insertion order for round trips through ComfyUI.
        func encode(_ value: JSONValue, nodeID: String? = nil, orderedNames: Bool = false) throws -> String {
            if var object = value.objectValue {
                let currentID = object["id"]?.displayValue ?? nodeID
                if object["type"]?.stringValue != nil && object["id"] != nil { object.removeValue(forKey: "title") }
                if let nodes = object["nodes"]?.arrayValue {
                    object["nodes"] = .array(nodes.filter { !Self.decorations.contains($0["type"]?.stringValue ?? "") })
                    object.removeValue(forKey: "groups")
                    let retained = Set((object["nodes"]?.arrayValue ?? []).compactMap { $0["id"]?.displayValue })
                    if let links = object["links"]?.arrayValue {
                        object["links"] = .array(links.filter {
                            if let a = $0.arrayValue, a.count >= 6 { return retained.contains(a[1].displayValue) && retained.contains(a[3].displayValue) }
                            return retained.contains($0["origin_id"]?.displayValue ?? "") && retained.contains($0["target_id"]?.displayValue ?? "")
                        })
                    }
                }
                let preferred = orderedNames ? widgetOrder[nodeID ?? ""] ?? [] : []
                let keys = preferred.filter { object[$0] != nil } + object.keys.filter { !preferred.contains($0) }.sorted()
                let pairs = try keys.map { key -> String in
                    let name = String(data: try JSONValue.string(key).data(), encoding: .utf8)!
                    return name + ":" + (try encode(object[key]!, nodeID: currentID, orderedNames: key == "widgets_values_named"))
                }
                return "{" + pairs.joined(separator: ",") + "}"
            }
            if let array = value.arrayValue { return "[" + (try array.map { try encode($0) }).joined(separator: ",") + "]" }
            return String(data: try value.data(), encoding: .utf8)!
        }
        return Data(try encode(root).utf8)
    }
    public var fields: [WorkflowField] { nodes.flatMap(\.fields) }

    public mutating func update(fieldID: String, fromText text: String) throws {
        guard let field = fields.first(where: { $0.id == fieldID }) else { throw WorkflowError.invalid("找不到这个参数。") }
        let value = try field.parsedValue(from: text)
        // Reuse the API editor's exact type/range validation, including UInt64 seeds.
        let validationJSON = JSONValue.object([field.nodeID: .object(["class_type": .string(field.nodeType), "inputs": .object([field.name: field.value])])])
        var validation = try WorkflowDocument(data: validationJSON.data(), objectInfo: info)
        try validation.update(fieldID: field.id, value: value)
        if !originalLayout {
            var doc = try WorkflowDocument(data: data(), objectInfo: info)
            try doc.update(fieldID: fieldID, value: value)
            root = doc.json; try loadAPI(); return
        }
        guard var object = root.objectValue, var rawNodes = object["nodes"]?.arrayValue,
              let index = rawNodes.firstIndex(where: { $0["id"]?.displayValue == field.nodeID }),
              var raw = rawNodes[index].objectValue else { throw WorkflowError.invalid("节点不存在。") }
        if var named = raw["widgets_values_named"]?.objectValue, named[field.name] != nil {
            if var array = raw["widgets_values"]?.arrayValue {
                guard let names = widgetOrder[field.nodeID], let slot = names.firstIndex(of: field.name),
                      slot < array.count, array[slot] == named[field.name] else {
                    throw WorkflowError.invalid("此节点的命名参数与位置参数无法可靠对应，请在 ComfyUI 中重新保存工作流后导入，或导入 API JSON。")
                }
                array[slot] = value; raw["widgets_values"] = .array(array)
            }
            named[field.name] = value; raw["widgets_values_named"] = .object(named)
        } else if var named = raw["widgets_values"]?.objectValue {
            named[field.name] = value; raw["widgets_values"] = .object(named)
        } else if var array = raw["widgets_values"]?.arrayValue,
                  let slot = namesFor(raw, count: array.count).firstIndex(of: field.name), slot < array.count {
            array[slot] = value; raw["widgets_values"] = .array(array)
        } else { throw WorkflowError.invalid("无法定位这个参数；节点连接保持原样。") }
        rawNodes[index] = .object(raw); object["nodes"] = .array(rawNodes)
        root = .object(object); try loadUI()
    }

    private mutating func loadUI() throws {
        guard let rawNodes = root["nodes"]?.arrayValue, !rawNodes.isEmpty, rawNodes.count <= 3000 else { throw WorkflowError.invalid("画布需包含 1–3000 个节点。") }
        var seen = Set<String>()
        var result: [CanvasNode] = []
        for (index, value) in rawNodes.enumerated() {
            guard let raw = value.objectValue, let id = raw["id"]?.displayValue, !id.isEmpty,
                  let type = raw["type"]?.stringValue, !type.isEmpty, seen.insert(id).inserted else { throw WorkflowError.invalid("画布存在缺失或重复的节点编号。") }
            if Self.decorations.contains(type) { continue }
            let position = Self.pair(raw["pos"]) ?? (Double(index % 5) * 360, Double(index / 5) * 260)
            let size = Self.pair(raw["size"]) ?? (280, 180)
            guard abs(position.0) <= 10_000_000, abs(position.1) <= 10_000_000,
                  size.0 > 0, size.1 > 0, size.0 <= 100_000, size.1 <= 100_000 else { throw WorkflowError.invalid("节点 \(id) 的坐标或尺寸超出支持范围。") }
            var fields: [WorkflowField] = []
            if let named = raw["widgets_values_named"]?.objectValue ?? raw["widgets_values"]?.objectValue {
                let keys = widgetOrder[id] ?? named.keys.sorted()
                for name in keys where named[name]?.isScalar == true {
                    let v = named[name]!
                    fields.append(WorkflowField(nodeID: id, nodeType: type, name: name, value: v, schema: info?.schema(for: type, input: name) ?? .inferred(name: name, value: v)))
                }
                // Preserve additional named inputs even if the stored positional map is older.
                for name in named.keys.sorted() where !keys.contains(name) && named[name]?.isScalar == true {
                    let v = named[name]!
                    fields.append(WorkflowField(nodeID: id, nodeType: type, name: name, value: v, schema: info?.schema(for: type, input: name) ?? .inferred(name: name, value: v)))
                }
            } else if let array = raw["widgets_values"]?.arrayValue {
                let names = namesFor(raw, count: array.count)
                fields = array.enumerated().compactMap { slot, v in
                    guard v.isScalar else { return nil }
                    let name = names[slot]
                    return WorkflowField(nodeID: id, nodeType: type, name: name, value: v, schema: info?.schema(for: type, input: name) ?? .inferred(name: name, value: v))
                }
            }
            result.append(CanvasNode(id: id, type: type, x: position.0, y: position.1, width: size.0,
                                     height: raw["flags"]?["collapsed"]?.boolValue == true ? 34 : size.1,
                                     inputs: (raw["inputs"]?.arrayValue ?? []).map { $0["name"]?.stringValue ?? "input" },
                                     outputs: (raw["outputs"]?.arrayValue ?? []).map { $0["name"]?.stringValue ?? $0["type"]?.stringValue ?? "output" },
                                     fields: fields, bypassed: raw["mode"]?.integerValue == 4 || raw["mode"]?.integerValue == 2))
        }
        guard !result.isEmpty else { throw WorkflowError.invalid("画布没有可显示的功能节点。") }
        let ids = Set(result.map(\.id))
        let rawLinks = root["links"]?.arrayValue ?? []
        guard rawLinks.count <= 30_000 else { throw WorkflowError.invalid("画布连接超过 30000 条。") }
        var parsed: [CanvasLink] = []
        for (index, link) in rawLinks.enumerated() {
            let a = link.arrayValue
            if let a = a, a.count < 6 { throw WorkflowError.invalid("画布连接格式不完整。") }
            let source = a?[1].displayValue ?? link["origin_id"]?.displayValue ?? ""
            let target = a?[3].displayValue ?? link["target_id"]?.displayValue ?? ""
            guard ids.contains(source), ids.contains(target) else { continue }
            guard let s = (a?[2] ?? link["origin_slot"])?.uint64Value, s < 10000,
                  let t = (a?[4] ?? link["target_slot"])?.uint64Value, t < 10000 else { throw WorkflowError.invalid("画布连接端口编号无效。") }
            parsed.append(CanvasLink(id: String(index), source: source, sourceSlot: Int(s), target: target, targetSlot: Int(t), type: a?[5].displayValue ?? link["type"]?.displayValue ?? ""))
        }
        nodes = result; links = parsed
    }

    private mutating func loadAPI() throws {
        let document = try WorkflowDocument(data: root.data(), objectInfo: info)
        let raw = document.nodes
        guard raw.count <= 3000, document.connections.count <= 30_000 else { throw WorkflowError.invalid("工作流过大，画布最多支持 3000 个节点与 30000 条连接。") }
        let edges = document.connections
        var incoming = Dictionary(uniqueKeysWithValues: raw.map { ($0.id, 0) })
        var outgoing: [String: [String]] = [:]
        for e in edges { incoming[e.targetNodeID, default: 0] += 1; outgoing[e.sourceNodeID, default: []].append(e.targetNodeID) }
        var queue = raw.filter { incoming[$0.id] == 0 }.map(\.id), cursor = 0
        var ranks: [String: Int] = [:]
        while cursor < queue.count {
            let id = queue[cursor]; cursor += 1
            for next in outgoing[id] ?? [] {
                ranks[next] = max(ranks[next] ?? 0, (ranks[id] ?? 0) + 1)
                incoming[next, default: 0] -= 1
                if incoming[next] == 0 { queue.append(next) }
            }
        }
        var heights: [Int: Double] = [:]
        var result: [CanvasNode] = []
        let allFields = Dictionary(grouping: document.fields, by: \.nodeID)
        for node in raw {
            let rank = ranks[node.id] ?? 0
            let fields = allFields[node.id] ?? []
            let inputs = node.inputs.keys.sorted()
            let outputCount = min(1000, (edges.filter { $0.sourceNodeID == node.id }.map(\.sourceOutputIndex).max() ?? -1) + 1)
            let height = Double(max(136, 64 + max(min(fields.count, 4), max(inputs.count, outputCount)) * 25))
            result.append(CanvasNode(id: node.id, type: node.classType, x: Double(rank) * 390, y: heights[rank] ?? 0, width: 280, height: height,
                                     inputs: inputs, outputs: (0..<outputCount).map { "output \($0)" }, fields: fields, bypassed: false))
            heights[rank] = (heights[rank] ?? 0) + height + 72
        }
        nodes = result
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        links = edges.map { CanvasLink(id: $0.id, source: $0.sourceNodeID, sourceSlot: $0.sourceOutputIndex, target: $0.targetNodeID,
                                      targetSlot: byID[$0.targetNodeID]?.inputs.firstIndex(of: $0.targetInputName) ?? 0, type: $0.targetInputName) }
    }

    private static func pair(_ value: JSONValue?) -> (Double, Double)? {
        let a = value?.arrayValue
        let x = a.flatMap { $0.count >= 2 ? $0[0].doubleValue : nil } ?? value?["0"]?.doubleValue
        let y = a.flatMap { $0.count >= 2 ? $0[1].doubleValue : nil } ?? value?["1"]?.doubleValue
        guard let x = x, let y = y, x.isFinite, y.isFinite else { return nil }
        return (x, y)
    }

    private func namesFor(_ raw: [String: JSONValue], count: Int) -> [String] {
        let type = raw["type"]?.stringValue ?? ""
        let names: [String: [String]] = [
            "KSampler": ["seed", "control_after_generate", "steps", "cfg", "sampler_name", "scheduler", "denoise"],
            "KSamplerAdvanced": ["add_noise", "noise_seed", "control_after_generate", "steps", "cfg", "sampler_name", "scheduler", "start_at_step", "end_at_step", "return_with_leftover_noise"],
            "CLIPTextEncode": ["text"], "Text": ["text"], "LoadImage": ["image", "upload"],
            "EmptyLatentImage": ["width", "height", "batch_size"], "EmptySD3LatentImage": ["width", "height", "batch_size"],
            "CheckpointLoaderSimple": ["ckpt_name"], "VAELoader": ["vae_name"], "LoraLoader": ["lora_name", "strength_model", "strength_clip"],
            "LoraLoaderModelOnly": ["lora_name", "strength_model"], "SaveImage": ["filename_prefix"], "SetNode": ["Constant"], "GetNode": ["Constant"]
        ]
        if let known = names[type], known.count == count || (type == "LoadImage" && count == 1) { return Array(known.prefix(count)) }
        return (0..<count).map { "参数 \($0 + 1)" }
    }
}

/// A bounded scanner over already-validated JSON, used only to retain object key order.
private struct JSONKeyOrderScanner {
    let bytes: [UInt8]
    var index = 0
    var orders: [String: [String]] = [:]
    init(data: Data) { bytes = Array(data) }
    mutating func scan() -> [String: [String]] { value(path: "", depth: 0); return orders }
    mutating func space() { while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    mutating func string() -> String {
        let start = index; index += 1
        while index < bytes.count {
            if bytes[index] == 92 { index += 2; continue }
            if bytes[index] == 34 { index += 1; break }
            index += 1
        }
        return (try? JSONDecoder().decode(String.self, from: Data(bytes[start..<min(index, bytes.count)]))) ?? ""
    }
    mutating func value(path: String, depth: Int) {
        guard depth < 128 else { index = bytes.count; return }
        space(); guard index < bytes.count else { return }
        switch bytes[index] {
        case 123:
            index += 1; space(); var keys: [String] = []
            while index < bytes.count && bytes[index] != 125 {
                guard bytes[index] == 34 else { index = bytes.count; return }
                let key = string(); keys.append(key); space(); index += 1
                value(path: path.isEmpty ? key : path + "/" + key, depth: depth + 1); space()
                if index < bytes.count && bytes[index] == 44 { index += 1; space() } else { break }
            }
            orders[path] = keys; index += 1
        case 91:
            index += 1; space(); var slot = 0
            while index < bytes.count && bytes[index] != 93 {
                value(path: path + "/\(slot)", depth: depth + 1); slot += 1; space()
                if index < bytes.count && bytes[index] == 44 { index += 1; space() } else { break }
            }
            index += 1
        case 34: _ = string()
        default: while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        }
    }
}
