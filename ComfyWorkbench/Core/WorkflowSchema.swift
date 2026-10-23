import Foundation

public struct WorkflowFieldSchema: Equatable {
    public enum Kind: String { case text, integer, decimal, boolean, choice }
    public let kind: Kind
    public let minimumValue: JSONValue?
    public let maximumValue: JSONValue?
    public let step: Double?
    public let options: [JSONValue]
    public let multiline: Bool
    public let isUpload: Bool
    public let connectionOnly: Bool
    public let acceptsLiteralArray: Bool

    public var minimum: Double? { minimumValue?.doubleValue }
    public var maximum: Double? { maximumValue?.doubleValue }
    public var choices: [JSONValue] { options }

    public init(kind: Kind, minimumValue: JSONValue? = nil, maximumValue: JSONValue? = nil,
                step: Double? = nil, options: [JSONValue] = [], multiline: Bool = false,
                isUpload: Bool = false, connectionOnly: Bool = false, acceptsLiteralArray: Bool = false) {
        self.kind = kind; self.minimumValue = minimumValue; self.maximumValue = maximumValue
        self.step = step; self.options = options; self.multiline = multiline
        self.isUpload = isUpload; self.connectionOnly = connectionOnly; self.acceptsLiteralArray = acceptsLiteralArray
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
            isUpload: kind == .text && ["image", "video", "audio"].contains(lower))
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
        return WorkflowFieldSchema(kind: kind, minimumValue: config["min"], maximumValue: config["max"],
            step: config["step"]?.doubleValue, options: options,
            multiline: config["multiline"]?.boolValue ?? false,
            isUpload: (config["image_upload"]?.boolValue ?? false) || (config["video_upload"]?.boolValue ?? false) || (config["audio_upload"]?.boolValue ?? false),
            connectionOnly: (config["forceInput"]?.boolValue ?? false) || !widgetTypes.contains(typeName),
            acceptsLiteralArray: arrayChoices)
    }
}
