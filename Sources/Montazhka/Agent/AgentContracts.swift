import Foundation

enum AgentJSONValue: Codable, Equatable, Sendable,
    ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral
{
    case string(String)
    case bool(Bool)
    case number(Double)
    case object([String: AgentJSONValue])
    case array([AgentJSONValue])
    case null

    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: AgentJSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([AgentJSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct AgentErrorPayload: Codable, Equatable, Sendable {
    let code: String
    let message: String
    var recovery: String?
}

struct AgentResponse: Codable, Equatable, Sendable {
    let apiVersion: String
    let ok: Bool
    let command: String
    let data: [String: AgentJSONValue]?
    let error: AgentErrorPayload?

    static func success(command: String, data: [String: AgentJSONValue]) -> AgentResponse {
        AgentResponse(apiVersion: "1", ok: true, command: command, data: data, error: nil)
    }

    static func failure(
        command: String, code: String, message: String, recovery: String? = nil
    ) -> AgentResponse {
        AgentResponse(
            apiVersion: "1", ok: false, command: command, data: nil,
            error: AgentErrorPayload(code: code, message: message, recovery: recovery))
    }
}

struct AgentToolDefinition: Codable, Equatable, Sendable {
    let name: String
    let description: String
    let inputSchema: [String: AgentJSONValue]
    let isReadOnly: Bool
    let isDestructive: Bool
    let isIdempotent: Bool
}

enum AgentToolCatalog {
    static let definitions: [AgentToolDefinition] = [
        tool("montazhka_doctor", "Проверить готовность движка, модели и папок.", readOnly: true),
        tool(
            "montazhka_get_projects", "Получить проекты постранично или один по ID.",
            properties: [
                "projectId": string, "offset": integer, "limit": integer,
            ], readOnly: true),
        tool(
            "montazhka_edit_video", "Запустить фоновый монтаж одного или нескольких видео.",
            properties: editVideoProperties, required: ["sourcePaths"], destructive: true),
        tool(
            "montazhka_make_shorts", "Создать пять вертикальных роликов с субтитрами.",
            properties: [
                "sourcePath": string, "confirmModelDownload": boolean,
                "trimPauses": boolean,
            ], required: ["sourcePath"], destructive: true),
        tool(
            "montazhka_edit_project", "Применить точные резы и настройки к копии проекта.",
            properties: editProjectProperties, required: ["projectId"], destructive: true),
        tool(
            "montazhka_get_job", "Получить короткий статус фоновой задачи.", properties: ["jobId": string],
            required: ["jobId"], readOnly: true),
        tool(
            "montazhka_inspect", "Проверить проект и зоны склеек.",
            properties: [
                "projectId": string, "cuts": array(number),
            ], required: ["projectId"], readOnly: true),
        tool(
            "montazhka_export", "Создать черновой или подтверждённый финальный MP4.",
            properties: [
                "projectId": string, "outputPath": string,
                "quality": enumStrings(["compact", "medium", "high", "maximum"]),
                "final": boolean, "confirmFinal": boolean, "overwrite": boolean,
            ], required: ["projectId"], destructive: true),
    ]

    static var estimatedTokenCount: Int {
        (((try? JSONEncoder().encode(definitions).count) ?? 0) + 3) / 4
    }

    private static func tool(
        _ name: String, _ description: String,
        properties: [String: AgentJSONValue] = [:], required: [String] = [],
        readOnly: Bool = false, destructive: Bool = false,
        idempotent: Bool = false
    ) -> AgentToolDefinition {
        AgentToolDefinition(
            name: name,
            description: description,
            inputSchema: [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ],
            isReadOnly: readOnly,
            isDestructive: destructive,
            isIdempotent: idempotent)
    }

    private static let string: AgentJSONValue = .object(["type": "string"])
    private static let number: AgentJSONValue = .object(["type": "number"])
    private static let integer: AgentJSONValue = .object(["type": "integer"])
    private static let boolean: AgentJSONValue = .object(["type": "boolean"])
    private static func array(_ item: AgentJSONValue) -> AgentJSONValue {
        .object(["type": "array", "items": item])
    }
    private static func enumStrings(_ values: [String]) -> AgentJSONValue {
        .object(["type": "string", "enum": .array(values.map { .string($0) })])
    }
    private static let cut = AgentJSONValue.object([
        "type": "object",
        "properties": .object([
            "sourcePath": string, "start": number, "end": number,
        ]),
        "required": .array([.string("sourcePath"), .string("start"), .string("end")]),
        "additionalProperties": false,
    ])
    private static let commonEditProperties: [String: AgentJSONValue] = [
        "name": string,
        "profile": enumStrings(["clean-speech", "dynamic", "shorts"]),
        "cuts": array(cut), "removePauses": boolean, "enhanceVoice": boolean,
        "musicPath": string, "aiMode": enumStrings(["off", "built-in", "external"]),
        "confirmModelDownload": boolean,
    ]
    private static let editVideoProperties = commonEditProperties.merging(["sourcePaths": array(string)]) { _, new in
        new
    }
    private static let editProjectProperties = commonEditProperties.merging(["projectId": string]) { _, new in
        new
    }
}
