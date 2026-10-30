import Foundation

public struct WorkflowFieldSchema: Equatable {
    public enum Kind: String { case text, integer, decimal, boolean, choice }
    public enum UploadKind: String, CaseIterable { case image, video, audio, file }
    public let kind: Kind
    public let minimumValue: JSONValue?
    public let maximumValue: JSONValue?
    public let step: Double?
    public let options: [JSONValue]
    public let multiline: Bool
    public let isUpload: Bool
    public let uploadKind: UploadKind?
    public let connectionOnly: Bool
    public let acceptsLiteralArray: Bool

    public var minimum: Double? { minimumValue?.doubleValue }
    public var maximum: Double? { maximumValue?.doubleValue }
    public var choices: [JSONValue] { options }

    public init(kind: Kind, minimumValue: JSONValue? = nil, maximumValue: JSONValue? = nil,
                step: Double? = nil, options: [JSONValue] = [], multiline: Bool = false,
                isUpload: Bool = false, connectionOnly: Bool = false, acceptsLiteralArray: Bool = false, uploadKind: UploadKind? = nil) {
        self.kind = kind; self.minimumValue = minimumValue; self.maximumValue = maximumValue
        self.step = step; self.options = options; self.multiline = multiline
        self.isUpload = isUpload; self.connectionOnly = connectionOnly; self.acceptsLiteralArray = acceptsLiteralArray
        self.uploadKind = isUpload ? (uploadKind ?? .file) : nil
    }

    public static func inferred(name: String, value: JSONValue) -> WorkflowFieldSchema {
        let kind: Kind
        switch value {
        case .bool: kind = .boolean
        case .integer, .unsignedInteger: kind = .integer
        case .decimal: kind = .decimal
        default: kind = .text
        }
        let lower = name.lowercased()
        return WorkflowFieldSchema(kind: kind,
            multiline: kind == .text && (lower.contains("prompt") || lower == "text" || value.displayValue.contains("\n") || value.displayValue.count > 160),
            isUpload: kind == .text && ["image", "video", "audio"].contains(lower), uploadKind: UploadKind(rawValue: lower))
    }
}

/// Widget constraints returned by the connected server's /object_info endpoint.
public struct ObjectInfo: Equatable {
    public let definitions: [String: JSONValue]

    public init(data: Data) throws {
        guard let object = try JSONValue(data: data).objectValue else {
            throw WorkflowError.invalid("节点信息应是 JSON 对象。")
        }
        definitions = object
    }

    public init(definitions: [String: JSONValue]) { self.definitions = definitions }

    public func schema(for classType: String, input name: String) -> WorkflowFieldSchema? {
        guard let input = definitions[classType]?["input"]?.objectValue else { return nil }
        let entry = input["required"]?[name] ?? input["optional"]?[name]
        guard let specification = entry?.arrayValue, let type = specification.first else { return nil }
        let config = specification.count > 1 ? specification[1].objectValue ?? [:] : [:]
        let typeName = type.stringValue?.uppercased() ?? "COMBO"
        let rawOptions = type.arrayValue ?? config["options"]?.arrayValue ?? []
        let options = typeName == "COMFY_DYNAMICCOMBO_V3" ? rawOptions.compactMap { $0["key"] } : rawOptions
        let kind: WorkflowFieldSchema.Kind
        switch typeName {
        case "INT": kind = .integer
        case "FLOAT", "NUMBER": kind = .decimal
        case "BOOLEAN", "BOOL": kind = .boolean
        case "COMBO", "COMFY_DYNAMICCOMBO_V3": kind = .choice
        default: kind = options.isEmpty ? .text : .choice
        }
        let widgetTypes = ["STRING", "INT", "FLOAT", "NUMBER", "BOOLEAN", "BOOL", "COMBO", "COMFY_DYNAMICCOMBO_V3"]
        let arrayChoices = options.contains { $0.arrayValue != nil }
        // VHS upload loaders omit the usual upload flag. Path loaders intentionally stay text fields.
        let knownUpload: WorkflowFieldSchema.UploadKind? =
            (["VHS_LoadVideo", "VHS_LoadVideoFFmpeg"].contains(classType) && name == "video") ? .video :
            (classType == "VHS_LoadAudioUpload" && name == "audio" ? .audio : nil)
        let uploadKind: WorkflowFieldSchema.UploadKind? = config["image_upload"]?.boolValue == true ? .image :
            (config["video_upload"]?.boolValue == true ? .video : (config["audio_upload"]?.boolValue == true ? .audio : knownUpload))
        return WorkflowFieldSchema(kind: kind, minimumValue: config["min"], maximumValue: config["max"],
            step: config["step"]?.doubleValue, options: options,
            multiline: config["multiline"]?.boolValue ?? false,
            isUpload: uploadKind != nil,
            connectionOnly: (config["forceInput"]?.boolValue ?? false) || !widgetTypes.contains(typeName),
            acceptsLiteralArray: arrayChoices,
            uploadKind: uploadKind)
    }
}

