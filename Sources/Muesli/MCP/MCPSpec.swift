import Foundation

// MARK: - JSON-RPC 2.0 Base Types

enum JSONRPCID: Codable, Equatable, Hashable, CustomStringConvertible, Sendable {
    case string(String)
    case int(Int)

    var description: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected Int or String for JSONRPCID")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s):
            try container.encode(s)
        case .int(let i):
            try container.encode(i)
        }
    }
}

struct JSONRPCRequest: Codable, Sendable {
    var jsonrpc: String = "2.0"
    var id: JSONRPCID?
    var method: String
    var params: AnyCodable?

    init(id: JSONRPCID? = nil, method: String, params: AnyCodable? = nil) {
        self.jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

struct JSONRPCResponse: Codable, Sendable {
    var jsonrpc: String = "2.0"
    var id: JSONRPCID?
    var result: AnyCodable?
    var error: JSONRPCError?

    init(id: JSONRPCID?, result: AnyCodable?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    init(id: JSONRPCID?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

struct JSONRPCError: Codable, Equatable, Error, Sendable {
    var code: Int
    var message: String
    var data: AnyCodable?

    init(code: Int, message: String, data: AnyCodable? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    static func parseError(_ message: String = "Parse error") -> JSONRPCError {
        .init(code: -32700, message: message)
    }

    static func invalidRequest(_ message: String = "Invalid request") -> JSONRPCError {
        .init(code: -32600, message: message)
    }

    static func methodNotFound(_ method: String) -> JSONRPCError {
        .init(code: -32601, message: "Method not found: \(method)")
    }

    static func invalidParams(_ message: String = "Invalid params") -> JSONRPCError {
        .init(code: -32602, message: message)
    }

    static func internalError(_ message: String = "Internal error") -> JSONRPCError {
        .init(code: -32603, message: message)
    }
}

// MARK: - AnyCodable

struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    let value: Any

    init(_ value: Any?) {
        self.value = value ?? ()
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (Void, Void):
            return true
        case let (l as Bool, r as Bool):
            return l == r
        case let (l as Int, r as Int):
            return l == r
        case let (l as Double, r as Double):
            return l == r
        case let (l as String, r as String):
            return l == r
        case let (l as [AnyCodable], r as [AnyCodable]):
            return l == r
        case let (l as [String: AnyCodable], r as [String: AnyCodable]):
            return l == r
        default:
            return "\(lhs.value)" == "\(rhs.value)"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = ()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported AnyCodable value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is Void:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [AnyCodable]:
            try container.encode(array)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: AnyCodable]:
            try container.encode(dict)
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encode(String(describing: value))
        }
    }

    var stringValue: String? {
        value as? String
    }

    var intValue: Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        return nil
    }

    var doubleValue: Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    var boolValue: Bool? {
        value as? Bool
    }

    var arrayValue: [AnyCodable]? {
        if let arr = value as? [AnyCodable] { return arr }
        if let arr = value as? [Any] { return arr.map { AnyCodable($0) } }
        return nil
    }

    var dictionaryValue: [String: AnyCodable]? {
        if let dict = value as? [String: AnyCodable] { return dict }
        if let dict = value as? [String: Any] { return dict.mapValues { AnyCodable($0) } }
        return nil
    }
}

extension AnyCodable: ExpressibleByNilLiteral {
    init(nilLiteral: ()) { self.init(()) }
}
extension AnyCodable: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self.init(value) }
}
extension AnyCodable: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self.init(value) }
}
extension AnyCodable: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self.init(value) }
}
extension AnyCodable: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self.init(value) }
}
extension AnyCodable: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: AnyCodable...) { self.init(elements) }
}
extension AnyCodable: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, AnyCodable)...) {
        var dict: [String: AnyCodable] = [:]
        for (k, v) in elements { dict[k] = v }
        self.init(dict)
    }
}

// MARK: - MCP Protocol Models

