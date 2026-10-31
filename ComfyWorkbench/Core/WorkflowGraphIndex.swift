import Foundation

/// Saved subgraph definitions own their node modes. References share that definition;
/// instance-level widget overrides are handled separately when deriving the API graph.
struct WorkflowGraphIndex {
    struct Entry { let scope: String; let id: String; let raw: JSONValue }
    let root: JSONValue
    var graphs: [String: JSONValue] = [:]
    var entries: [String: Entry] = [:]
    var order: [String] = []

    init(_ root: JSONValue) throws {
        self.root = root
        graphs[""] = root; order = [""]
        for graph in root["definitions"]?["subgraphs"]?.arrayValue ?? [] {
            guard let id = graph["id"]?.displayValue, !id.isEmpty, graphs[id] == nil,
                  graph["nodes"]?.arrayValue != nil else { throw WorkflowError.invalid("子图定义缺失或编号重复。") }
            graphs[id] = graph; order.append(id)
        }
        guard order.count <= 513 else { throw WorkflowError.invalid("子图数量过多。") }
        for scope in order {
            for node in graphs[scope]?["nodes"]?.arrayValue ?? [] {
                guard let id = node["id"]?.displayValue, !id.isEmpty, node.objectValue != nil else { throw WorkflowError.invalid("节点编号缺失。") }
                let key = Self.key(scope, id)
                guard entries[key] == nil else { throw WorkflowError.invalid("同一图中有重复节点编号。") }
                entries[key] = Entry(scope: scope, id: id, raw: node)
            }
        }
        guard entries.count <= 10_000 else { throw WorkflowError.invalid("子图节点总数超过 10000。") }
    }
    static func token(_ parts: [String]) -> String {
        let data = try! JSONEncoder().encode(parts)
        return data.base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
    }
    static func key(_ scope: String, _ id: String) -> String { scope.isEmpty ? id : "@graph:" + token([scope, id]) }
    func childScope(_ key: String) -> String? {
        guard let type = entries[key]?.raw["type"]?.stringValue, !type.isEmpty, graphs[type] != nil else { return nil }
        return type
    }
    func nodeKeys(_ scope: String) -> [String] {
        (graphs[scope]?["nodes"]?.arrayValue ?? []).compactMap { $0["id"].map { Self.key(scope, $0.displayValue) } }
    }
    func descendants(of keys: [String]) throws -> [String] {
        var result: [String] = [], seen = Set<String>()
        func visit(_ key: String, path: Set<String>) throws {
            guard entries[key] != nil else { throw WorkflowError.invalid("开关引用了不存在的节点。") }
            if seen.contains(key) { return }
            if entries[key]?.raw["subgraph"] != nil && childScope(key) == nil { throw WorkflowError.invalid("这种内嵌子图格式尚不支持模式传播，请使用 ComfyUI 原生子图格式。") }
            if let scope = childScope(key) {
                guard path.count < 32, !path.contains(scope) else { throw WorkflowError.invalid("子图存在循环引用或嵌套过深。") }
                var next = path; next.insert(scope)
                for child in nodeKeys(scope) { try visit(child, path: next) }
            }
            if seen.insert(key).inserted { result.append(key) }
        }
        for key in keys { try visit(key, path: []) }
        return result
    }
    func replacingNodes(_ replacements: [String: JSONValue]) throws -> JSONValue {
        if replacements.isEmpty { return root }
        guard Set(replacements.keys).isSubset(of: Set(entries.keys)), var result = root.objectValue else { throw WorkflowError.invalid("节点记录已失效。") }
        func replace(_ graph: JSONValue, scope: String) throws -> JSONValue {
            guard var object = graph.objectValue else { throw WorkflowError.invalid("图结构无效。") }
            object["nodes"] = .array((graph["nodes"]?.arrayValue ?? []).map { node in
                guard let id = node["id"]?.displayValue else { return node }
                return replacements[Self.key(scope, id)] ?? node
            })
            return .object(object)
        }
        result["nodes"] = try replace(root, scope: "")["nodes"]
        if var definitions = root["definitions"]?.objectValue {
            definitions["subgraphs"] = .array(try (root["definitions"]?["subgraphs"]?.arrayValue ?? []).map { try replace($0, scope: $0["id"]!.displayValue) })
            result["definitions"] = .object(definitions)
        }
        return .object(result)
    }
    func applyingModes(_ modes: [String: JSONValue]) throws -> JSONValue {
        var changed: [String: JSONValue] = [:]
        for (key, mode) in modes {
            guard var node = entries[key]?.raw.objectValue,
                  mode == .null || [Int64(0), 2, 4].contains(mode.integerValue ?? -1) else { throw WorkflowError.invalid("节点或运行模式已变化，无法恢复。") }
            if mode == .null { node.removeValue(forKey: "mode") } else { node["mode"] = mode }
            changed[key] = .object(node)
        }
        return try replacingNodes(changed)
    }
    /// Follow control wires only through known passive collectors/reroutes.
    func connected(_ key: String, upstream: Bool = true) throws -> [String] {
        guard let entry = entries[key] else { return [] }
        func slotNumber(_ link: JSONValue) -> Int64 {
            let position = upstream ? 4 : 2
            if let array = link.arrayValue, array.count > position { return array[position].integerValue ?? 0 }
            return link[upstream ? "target_slot" : "origin_slot"]?.integerValue ?? 0
        }
        let rawLinks: [JSONValue] = graphs[entry.scope]?["links"]?.arrayValue ?? []
        let links = rawLinks.sorted { slotNumber($0) < slotNumber($1) }
        var result: [String] = [], seen = Set<String>(), walked = Set<String>()
        func walk(_ current: String, path: Set<String>) throws {
            guard path.count < 512, !path.contains(current) else { throw WorkflowError.invalid("开关连接存在循环。") }
            guard walked.insert(current).inserted else { return }
            var path = path; path.insert(current)
            guard let currentID = entries[current]?.id else { return }
            for link in links {
                let a = link.arrayValue
                guard a == nil || a!.count >= 6 else { throw WorkflowError.invalid("开关连线格式不完整。") }
                let source = a?[1].displayValue ?? link["origin_id"]?.displayValue
                let target = a?[3].displayValue ?? link["target_id"]?.displayValue
                guard (upstream ? target : source) == currentID, let id = (upstream ? source : target) else { continue }
                guard let targetID = target, let linkID = a?.first?.displayValue ?? link["id"]?.displayValue,
                      let slot = (a?[4] ?? link["target_slot"])?.integerValue, slot >= 0,
                      let ports = entries[Self.key(entry.scope, targetID)]?.raw["inputs"]?.arrayValue,
                      slot < ports.count, ports[Int(slot)]["link"]?.displayValue == linkID else {
                    throw WorkflowError.invalid("开关连线与输入端口记录不一致，请重新保存画布。")
                }
                let next = Self.key(entry.scope, id)
                guard let node = entries[next] else { throw WorkflowError.invalid("开关连线引用的节点不存在。") }
                if WorkflowControlEngine.passThroughTypes.contains(node.raw["type"]?.stringValue ?? "") { try walk(next, path: path) }
                else if seen.insert(next).inserted { result.append(next) }
            }
        }
        try walk(key, path: [])
        return result
    }
}
