import Foundation

/// rgthree controls are frontend operations on saved node modes, not server widgets.
enum WorkflowControlEngine {
    static let groupTypes: Set<String> = ["Fast Groups Bypasser (rgthree)", "Fast Groups Muter (rgthree)"]
    static let connectedTypes: Set<String> = ["Fast Bypasser (rgthree)", "Fast Muter (rgthree)"]
    static let repeater = "Mute / Bypass Repeater (rgthree)"
    static let relay = "Mute / Bypass Relay (rgthree)"
    static let passThroughTypes: Set<String> = ["Reroute", "Reroute (rgthree)", "Node Collector (rgthree)", "Node Combiner (rgthree)"]
    static let frontendTypes = groupTypes.union(connectedTypes).union([repeater, relay, "Node Collector (rgthree)", "Node Combiner (rgthree)"])

    static func discover(_ index: WorkflowGraphIndex) -> (controls: [WorkflowGroupSwitch], issues: [String: String]) {
        var controls: [WorkflowGroupSwitch] = [], issues: [String: String] = [:]
        for owner in index.nodeKeys("") {
            do {
                for key in try index.descendants(of: [owner]) {
                    guard let entry = index.entries[key], WorkflowGroupSwitch.controllerTypes.contains(entry.raw["type"]?.stringValue ?? "") else { continue }
                    controls += try WorkflowGroupSwitch.controls(index: index, key: key, owner: owner)
                }
            } catch { issues[owner] = error.localizedDescription }
        }
        return (controls, issues)
    }

    /// Evaluate mode propagation transactionally. Conflicting/cyclic relays never partly edit a draft.
    static func change(index: WorkflowGraphIndex, requested: [String: Int64]) throws -> (before: JSONValue, after: JSONValue) {
        var modes = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.key, $0.value.raw["mode"]?.integerValue ?? 0) })
        var touched = Set<String>(), pending = Set<String>()
        func assign(_ keys: [String], _ mode: Int64) throws {
            for key in try index.descendants(of: keys) {
                guard [Int64(0), 2, 4].contains(modes[key] ?? -1) else { throw WorkflowError.invalid("节点运行模式不受支持，无法保证撤销恢复。") }
                touched.insert(key)
                if modes[key] != mode { modes[key] = mode; pending.insert(key) }
            }
        }
        for key in requested.keys.sorted() {
            guard let current = modes[key], [Int64(0), 2, 4].contains(current), [Int64(0), 2, 4].contains(requested[key]!) else { throw WorkflowError.invalid("节点或模式不存在。") }
            touched.insert(key)
            if current != requested[key]! { modes[key] = requested[key]!; pending.insert(key) }
        }
        let relays = index.entries.keys.filter { index.entries[$0]?.raw["type"]?.stringValue == relay }.sorted()
        var signatures = Set<String>()
        for _ in 0..<128 {
            let signature = modes.keys.sorted().map { $0 + "=" + String(modes[$0]!) }.joined(separator: "|") + pending.sorted().joined(separator: ",")
            guard signatures.insert(signature).inserted else { throw WorkflowError.invalid("开关传播存在循环或相互冲突，本次更改未应用。") }
            let changed = pending.sorted(); pending.removeAll()
            for key in changed where index.entries[key]?.raw["type"]?.stringValue == repeater {
                let inputs = try index.connected(key)
                let targets = inputs.filter { index.entries[$0]?.raw["type"]?.stringValue != relay }
                if !targets.isEmpty { try assign(targets, modes[key]!) }
                else if inputs.isEmpty, let entry = index.entries[key] {
                    for group in index.graphs[entry.scope]?["groups"]?.arrayValue ?? [] {
                        let members = try WorkflowGroupSwitch.members(index: index, scope: entry.scope, group: group)
                        if members.contains(key) { try assign(members.filter { $0 != key }, modes[key]!) }
                    }
                }
            }
            for key in relays {
                let inputs = try index.connected(key)
                let values = inputs.isEmpty ? [modes[key] ?? 0] : inputs.compactMap { modes[$0] }
                let property: String
                if values.contains(0) { property = "on_any_active_inputs" }
                else if values.allSatisfy({ $0 == 2 }) { property = "on_muted_inputs" }
                else if values.allSatisfy({ $0 == 4 }) { property = "on_bypassed_inputs" }
                else { continue }
                let defaults = ["on_any_active_inputs": "ACTIVE", "on_muted_inputs": "MUTE", "on_bypassed_inputs": "BYPASS"]
                let action = index.entries[key]?.raw["properties"]?[property]?.stringValue ?? defaults[property]!
                if action == "NOTHING" { continue }
                guard let mode = ["ACTIVE": Int64(0), "MUTE": 2, "BYPASS": 4][action] else { throw WorkflowError.invalid("Relay 的模式映射不受支持。") }
                let targets = try index.connected(key, upstream: false).filter { index.entries[$0]?.raw["type"]?.stringValue == repeater }
                for target in targets {
                    let downstream = try index.connected(target, upstream: false)
                    guard !downstream.contains(where: { connectedTypes.contains(index.entries[$0]?.raw["type"]?.stringValue ?? "") }) else {
                        throw WorkflowError.invalid("Repeater 同时连接 Relay 和快捷开关，控制来源冲突。请在原画布修正连线。")
                    }
                }
                try assign(targets, mode)
            }
            if pending.isEmpty {
                let changed = touched.filter { (index.entries[$0]?.raw["mode"]?.integerValue ?? 0) != modes[$0] }
                return (.object(Dictionary(uniqueKeysWithValues: changed.map { ($0, index.entries[$0]!.raw["mode"] ?? .null) })),
                        .object(Dictionary(uniqueKeysWithValues: changed.map { ($0, .integer(modes[$0]!)) })))
            }
        }
        throw WorkflowError.invalid("开关传播超过安全上限，本次更改未应用。")
    }
}