struct MCPClientInfo: Codable, Sendable {
    var name: String
    var version: String?

    init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

struct MCPInitializeParams: Codable, Sendable {
    var protocolVersion: String
    var capabilities: [String: AnyCodable]?
    var clientInfo: MCPClientInfo?

    init(protocolVersion: String = "2024-11-05", capabilities: [String: AnyCodable]? = nil, clientInfo: MCPClientInfo? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

struct MCPServerCapabilities: Codable, Sendable {
    struct ToolsCapability: Codable, Sendable {
        var listChanged: Bool = false
        init(listChanged: Bool = false) { self.listChanged = listChanged }
    }
    struct ResourcesCapability: Codable, Sendable {
        var subscribe: Bool = false
        var listChanged: Bool = false
        init(subscribe: Bool = false, listChanged: Bool = false) {
            self.subscribe = subscribe
            self.listChanged = listChanged
        }
    }
    struct PromptsCapability: Codable, Sendable {
        var listChanged: Bool = false
        init(listChanged: Bool = false) { self.listChanged = listChanged }
    }

    var tools: ToolsCapability?
    var resources: ResourcesCapability?
    var prompts: PromptsCapability?
    var logging: [String: AnyCodable]?

    init(
        tools: ToolsCapability? = ToolsCapability(),
        resources: ResourcesCapability? = ResourcesCapability(),
        prompts: PromptsCapability? = PromptsCapability(),
        logging: [String: AnyCodable]? = [:]
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
        self.logging = logging
    }
}

struct MCPServerInfo: Codable, Sendable {
    var name: String
    var version: String

    init(name: String = "muesli", version: String = AppVersion.current) {
        self.name = name
        self.version = version
    }
}

struct MCPInitializeResult: Codable, Sendable {
    var protocolVersion: String
    var capabilities: MCPServerCapabilities
    var serverInfo: MCPServerInfo
    var instructions: String?

    init(
        protocolVersion: String = "2024-11-05",
        capabilities: MCPServerCapabilities = MCPServerCapabilities(),
        serverInfo: MCPServerInfo = MCPServerInfo(),
        instructions: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

struct MCPTool: Codable, Sendable {
    var name: String
    var description: String
    var inputSchema: AnyCodable

    init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = AnyCodable(inputSchema)
    }
}

struct MCPContent: Codable, Sendable {
    var type: String
    var text: String?

    init(type: String = "text", text: String) {
        self.type = type
        self.text = text
    }

    static func text(_ string: String) -> MCPContent {
        MCPContent(type: "text", text: string)
    }
}

struct MCPToolCallResult: Codable, Sendable {
    var content: [MCPContent]
    var isError: Bool?

    init(content: [MCPContent], isError: Bool? = nil) {
        self.content = content
        self.isError = isError
    }

    static func text(_ text: String, isError: Bool = false) -> MCPToolCallResult {
        MCPToolCallResult(content: [.text(text)], isError: isError ? true : nil)
    }
}

struct MCPResource: Codable, Sendable {
    var uri: String
    var name: String
    var description: String?
    var mimeType: String?

    init(uri: String, name: String, description: String? = nil, mimeType: String? = "text/markdown") {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

struct MCPResourceContent: Codable, Sendable {
    var uri: String
    var mimeType: String?
    var text: String?

    init(uri: String, mimeType: String? = "text/markdown", text: String) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
    }
}

struct MCPPromptArgument: Codable, Sendable {
    var name: String
    var description: String?
    var required: Bool?

    init(name: String, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.description = description
        self.required = required
    }
}

struct MCPPrompt: Codable, Sendable {
    var name: String
    var description: String?
    var arguments: [MCPPromptArgument]?

    init(name: String, description: String? = nil, arguments: [MCPPromptArgument]? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }
}

struct MCPPromptMessage: Codable, Sendable {
    var role: String
    var content: MCPContent

    init(role: String = "user", content: MCPContent) {
        self.role = role
        self.content = content
    }
}
