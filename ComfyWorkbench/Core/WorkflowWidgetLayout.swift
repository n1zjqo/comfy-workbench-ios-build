import Foundation

/// Shared positional codec. A layout is accepted only when its serialized count is exact.
/// Extension-specific buttons require a known adapter; dictionary iteration is never widget order.
enum WorkflowWidgetLayout {
    static func subgraphNames(_ raw: JSONValue, count: Int) -> [String]? {
        let proxies = raw["properties"]?["proxyWidgets"]?.arrayValue ?? []
        let interface = Set(proxies.compactMap { proxy -> String? in
            guard let pair = proxy.arrayValue, pair.count == 2, pair[0].displayValue == "-1" else { return nil }; return pair[1].stringValue
        })
        let names = (raw["inputs"]?.arrayValue ?? []).compactMap { port -> String? in
            guard let name = port["widget"]?["name"]?.stringValue ?? port["name"]?.stringValue,
                  port["widget"] != nil || interface.contains(name) else { return nil }; return name
        }
        if !names.isEmpty, names.count == count, Set(names).count == names.count { return names }
        guard !proxies.isEmpty, proxies.count == count else { return nil }
        let keys = proxies.compactMap { proxy -> String? in
            guard let pair = proxy.arrayValue, pair.count == 2, pair[0].displayValue != "-1", let name = pair[1].stringValue else { return nil }
            return "__proxy_" + WorkflowGraphIndex.token([pair[0].displayValue, name])
        }
        return keys.count == count && Set(keys).count == count ? keys : nil
    }
    static let switchLayouts: [String: [String]] = [
        "ImpactSwitch": ["select", "sel_mode"], "ImpactInversedSwitch": ["select", "sel_mode"],
        "LatentSwitch": ["select"], "SEGSSwitch": ["select", "sel_mode"], "ImageMaskSwitch": ["select"],
        "easy imageSwitch": ["boolean"], "easy textSwitch": ["input"],
        "easy ab": ["A or B"], "easy anythingInversedSwitch": ["index"],
        "easy anythingIndexSwitch": ["index"], "easy imageIndexSwitch": ["index"],
        "easy textIndexSwitch": ["index"], "easy conditioningIndexSwitch": ["index"],
        "easy ifElse": ["boolean"], "easy blocker": ["continue"], "LazySwitchKJ": ["switch"]
    ]
    static func names(raw: JSONValue, definition: JSONValue?, count: Int) -> [String]? {
        let type = raw["type"]?.stringValue ?? ""
        if ["LatentSwitch", "SEGSSwitch"].contains(type) {
            if count == 1 { return ["select"] }
            if count == 2 { return ["select", "sel_mode"] }
        }
        if let known = switchLayouts[type] {
            if known.count == count { return known }
            // Earlier Impact versions serialize only select; require that server schema agrees.
            if type.hasPrefix("Impact"), count == 1,
               definition?["input"]?["required"]?["sel_mode"] == nil { return ["select"] }
        }
        guard let definition = definition, let sections = definition["input"]?.objectValue,
              let order = definition["input_order"]?.objectValue else { return nil }
        var names: [String] = []
        for section in ["required", "optional"] {
            let fields = sections[section]?.objectValue ?? [:]
            guard let list = order[section]?.arrayValue ?? (fields.isEmpty ? [] : nil) else { return nil }
            let keys = list.compactMap(\.stringValue)
            guard keys.count == list.count, Set(keys).count == keys.count, Set(keys) == Set(fields.keys) else { return nil }
            for key in keys {
                guard let schema = fields[key]?.arrayValue, !schema.isEmpty else { return nil }
                let options = schema.count > 1 ? schema[1] : .null
                if options["forceInput"]?.boolValue == true { continue }
                let kind = schema[0].stringValue ?? ""
                guard schema[0].arrayValue != nil || ["STRING", "INT", "FLOAT", "BOOLEAN", "BOOL", "COMBO"].contains(kind) else { continue }
                if kind == "COMBO", options["multiselect"]?.boolValue == true { return nil }
                names.append(key)
                if options["control_after_generate"]?.boolValue == true { names.append("control_after_generate") }
            }
        }
        guard names.count == count, Set(names).count == names.count else { return nil }
        return names
    }
}