public struct WorkflowReferenceInput: Identifiable {
    public var id: String { field.id }
    public let field: WorkflowField
    public let destinations: [String]
    public let role: String?
    public let enabled: Bool
}

public struct WorkflowReferenceGroup: Identifiable {
    public enum Layout: Equatable { case hero, grid, rows }
    public var id: String { kind.rawValue }
    public let kind: WorkflowFieldSchema.UploadKind
    public let inputs: [WorkflowReferenceInput]
    public var layout: Layout { kind == .image || kind == .video ? (inputs.count == 1 ? .hero : .grid) : .rows }
    /// Preserve input order. Wide media use a full row; portrait/square media share a row.
    public func mediaRows(aspectRatios: [String: Double]) -> [[WorkflowReferenceInput]] {
        var rows: [[WorkflowReferenceInput]] = [], pair: [WorkflowReferenceInput] = []
        for input in inputs {
            let ratio = aspectRatios[input.id] ?? 1
            if ratio.isFinite && ratio >= 1.25 {
                if !pair.isEmpty { rows.append(pair); pair = [] }
                rows.append([input])
            } else {
                pair.append(input)
                if pair.count == 2 { rows.append(pair); pair = [] }
            }
        }
        if !pair.isEmpty { rows.append(pair) }
        return rows
    }
}

extension WorkflowCanvas {
    /// A view of existing upload inputs. Never creates nodes, sockets, or links.
    public var referenceGroups: [WorkflowReferenceGroup] {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let outgoing = Dictionary(grouping: links, by: \.source)
        let inputs = nodes.flatMap(\.fields).filter { $0.schema.isUpload }.map { field -> WorkflowReferenceInput in
            var destinations: [String] = [], roles = Set<String>(), visited = Set<String>(), pending = [field.nodeID]
            while let source = pending.popLast(), visited.count < 3000 {
                guard visited.insert(source).inserted else { continue }
                for link in outgoing[source] ?? [] {
                    guard let target = byID[link.target], !target.bypassed, target.inputs.indices.contains(link.targetSlot) else { continue }
                    if target.type == "Reroute" { pending.append(target.id); continue }
                    let input = target.inputs[link.targetSlot]
                    destinations.append("\(target.type) #\(target.id) / \(input)")
                    switch input.lowercased() {
                    case "first_frame", "start_image": roles.insert("首帧")
                    case "last_frame", "end_image": roles.insert("尾帧")
                    default:
                        if target.type == "MiniMaxH3ReferenceToVideo" {
                            for (prefix, label) in [("ref_images.ref_image_", "参考图片"), ("ref_videos.ref_video_", "参考视频"), ("ref_audios.ref_audio_", "参考音频"), ("ref_video_audios.ref_video_audio_", "视频原声")] {
                                if input.hasPrefix(prefix), let index = Int(input.dropFirst(prefix.count)), index >= 0, index < 100 {
                                    roles.insert("\(label) \(index + 1)")
                                }
                            }
                        }
                    }
                }
            }
            return WorkflowReferenceInput(field: field, destinations: Array(Set(destinations)).sorted(), role: roles.count == 1 && destinations.count == 1 ? roles.first : nil, enabled: byID[field.nodeID]?.bypassed != true)
        }
        return WorkflowFieldSchema.UploadKind.allCases.compactMap { kind in
            let matching = inputs.filter { ($0.field.schema.uploadKind ?? .file) == kind }
            return matching.isEmpty ? nil : WorkflowReferenceGroup(kind: kind, inputs: matching)
        }
    }
}