public struct WorkflowGroupSwitch: Identifiable, Equatable {
    public static let controllerTypes = WorkflowControlEngine.groupTypes.union(WorkflowControlEngine.connectedTypes)
    public let ownerID: String
    public let controllerID: String
    public let fieldName: String
    public let title: String
    public let scopeCaption: String?
    public let color: String?
    public let nodeIDs: [String]
    public let activeCount: Int
    public let offMode: Int64
    public let restriction: String
    public var id: String { ownerID + "." + fieldName }
    public var enabled: Bool { activeCount > 0 }
    public var partiallyEnabled: Bool { activeCount > 0 && activeCount < nodeIDs.count }
    public var status: String {
        if nodeIDs.isEmpty { return "没有可切换的节点" }
        if partiallyEnabled { return "部分启用（\(activeCount)/\(nodeIDs.count)）" }
        return enabled ? "已启用 · \(nodeIDs.count) 个节点" : (offMode == 4 ? "已旁路" : "已停用") + " · \(nodeIDs.count) 个节点"
    }
    static func controls(index: WorkflowGraphIndex, key: String, owner: String) throws -> [Self] {
        guard let entry = index.entries[key] else { return [] }
        let controller = entry.raw, properties = controller["properties"]
        let type = controller["type"]?.stringValue ?? ""
        let restriction = properties?["toggleRestriction"]?.stringValue ?? "default"
        guard ["default", "max one", "always one"].contains(restriction) else { throw WorkflowError.invalid("此开关的互斥规则尚不支持。") }
        func make(_ name: String, _ title: String, _ members: [String], _ scope: String, _ color: String? = nil) -> Self {
            let field = key == owner ? name : "__nested_" + WorkflowGraphIndex.token([key, name])
            let caption = entry.scope.isEmpty && scope.isEmpty ? nil : "子图 · \(scope.isEmpty ? "主画布" : String(scope.prefix(8))) · \(type) #\(entry.id) · 共享定义"
            return Self(ownerID: owner, controllerID: key, fieldName: field, title: title, scopeCaption: caption, color: color,
                        nodeIDs: members, activeCount: members.filter { (index.entries[$0]?.raw["mode"]?.integerValue ?? 0) == 0 }.count,
                        offMode: type.contains("Muter") ? 2 : 4, restriction: restriction)
        }
        if WorkflowControlEngine.connectedTypes.contains(type) {
            return try index.connected(key).map { target in
                let node = index.entries[target]!
                return make("__target_" + WorkflowGraphIndex.token([target]), (node.raw["type"]?.stringValue ?? "节点") + " #" + node.id, [target], node.scope)
            }
        }
        let scopes = properties?["showAllGraphs"]?.boolValue == false ? [entry.scope] : index.order
        guard scopes.contains(where: { !(index.graphs[$0]?["groups"]?.arrayValue ?? []).isEmpty }) else { throw WorkflowError.invalid("缺少分组信息。请重新导入画布 JSON；API JSON 不含前端分组。") }
        let pattern = (properties?["matchTitle"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard pattern.count <= 256 else { throw WorkflowError.invalid("分组匹配规则过长。") }
        let regex: NSRegularExpression?
        do { regex = pattern.isEmpty ? nil : try NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
        catch { throw WorkflowError.invalid("分组名称匹配规则无效。") }
        let colors = try (properties?["matchColors"]?.stringValue ?? "").split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { value -> String in
            guard let color = normalizedColor(String(value)) else { throw WorkflowError.invalid("无法识别分组颜色规则 \(value)。") }; return color
        }
        var found: [(x: Double, y: Double, control: Self)] = []
        for scope in scopes {
            let groups = index.graphs[scope]?["groups"]?.arrayValue ?? []
            guard groups.count <= 1000 else { throw WorkflowError.invalid("分组数量过多。") }
            var ids = Set<String>()
            for (position, group) in groups.enumerated() {
                let title = group["title"]?.stringValue ?? "分组"
                let groupID = group["id"].map { "id_" + $0.displayValue } ?? "index_\(position)"
                guard ids.insert(groupID).inserted else { throw WorkflowError.invalid("同一图中分组编号重复。") }
                if let regex = regex, regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)) == nil { continue }
                let color = normalizedColor(group["color"]?.stringValue ?? "")
                if !colors.isEmpty && !colors.contains(color ?? "") { continue }
                let members = try members(index: index, scope: scope, group: group)
                let name = scope == entry.scope ? "__group_" + groupID : "__graph_group_" + WorkflowGraphIndex.token([scope, groupID])
                found.append((group["bounding"]!.arrayValue![0].doubleValue!, group["bounding"]!.arrayValue![1].doubleValue!, make(name, title, members, scope, color)))
            }
        }
        let sort = properties?["sort"]?.stringValue ?? "position"
        let text = (properties?["customSortAlphabet"]?.stringValue ?? "").replacingOccurrences(of: "\n", with: "").lowercased()
        let alphabet = text.contains(",") ? text.components(separatedBy: ",") : text.trimmingCharacters(in: .whitespacesAndNewlines).map(String.init)
        return found.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if sort == "position" {
                if floor(a.y / 30) != floor(b.y / 30) { return floor(a.y / 30) < floor(b.y / 30) }
                if floor(a.x / 30) != floor(b.x / 30) { return floor(a.x / 30) < floor(b.x / 30) }
            } else {
                if sort == "custom alphabet", !alphabet.isEmpty {
                    let ai = alphabet.firstIndex { a.control.title.lowercased().hasPrefix($0) } ?? Int.max
                    let bi = alphabet.firstIndex { b.control.title.lowercased().hasPrefix($0) } ?? Int.max
                    if ai != bi { return ai < bi }
                }
                let order = a.control.title.localizedStandardCompare(b.control.title)
                if order != .orderedSame { return order == .orderedAscending }
            }
            return left.offset < right.offset
        }.map { $0.element.control }
    }
    static func members(index: WorkflowGraphIndex, scope: String, group: JSONValue) throws -> [String] {
        guard let bounds = group["bounding"]?.arrayValue, bounds.count == 4,
              let x = bounds[0].doubleValue, let y = bounds[1].doubleValue, let w = bounds[2].doubleValue, let h = bounds[3].doubleValue,
              [x, y, w, h].allSatisfy({ $0.isFinite && abs($0) <= 100_000_000 }), w > 0, h > 0 else { throw WorkflowError.invalid("分组范围缺失或无效。") }
        return try index.nodeKeys(scope).filter { key in
            let node = index.entries[key]!.raw
            guard let position = pair(node["pos"]), let size = pair(node["size"]), size.0 > 0, size.1 > 0 else { throw WorkflowError.invalid("部分节点缺少位置或尺寸，请在 ComfyUI 重新保存画布。") }
            var cx = position.0 + size.0 / 2
            var cy = position.1 + size.1 / 2 - (node["type"]?.stringValue == "Reroute" ? 0 : 15)
            if node["flags"]?["collapsed"]?.boolValue == true {
                cy = position.1 - 15
                let low = position.0 + min(size.0, 60) / 2
                if cy >= y && cy < y + h && cx >= x && low < x + w {
                    guard low >= x && cx < x + w else { throw WorkflowError.invalid("分组边缘的折叠节点归属不明确，请展开并保存。") }
                }
                cx = low
            }
            return cx >= x && cx < x + w && cy >= y && cy < y + h
        }
    }
    private static func pair(_ value: JSONValue?) -> (Double, Double)? {
        let a = value?.arrayValue
        let x = a.flatMap { $0.count >= 2 ? $0[0].doubleValue : nil } ?? value?["0"]?.doubleValue
        let y = a.flatMap { $0.count >= 2 ? $0[1].doubleValue : nil } ?? value?["1"]?.doubleValue
        guard let x = x, let y = y, x.isFinite, y.isFinite else { return nil }; return (x, y)
    }
    static func normalizedColor(_ color: String) -> String? {
        var hex = color.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let named = ["red": "#a88", "brown": "#b06634", "green": "#8a8", "blue": "#88a", "pale_blue": "#3f789e", "cyan": "#8aa", "purple": "#a1309b", "yellow": "#b58b2a", "black": "#444"]
        hex = named[hex] ?? hex
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { String(repeating: String($0), count: 2) }.joined() }
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + hex
    }
}
