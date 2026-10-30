import Foundation

/// Converts named widgets and an explicit set of standard widget layouts.
/// Unknown frontend extension layouts are rejected instead of guessed.
public enum UIWorkflowConverter {
    public struct ConversionError: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
        public init(_ message: String) { self.message = message }
    }

    public static func convert(data: Data, objectInfoData: Data) throws -> Data {
        let graph = try SubgraphExpansion.expand(JSONValue(data: data))
        let definitions = try JSONValue(data: objectInfoData)
        guard let objectInfo = definitions.objectValue, !objectInfo.isEmpty else {
            throw ConversionError("服务器没有返回节点定义，请先连接 ComfyUI。")
        }
        return try Converter(graph: graph, objectInfo: objectInfo).convert().data(prettyPrinted: true)
    }

    private final class Converter {
        struct Node {
            let id: String
            let type: String
            let mode: Int64
            let raw: JSONValue
            var inputs: [JSONValue] { raw["inputs"]?.arrayValue ?? [] }
            var outputs: [JSONValue] { raw["outputs"]?.arrayValue ?? [] }
        }
        struct Link {
            let source: String
            let slot: Int
            let target: String
            let targetSlot: Int
        }
        struct Rule {
            let schema: [JSONValue]
            let required: Bool
        }

        let objectInfo: [String: JSONValue]
        var nodes: [String: Node] = [:]
        var links: [String: Link] = [:]
        var setters: [String: [Node]] = [:]
        var output: [String: JSONValue] = [:]
        var visiting = Set<String>()

        // These are frontend-only controls in the supplied workflow, with no execution output.
        let decorations: Set<String> = ["Note", "MarkdownNote", "忽略多组孤海", "Label (rgthree)", "Fast Groups Bypasser (rgthree)"]
        let virtualTypes: Set<String> = ["SetNode", "GetNode", "Reroute"]
        let frontendWidgets: Set<String> = [
            "upload", "choose video to upload", "videopreview", "preview", "control_after_generate"
        ]

        init(graph: JSONValue, objectInfo: [String: JSONValue]) throws {
            self.objectInfo = objectInfo
            guard let rawNodes = graph["nodes"]?.arrayValue,
                  let rawLinks = graph["links"]?.arrayValue else {
                throw ConversionError("这不是带 nodes / links 的 ComfyUI 界面工作流。")
            }
            guard rawNodes.count <= 10_000, rawLinks.count <= 100_000 else {
                throw ConversionError("工作流过大，无法在手机上安全转换。")
            }
            for raw in rawNodes {
                guard let id = Self.identifier(raw["id"]), let type = raw["type"]?.stringValue,
                      !type.isEmpty, nodes[id] == nil else {
                    throw ConversionError("工作流有重复或无效的节点 ID。")
                }
                let mode = raw["mode"]?.integerValue ?? 0
                guard [Int64(0), 2, 4].contains(mode) else {
                    throw ConversionError("节点 \(id) 的运行模式不受支持：\(mode)。")
                }
                let node = Node(id: id, type: type, mode: mode, raw: raw)
                nodes[id] = node
                if type == "SetNode", let name = try namedWidgets(node)["Constant"]?.stringValue {
                    setters[name, default: []].append(node)
                }
            }
            for raw in rawLinks {
                guard let parts = raw.arrayValue, parts.count >= 5,
                      let id = Self.identifier(parts[0]), links[id] == nil,
                      let source = Self.identifier(parts[1]), let slot = Self.index(parts[2]),
                      let target = Self.identifier(parts[3]), let targetSlot = Self.index(parts[4]),
                      nodes[source] != nil, nodes[target] != nil else {
                    throw ConversionError("工作流含无效、重复或缺少节点的连线。")
                }
                links[id] = Link(source: source, slot: slot, target: target, targetSlot: targetSlot)
            }
        }

        func convert() throws -> JSONValue {
            var roots: [Node] = []
            for node in nodes.values where node.mode == 0 && !isVirtual(node) && !decorations.contains(node.type) {
                if let definition = objectInfo[node.type] {
                    if definition["output_node"]?.boolValue == true { roots.append(node) }
                } else if node.outputs.isEmpty {
                    // A missing terminal node may itself be an output; do not silently discard it.
                    throw missingSchema(node)
                }
            }
            guard !roots.isEmpty else {
                throw ConversionError("没有找到可执行的输出节点；请检查服务器节点与工作流的开关状态。")
            }
            for root in roots.sorted(by: { $0.id < $1.id }) { try emit(root.id) }
            return .object(output)
        }

        func emit(_ id: String) throws {
            if output[id] != nil { return }
            guard visiting.count < 512 else { throw ConversionError("工作流依赖层级过深。") }
            guard visiting.insert(id).inserted else { throw ConversionError("节点 \(id) 存在循环依赖。") }
            defer { visiting.remove(id) }
            guard let node = nodes[id], node.mode == 0, !isVirtual(node),
                  !decorations.contains(node.type) else {
                throw ConversionError("节点 \(id) 不能直接作为 API 节点执行。")
            }
            guard let definition = objectInfo[node.type], let inputSchema = definition["input"]?.objectValue else {
                throw missingSchema(node)
            }
            var values = try namedWidgets(node)
            var connectedKeys = Set<String>()
            var dependencies = Set<String>()
            var inputNames = Set<String>()
            for (index, input) in node.inputs.enumerated() {
                guard let name = input["name"]?.stringValue, !name.isEmpty,
                      inputNames.insert(name).inserted else {
                    throw ConversionError("节点 \(id) 有重复或无名称的输入。")
                }
                guard let linkID = Self.identifier(input["link"]) else { continue }
                connectedKeys.insert(name)
                values.removeValue(forKey: name) // Linked widgets retain stale UI values; never use those as fallback.
                guard let edge = links[linkID], edge.target == id, edge.targetSlot == index else {
                    throw ConversionError("节点 \(id) 的输入 \(name) 指向无效连线。")
                }
                if let resolved = try resolve(edge.source, slot: edge.slot, path: []) {
                    values[name] = .array([.string(resolved.0), .integer(Int64(resolved.1))])
                    dependencies.insert(resolved.0)
                }
            }
            var rules: [String: Rule] = [:]
            try expand(inputSchema, prefix: "", live: values, rules: &rules, node: node, depth: 0)
            try expandVideoFormat(node, live: values, rules: &rules)
            for key in Array(values.keys) where rules[key] == nil {
                if (frontendWidgets.contains(key) || isKnownFrontendWidget(key, node: node)), !connectedKeys.contains(key) {
                    values.removeValue(forKey: key)
                } else {
                    throw ConversionError("节点 \(id)（\(node.type)）的参数 \(key) 不在服务器定义中，无法无损转换。")
                }
            }
            for (key, rule) in rules {
                guard let value = values[key] else {
                    if rule.required {
                        throw ConversionError("节点 \(id)（\(node.type)）缺少必需输入 \(key)，可能来自已关闭的节点。")
                    }
                    continue
                }
                try validate(value, rule: rule, linked: connectedKeys.contains(key), key: key, node: node)
            }
            for dependency in dependencies.sorted() { try emit(dependency) }
            output[id] = .object(["class_type": .string(node.type), "inputs": .object(values)])
        }

        /// nil means an explicitly muted/bypassed source has no compatible passthrough.
        func resolve(_ id: String, slot: Int, path: Set<String>) throws -> (String, Int)? {
            let token = "\(id):\(slot)"
            guard path.count < 512, !path.contains(token) else {
                throw ConversionError("节点 \(id) 的虚拟连线存在循环或过深的依赖。")
            }
            var nextPath = path
            nextPath.insert(token)
            guard let node = nodes[id], slot >= 0, slot < node.outputs.count else {
                throw ConversionError("连线引用了节点 \(id) 的无效输出 \(slot)。")
            }
            if node.mode == 2 { return nil }
            if node.mode == 4 {
                let outputType = node.outputs[slot]["type"]?.stringValue ?? ""
                guard !outputType.isEmpty else { throw ConversionError("旁路节点 \(id) 缺少输出类型。") }
                let candidates = node.inputs.enumerated().filter { _, input in
                    Self.identifier(input["link"]) != nil && Self.compatible(outputType, input["type"]?.stringValue ?? "")
                }
                guard candidates.count <= 1 else {
                    throw ConversionError("旁路节点 \(id) 有多个同类型输入，无法确定该保留哪条连线。请在 ComfyUI 导出 API 格式。")
                }
                guard let candidate = candidates.first else { return nil }
                return try resolveInput(node, index: candidate.offset, path: nextPath)
            }
            if node.type == "GetNode" {
                guard let name = try namedWidgets(node)["Constant"]?.stringValue,
                      let matches = setters[name], matches.count == 1, let setter = matches.first else {
                    throw ConversionError("GetNode \(id) 没有唯一对应的 SetNode。")
                }
                if setter.mode == 2 { return nil }
                return try resolveInput(setter, index: slot, path: nextPath)
            }
            if node.type == "SetNode" || node.type == "Reroute" {
                guard node.inputs.count == 1, slot == 0 else {
                    throw ConversionError("虚拟节点 \(id) 的端口结构不受支持。")
                }
                return try resolveInput(node, index: 0, path: nextPath)
            }
            if decorations.contains(node.type) { throw ConversionError("执行连线引用了说明节点 \(id)。") }
            return (id, slot)
        }

        func resolveInput(_ node: Node, index: Int, path: Set<String>) throws -> (String, Int)? {
            guard index < node.inputs.count else { throw ConversionError("节点 \(node.id) 缺少透传输入。") }
            guard let id = Self.identifier(node.inputs[index]["link"]) else { return nil }
            guard let edge = links[id], edge.target == node.id, edge.targetSlot == index else {
                throw ConversionError("节点 \(node.id) 的透传连线无效。")
            }
            return try resolve(edge.source, slot: edge.slot, path: path)
        }

        func namedWidgets(_ node: Node) throws -> [String: JSONValue] {
            if let named = node.raw["widgets_values_named"]?.objectValue { return named }
            if let named = node.raw["widgets_values"]?.objectValue { return named }
            if let positional = node.raw["widgets_values"]?.arrayValue, !positional.isEmpty {
                return try standardWidgets(node, positional: positional)
            }
            return [:]
        }

        func isKnownFrontendWidget(_ name: String, node: Node) -> Bool {
            if node.type == "Image Comparer (rgthree)" { return name == "rgthree_comparer" }
            if node.type == "Seed (rgthree)" {
                return ["🎲 Randomize Each Time", "🎲 New Fixed Random", "USE_LAST_SEED"].contains(name)
            }
            return false
        }

        func standardWidgets(_ node: Node, positional: [JSONValue]) throws -> [String: JSONValue] {
            if node.type == "Image Comparer (rgthree)", positional.count == 1,
               positional[0].arrayValue != nil || positional[0].objectValue != nil || positional[0] == .null {
                return ["rgthree_comparer": positional[0]]
            }
            if node.type == "Seed (rgthree)", positional.count == 1 || positional.count == 4,
               positional[0].integerValue != nil || positional[0].uint64Value != nil {
                guard positional.dropFirst().allSatisfy({ $0.stringValue != nil || $0 == .null }) else { throw invalidValue(node, "seed buttons") }
                return ["seed": positional[0]]
            }
            if ["SetNode", "GetNode"].contains(node.type), positional.count == 1, positional[0].stringValue != nil {
                return ["Constant": positional[0]]
            }
            let layouts: [String: [String]] = [
                "CheckpointLoaderSimple": ["ckpt_name"], "CLIPTextEncode": ["text"],
                "EmptyLatentImage": ["width", "height", "batch_size"],
                "EmptySD3LatentImage": ["width", "height", "batch_size"],
                "KSampler": ["seed", "control_after_generate", "steps", "cfg", "sampler_name", "scheduler", "denoise"],
                "KSamplerAdvanced": ["add_noise", "noise_seed", "control_after_generate", "steps", "cfg", "sampler_name", "scheduler", "start_at_step", "end_at_step", "return_with_leftover_noise"],
                "VAELoader": ["vae_name"], "LoraLoader": ["lora_name", "strength_model", "strength_clip"],
                "LoraLoaderModelOnly": ["lora_name", "strength_model"], "SaveImage": ["filename_prefix"],
                "LoadImage": ["image"], "LatentUpscale": ["upscale_method", "width", "height", "crop"],
                "ImageScale": ["upscale_method", "width", "height", "crop"],
                "ImageScaleBy": ["upscale_method", "scale_by"], "LatentUpscaleBy": ["upscale_method", "scale_by"],
                "UpscaleModelLoader": ["model_name"], "CLIPSetLastLayer": ["stop_at_clip_layer"]
            ]
            guard let keys = layouts[node.type], let schema = objectInfo[node.type]?["input"] else {
                throw ConversionError("节点 \(node.id)（\(node.type)）的参数只按位置保存，尚无可靠的转换规则。请在 ComfyUI 导出 API 格式后导入。")
            }
            var values = positional
            if node.type == "LoadImage", values.count == 2, ["image", "image_upload"].contains(values[1].stringValue ?? "") { values.removeLast() }
            guard keys.count == values.count else {
                throw ConversionError("节点 \(node.id)（\(node.type)）的参数数量与标准布局不符，请导出 API 格式。")
            }
            var result: [String: JSONValue] = [:]
            for (key, value) in zip(keys, values) {
                if key == "control_after_generate" {
                    guard ["fixed", "increment", "decrement", "randomize"].contains(value.stringValue ?? "") else { throw invalidValue(node, key) }
                    continue
                }
                guard schema["required"]?[key] != nil || schema["optional"]?[key] != nil else {
                    throw ConversionError("服务器的 \(node.type).\(key) 与标准定义不符，请导出 API 格式。")
                }
                result[key] = value
            }
            return result
        }

        func expand(_ sections: [String: JSONValue], prefix: String, live: [String: JSONValue],
                    rules: inout [String: Rule], node: Node, depth: Int) throws {
            guard depth < 12 else { throw ConversionError("节点 \(node.id) 的动态参数嵌套过深。") }
            for section in ["required", "optional"] {
                for (name, raw) in sections[section]?.objectValue ?? [:] {
                    guard let schema = raw.arrayValue, !schema.isEmpty else {
                        throw ConversionError("服务器返回了无效参数定义：\(node.type).\(name)。")
                    }
                    let key = prefix.isEmpty ? name : "\(prefix).\(name)"
                    let options = schema.count > 1 ? schema[1].objectValue ?? [:] : [:]
                    let type = schema[0].stringValue ?? ""
                    let required = section == "required"
                    switch type {
                    case "COMFY_AUTOGROW_V3":
                        guard let template = options["template"]?.objectValue,
                              let inputs = template["input"]?.objectValue,
                              let minimumValue = template["min"]?.integerValue,
                              minimumValue >= 0, minimumValue <= 100 else {
                            throw ConversionError("节点 \(node.id) 的动态输入 \(key) 缺少可识别模板。")
                        }
                        let minimum = Int(minimumValue)
                        let names: [String]
                        if let list = template["names"]?.arrayValue {
                            names = list.compactMap(\.stringValue)
                            guard names.count == list.count, Set(names).count == names.count else {
                                throw ConversionError("动态输入 \(key) 的名称列表无效。")
                            }
                        } else if let namePrefix = template["prefix"]?.stringValue,
                                  let maximum = template["max"]?.integerValue, maximum >= 1, maximum <= 100 {
                            names = (0..<Int(maximum)).map { "\(namePrefix)\($0)" }
                        } else { throw ConversionError("动态输入 \(key) 使用了不支持的模板。") }
                        guard minimum <= names.count, names.count <= 100 else {
                            throw ConversionError("动态输入 \(key) 的数量范围无效。")
                        }
                        let requiredTemplates = inputs["required"]?.objectValue ?? [:]
                        let optionalTemplates = inputs["optional"]?.objectValue ?? [:]
                        let candidates = Array(requiredTemplates.values) + Array(optionalTemplates.values)
                        guard candidates.count == 1, let child = candidates.first?.arrayValue,
                              !child.isEmpty, !(child[0].stringValue ?? "").hasPrefix("COMFY_DYNAMIC"),
                              child[0].stringValue != "COMFY_AUTOGROW_V3" else {
                            throw ConversionError("动态输入 \(key) 的子参数模板不明确。")
                        }
                        for (index, childName) in names.enumerated() {
                            try addRule("\(key).\(childName)", Rule(schema: child, required: index < minimum && !requiredTemplates.isEmpty), to: &rules)
                        }
                    case "COMFY_DYNAMICCOMBO_V3":
                        try addRule(key, Rule(schema: [.string("STRING")], required: required), to: &rules)
                        guard let selected = live[key]?.stringValue else {
                            if required { throw ConversionError("动态选项 \(key) 缺少选中值。") }
                            continue
                        }
                        let variants = options["options"]?.arrayValue ?? []
                        let matches = variants.filter { $0["key"]?.stringValue == selected }
                        guard matches.count == 1, let children = matches[0]["inputs"]?.objectValue else {
                            throw ConversionError("服务器不支持节点 \(node.id) 的动态选项 \(key)=\(selected)。")
                        }
                        try expand(children, prefix: key, live: live, rules: &rules, node: node, depth: depth + 1)
                    case "COMFY_DYNAMICSLOT_V3":
                        guard let slotType = options["slotType"]?.stringValue,
                              let children = options["inputs"]?.objectValue else {
                            throw ConversionError("动态端口 \(key) 的服务器定义不完整。")
                        }
                        try addRule(key, Rule(schema: [.string(slotType)], required: required), to: &rules)
                        if live[key] != nil {
                            try expand(children, prefix: key, live: live, rules: &rules, node: node, depth: depth + 1)
                        }
                    default:
                        if type.hasPrefix("COMFY_DYNAMIC") || type.hasPrefix("COMFY_AUTOGROW") {
                            throw ConversionError("节点 \(node.id) 使用未支持的动态输入类型 \(type)。")
                        }
                        try addRule(key, Rule(schema: schema, required: required), to: &rules)
                    }
                }
            }
        }

        // VideoHelperSuite declares codec widgets inside the selected format's schema.
        // Only fields advertised by the server are accepted; preview metadata is never submitted.
        func expandVideoFormat(_ node: Node, live: [String: JSONValue], rules: inout [String: Rule]) throws {
            guard node.type == "VHS_VideoCombine", let format = live["format"]?.stringValue,
                  let formatRule = rules["format"], formatRule.schema.count > 1,
                  let widgets = formatRule.schema[1]["formats"]?[format]?.arrayValue else { return }
            for widget in widgets {
                guard let parts = widget.arrayValue, parts.count >= 2, let name = parts[0].stringValue else {
                    throw ConversionError("服务器的视频格式参数定义无效。")
                }
                let schema: [JSONValue] = parts.count > 2 ? [parts[1], parts[2]] : [parts[1]]
                if let existing = rules[name] {
                    guard existing.schema.first == schema.first else { throw ConversionError("视频格式参数 \(name) 与节点定义冲突。") }
                } else { rules[name] = Rule(schema: schema, required: false) }
            }
        }

        func addRule(_ name: String, _ rule: Rule, to rules: inout [String: Rule]) throws {
            guard rules[name] == nil else { throw ConversionError("服务器对参数 \(name) 返回了重复定义。") }
            rules[name] = rule
        }

        func validate(_ value: JSONValue, rule: Rule, linked: Bool, key: String, node: Node) throws {
            if linked {
                guard let array = value.arrayValue, array.count == 2,
                      array[0].stringValue != nil, Self.index(array[1]) != nil else {
                    throw ConversionError("节点 \(node.id) 的连线参数 \(key) 无效。")
                }
                return
            }
            let first = rule.schema[0]
            if first.arrayValue != nil {
                // Model/file names can differ on another server. Preserve the value for editing;
                // the app/server preflight checks availability before queueing a generation.
                guard value.isScalar, value != .null else { throw invalidValue(node, key) }
                return
            }
            guard let type = first.stringValue else { throw invalidValue(node, key) }
            if type == "COMBO" {
                // V3 nodes name the widget type and put choices in schema[1].options.
                // Keep unavailable scalar selections editable, as with legacy combo arrays.
                let options = rule.schema.count > 1 ? rule.schema[1] : .null
                guard options["multiselect"]?.boolValue != true,
                      let choices = options["options"]?.arrayValue,
                      choices.allSatisfy({ $0.isScalar && $0 != .null }),
                      value.isScalar, value != .null else { throw invalidValue(node, key) }
                return
            }
            let types = type.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let valid = types.contains { item in
                switch item {
                case "STRING": return value.stringValue != nil
                case "BOOLEAN", "BOOL": return value.boolValue != nil
                case "INT": return value.integerValue != nil || value.uint64Value != nil
                case "FLOAT", "NUMBER": return value.doubleValue != nil
                case "*": return value.isScalar && value != .null
                default: return false
                }
            }
            guard valid else { throw invalidValue(node, key) }
        }

        func invalidValue(_ node: Node, _ key: String) -> ConversionError {
            ConversionError("节点 \(node.id)（\(node.type)）的参数 \(key) 类型不匹配，不能可靠转换。")
        }
        func missingSchema(_ node: Node) -> ConversionError {
            ConversionError("服务器缺少节点定义 \(node.type)（节点 \(node.id)）。请在包含该节点的 ComfyUI 上连接或导出 API 格式。")
        }
        func isVirtual(_ node: Node) -> Bool { virtualTypes.contains(node.type) }
        static func identifier(_ value: JSONValue?) -> String? {
            if let text = value?.stringValue, !text.isEmpty { return text }
            if let number = value?.integerValue, number >= 0 { return String(number) }
            return nil
        }
        static func index(_ value: JSONValue) -> Int? {
            guard let integer = value.integerValue, integer >= 0 else { return nil }
            return Int(exactly: integer)
        }
        static func compatible(_ left: String, _ right: String) -> Bool {
            guard !left.isEmpty, !right.isEmpty else { return false }
            if left == "*" || right == "*" { return true }
            let a = Set(left.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            let b = Set(right.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            return !a.isDisjoint(with: b)
        }
    }
}

/// Expands saved, linked subgraphs only in the derived execution graph. The
/// original canvas, coordinates, widget values and export data remain untouched.
private enum SubgraphExpansion {
    typealias Error = UIWorkflowConverter.ConversionError
    static func identifier(_ value: JSONValue?) throws -> String {
        if let string = value?.stringValue, !string.isEmpty { return string }
        if let number = value?.integerValue { return String(number) }
        throw Error("子图包含无效标识。")
    }
    static func edge(_ raw: JSONValue) throws -> [JSONValue] {
        if let array = raw.arrayValue, array.count >= 5 { return Array(array.prefix(6)) }
        guard let object = raw.objectValue,
              let id = object["id"], let source = object["origin_id"], let slot = object["origin_slot"],
              let target = object["target_id"], let targetSlot = object["target_slot"] else {
            throw Error("子图连线格式不完整。")
        }
        return [id, source, slot, target, targetSlot, object["type"] ?? .string("*")]
    }
    static func expand(_ graph: JSONValue) throws -> JSONValue {
        guard var root = graph.objectValue, var nodes = root["nodes"]?.arrayValue,
              let rawLinks = root["links"]?.arrayValue else { return graph }
        var edges = try rawLinks.map(edge)
        var definitions: [String: JSONValue] = [:]
        for definition in root["definitions"]?["subgraphs"]?.arrayValue ?? [] {
            let id = try identifier(definition["id"])
            guard definitions[id] == nil else { throw Error("工作流有重复的子图定义。") }
            definitions[id] = definition
        }
        var ancestry: [String: Set<String>] = [:]
        var expanded = 0
        while let instanceIndex = nodes.firstIndex(where: {
            ($0["mode"]?.integerValue ?? 0) == 0 && definitions[$0["type"]?.stringValue ?? ""] != nil
        }) {
            expanded += 1
            guard expanded <= 512, nodes.count <= 10_000, edges.count <= 100_000 else { throw Error("子图展开规模过大。") }
            let instance = nodes[instanceIndex]
            let id = try identifier(instance["id"])
            let type = instance["type"]!.stringValue!
            let definition = definitions[type]!
            var path = ancestry[id] ?? []
            guard path.count < 32, path.insert(type).inserted else { throw Error("子图存在循环引用或嵌套过深。") }
            guard let childNodes = definition["nodes"]?.arrayValue,
                  let childRawLinks = definition["links"]?.arrayValue else { throw Error("子图缺少节点或连线定义。") }
            // Promoted widgets need an explicit proxy mapping. Never silently
            // discard instance-level overrides or guess extension widget order.
            let promoted = definition["widgets"]?.arrayValue ?? []
            let positional = instance["widgets_values"]?.arrayValue ?? []
            let named = instance["widgets_values_named"]?.objectValue ?? instance["widgets_values"]?.objectValue ?? [:]
            guard promoted.isEmpty, positional.isEmpty, named.isEmpty else {
                throw Error("子图 \(id) 含提升到外层的控件，尚不能可靠映射；请从 ComfyUI 导出 API 工作流。")
            }
            let outerInputs = instance["inputs"]?.arrayValue ?? []
            let outerOutputs = instance["outputs"]?.arrayValue ?? []
            let inputs = definition["inputs"]?.arrayValue ?? []
            let outputs = definition["outputs"]?.arrayValue ?? []
            guard inputs.count == outerInputs.count, outputs.count == outerOutputs.count else {
                throw Error("子图 \(id) 的端口数量与实例不一致。")
            }
            for (outer, inner) in zip(outerInputs + outerOutputs, inputs + outputs) {
                guard outer["type"] == inner["type"] else { throw Error("子图 \(id) 的端口类型与实例不一致。") }
            }
            let inputID = try identifier(definition["inputNode"]?["id"])
            let outputID = try identifier(definition["outputNode"]?["id"])
            let childIDs = try childNodes.map { try identifier($0["id"]) }
            guard Set(childIDs).count == childIDs.count, !childIDs.contains(inputID), !childIDs.contains(outputID) else {
                throw Error("子图 \(id) 存在重复节点或边界标识冲突。")
            }
            func scoped(_ value: String) -> String { id + ":" + value }
            func boundary(_ input: Bool, _ slot: Int) -> String { scoped((input ? "__in" : "__out") + String(slot)) }
            var incoming: [Int: JSONValue] = [:]
            for index in edges.indices {
                if try identifier(edges[index][1]) == id {
                    guard let slot = edges[index][2].integerValue, slot >= 0, slot < outputs.count else { throw Error("子图输出连线越界。") }
                    edges[index][1] = .string(boundary(false, Int(slot))); edges[index][2] = .integer(0)
                }
                if try identifier(edges[index][3]) == id {
                    guard let slot = edges[index][4].integerValue, slot >= 0, slot < inputs.count,
                          incoming[Int(slot)] == nil,
                          try identifier(outerInputs[Int(slot)]["link"]) == identifier(edges[index][0]) else {
                        throw Error("子图输入连线不完整或重复。")
                    }
                    incoming[Int(slot)] = edges[index][0]
                    edges[index][3] = .string(boundary(true, Int(slot))); edges[index][4] = .integer(0)
                }
            }
            for (slot, port) in outerInputs.enumerated() where port["link"] != nil && port["link"] != .null {
                guard incoming[slot] != nil else { throw Error("子图输入缺少对应连线。") }
            }
            var outgoing: [Int: JSONValue] = [:]
            var childEdges = try childRawLinks.map(edge)
            for index in childEdges.indices {
                childEdges[index][0] = .string(scoped("link:" + (try identifier(childEdges[index][0]))))
                let source = try identifier(childEdges[index][1])
                let target = try identifier(childEdges[index][3])
                if source == inputID {
                    guard let slot = childEdges[index][2].integerValue, slot >= 0, slot < inputs.count else { throw Error("子图内部输入越界。") }
                    childEdges[index][1] = .string(boundary(true, Int(slot))); childEdges[index][2] = .integer(0)
                } else {
                    guard childIDs.contains(source) else { throw Error("子图内部连线来源不存在。") }
                    childEdges[index][1] = .string(scoped(source))
                }
                if target == outputID {
                    guard let slot = childEdges[index][4].integerValue, slot >= 0, slot < outputs.count, outgoing[Int(slot)] == nil else { throw Error("子图内部输出越界或有多个来源。") }
                    outgoing[Int(slot)] = childEdges[index][0]
                    childEdges[index][3] = .string(boundary(false, Int(slot))); childEdges[index][4] = .integer(0)
                } else {
                    guard childIDs.contains(target) else { throw Error("子图内部连线目标不存在。") }
                    childEdges[index][3] = .string(scoped(target))
                }
            }
            var expandedNodes: [JSONValue] = []
            for (child, childID) in zip(childNodes, childIDs) {
                var raw = child.objectValue!
                raw["id"] = .string(scoped(childID))
                raw["inputs"] = .array(try (child["inputs"]?.arrayValue ?? []).map { input in
                    guard var port = input.objectValue else { throw Error("子图输入端口无效。") }
                    if let link = port["link"], link != .null { port["link"] = .string(scoped("link:" + (try identifier(link)))) }
                    return .object(port)
                })
                ancestry[scoped(childID)] = path
                expandedNodes.append(.object(raw))
            }
            for (isInput, ports, connected) in [(true, inputs, incoming), (false, outputs, outgoing)] {
                for (slot, port) in ports.enumerated() {
                    let socketType = port["type"] ?? .string("*")
                    expandedNodes.append(.object([
                        "id": .string(boundary(isInput, slot)), "type": .string("Reroute"),
                        "inputs": .array([.object(["name": .string("value"), "type": socketType, "link": connected[slot] ?? .null])]),
                        "outputs": .array([.object(["name": .string("value"), "type": socketType])])
                    ]))
                }
            }
            nodes.remove(at: instanceIndex); nodes.append(contentsOf: expandedNodes); edges.append(contentsOf: childEdges)
        }
        root["nodes"] = .array(nodes); root["links"] = .array(edges.map(JSONValue.array))
        return .object(root)
    }
}
