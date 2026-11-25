import Foundation
import Network

/// Lightweight HTTP/1.1 and Server-Sent Events (SSE) server for the Model Context Protocol (MCP).
/// Exposes:
/// - `GET /sse`: MCP Server-Sent Events stream
/// - `POST /message?sessionId=...`: MCP SSE message dispatcher
/// - `POST /mcp`: Direct JSON-RPC endpoint
/// - `GET /` & `GET /status`: Health and capabilities check
/// - `GET /openapi.json`: OpenAPI 3.0 specification for ChatGPT Custom GPTs / Actions
/// - `GET /api/meetings`, `POST /api/meetings/search`, etc.: REST endpoints
final class MCPHTTPServer: @unchecked Sendable {
    let port: UInt16
    let allowRemote: Bool
    let requireAuth: Bool
    let authToken: String
    let service: MCPService

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.muesli.mcp.http", attributes: .concurrent)
    private var activeSessions: [String: NWConnection] = [:]
    private var activeHandlers: [ObjectIdentifier: HTTPConnectionHandler] = [:]
    private let lock = NSLock()
    private var isRunning: Bool = false

    var onClientCountChange: ((Int) -> Void)?

    init(
        port: UInt16 = 4040,
        allowRemote: Bool = false,
        requireAuth: Bool = false,
        authToken: String = "",
        service: MCPService
    ) {
        self.port = port
        self.allowRemote = allowRemote
        self.requireAuth = requireAuth
        self.authToken = authToken
        self.service = service
    }

    func start() throws {
        let params = NWParameters.tcp
        if !allowRemote {
            params.requiredInterfaceType = .loopback
        }

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "MuesliMCP", code: 400, userInfo: [NSLocalizedDescriptionKey: "Porta inválida: \(port)"])
        }

        let listener = try NWListener(using: params, on: endpointPort)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
            case .failed(let err):
                self?.isRunning = false
                NSLog("Muesli MCP Server error: %@", err.localizedDescription)
            case .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: queue)
    }

    func stop() {
        isRunning = false
        listener?.cancel()
        listener = nil

        lock.lock()
        for (_, conn) in activeSessions {
            conn.cancel()
        }
        activeSessions.removeAll()
        for (_, handler) in activeHandlers {
            handler.cancel()
        }
        activeHandlers.removeAll()
        lock.unlock()
        onClientCountChange?(0)
    }

    var clientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeSessions.count
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        let handler = HTTPConnectionHandler(server: self, connection: connection)
        let id = ObjectIdentifier(connection)

        lock.lock()
        activeHandlers[id] = handler
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                guard let self else { return }
                self.lock.lock()
                self.activeHandlers.removeValue(forKey: id)
                self.lock.unlock()
            default:
                break
            }
        }

        handler.start()
    }

    func registerSession(id: String, connection: NWConnection) {
        lock.lock()
        activeSessions[id] = connection
        let count = activeSessions.count
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?.unregisterSession(id: id)
            default:
                break
            }
        }
        onClientCountChange?(count)
    }

    func unregisterSession(id: String) {
        lock.lock()
        activeSessions.removeValue(forKey: id)
        let count = activeSessions.count
        lock.unlock()
        onClientCountChange?(count)
    }

    func sendSSE(sessionID: String, event: String, data: String) {
        lock.lock()
        let conn = activeSessions[sessionID]
        lock.unlock()

        guard let conn else { return }
        let payload = "event: \(event)\ndata: \(data)\n\n"
        guard let raw = payload.data(using: .utf8) else { return }

        conn.send(content: raw, completion: .contentProcessed({ _ in }))
    }

    // MARK: - Authentication

    func isAuthorized(headers: [String: String], queryParams: [String: String]) -> Bool {
        guard requireAuth, !authToken.isEmpty else { return true }

        if let authHeader = headers["authorization"] {
            let parts = authHeader.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].lowercased() == "bearer" {
                if parts[1].trimmingCharacters(in: .whitespaces) == authToken {
                    return true
                }
            }
        }

        if let tokenQuery = queryParams["token"], tokenQuery == authToken {
            return true
        }

        return false
    }
}

// MARK: - HTTP Connection Handler

private final class HTTPConnectionHandler {
    private weak var server: MCPHTTPServer?
    private let connection: NWConnection
    private var buffer = Data()

    init(server: MCPHTTPServer, connection: NWConnection) {
        self.server = server
        self.connection = connection
    }

    func start() {
        readNextChunk()
    }

    func cancel() {
        connection.cancel()
    }

    private func readNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if error != nil || isComplete {
                if isComplete && self.buffer.isEmpty {
                    self.connection.cancel()
                }
            } else {
                self.readNextChunk()
            }
        }
    }

    private func processBuffer() {
        guard let headerEndRange = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else { // "\r\n\r\n"
            return
        }

        let headerData = buffer.subdata(in: 0..<headerEndRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            sendResponse(statusCode: 400, statusText: "Bad Request", body: "Invalid HTTP headers")
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return }

        let method = String(requestParts[0]).uppercased()
        let rawURI = String(requestParts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2 {
                let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                let val = pair[1].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStartIndex = headerEndRange.upperBound
        let totalNeeded = bodyStartIndex + contentLength

        if buffer.count < totalNeeded {
            // Wait for more data to complete the body
            return
        }

        let bodyData = buffer.subdata(in: bodyStartIndex..<totalNeeded)
        buffer.removeSubrange(0..<totalNeeded)

        handleRequest(method: method, rawURI: rawURI, headers: headers, body: bodyData)
    }

    private func handleRequest(method: String, rawURI: String, headers: [String: String], body: Data) {
        guard let server else { return }

        // CORS Preflight
        if method == "OPTIONS" {
            sendResponse(
                statusCode: 204,
                statusText: "No Content",
                headers: [
                    "Access-Control-Allow-Origin": "*",
                    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                    "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Requested-With"
                ],
                bodyData: Data()
            )
            return
        }

        // Parse path and query
        let uriParts = rawURI.split(separator: "?", maxSplits: 1)
        let path = String(uriParts[0])
        var queryParams: [String: String] = [:]
        if uriParts.count > 1 {
            let queryStr = String(uriParts[1])
            for pair in queryStr.components(separatedBy: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                    let v = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                    queryParams[k] = v
                }
            }
        }

        // Auth check (allow /status and /openapi.json without auth if desired, but verify for others)
        if path != "/" && path != "/status" && path != "/openapi.json" {
            if !server.isAuthorized(headers: headers, queryParams: queryParams) {
                sendJSON(statusCode: 401, json: ["error": "Unauthorized: forneça o Bearer token configurado no Muesli."])
                return
            }
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/status"):
            handleStatus()

        case ("GET", "/openapi.json"):
            handleOpenAPI()

        case ("GET", "/sse"):
            handleSSE(queryParams: queryParams)

        case ("POST", "/message"):
            handleSSEMessage(queryParams: queryParams, body: body)

        case ("POST", "/mcp"):
            handleDirectMCP(body: body)

        // REST Endpoints
        case ("GET", "/api/meetings"):
            handleRESTListMeetings(queryParams: queryParams)

        case ("POST", "/api/meetings/search"):
            handleRESTSearchMeetings(body: body)

        case ("GET", "/api/recording/status"):
            handleRESTRecordingStatus()

        case ("POST", "/api/recording/start"):
            handleRESTStartRecording(body: body)

        case ("POST", "/api/recording/stop"):
            handleRESTStopRecording()

        default:
            if path.hasPrefix("/api/meetings/") && method == "GET" {
                let id = String(path.dropFirst("/api/meetings/".count))
                handleRESTGetMeeting(id: id)
            } else {
                sendJSON(statusCode: 404, json: ["error": "Endpoint não encontrado: \(path)"])
            }
        }
    }

    // MARK: - Handlers

    private func handleStatus() {
        Task {
            let (isRec, isPaused, totalMeetings) = await MainActor.run {
                (self.server?.service.recorder?.isRecording ?? false,
                 self.server?.service.recorder?.isPaused ?? false,
                 self.server?.service.store.meetings.count ?? 0)
            }

            let info: [String: Any] = [
                "status": "ok",
                "app": "Muesli",
                "version": AppVersion.current,
                "total_meetings": totalMeetings,
                "is_recording": isRec,
                "is_paused": isPaused,
                "mcp": [
                    "version": "2024-11-05",
                    "transports": ["sse", "http", "stdio"],
                    "endpoints": [
                        "sse": "/sse",
                        "message": "/message",
                        "mcp": "/mcp",
                        "openapi": "/openapi.json",
                        "status": "/status"
                    ]
                ]
            ]
            self.sendJSON(statusCode: 200, json: info)
        }
    }

    private func handleOpenAPI() {
        let spec: [String: Any] = [
            "openapi": "3.0.0",
            "info": [
                "title": "Muesli Meeting Assistant API",
                "version": AppVersion.current,
                "description": "API REST e MCP para interação inteligente com as reuniões, transcrições e gravações do Muesli macOS."
            ],
            "servers": [
                ["url": "http://127.0.0.1:\(server?.port ?? 4040)"]
            ],
            "paths": [
                "/api/meetings": [
                    "get": [
                        "summary": "Listar reuniões",
                        "operationId": "listMeetings",
                        "parameters": [
                            ["name": "limit", "in": "query", "schema": ["type": "integer"], "description": "Limite máximo de reuniões."],
                            ["name": "search", "in": "query", "schema": ["type": "string"], "description": "Filtro de busca."]
                        ],
                        "responses": ["200": ["description": "Lista de reuniões"]]
                    ]
                ],
                "/api/meetings/{id}": [
                    "get": [
                        "summary": "Obter reunião por ID ou pasta",
                        "operationId": "getMeeting",
                        "parameters": [
                            ["name": "id", "in": "path", "required": true, "schema": ["type": "string"]]
                        ],
                        "responses": ["200": ["description": "Detalhes e transcrição da reunião"]]
                    ]
                ],
                "/api/meetings/search": [
                    "post": [
                        "summary": "Pesquisar no histórico de reuniões e transcrições",
                        "operationId": "searchMeetings",
                        "requestBody": [
                            "required": true,
                            "content": ["application/json": ["schema": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]]]
                        ],
                        "responses": ["200": ["description": "Resultados da busca"]]
                    ]
                ],
                "/api/recording/status": [
                    "get": [
                        "summary": "Verificar status da gravação ao vivo",
                        "operationId": "getRecordingStatus",
                        "responses": ["200": ["description": "Status de gravação"]]
                    ]
                ],
                "/api/recording/start": [
                    "post": [
                        "summary": "Iniciar nova gravação",
                        "operationId": "startRecording",
                        "requestBody": [
                            "content": ["application/json": ["schema": ["type": "object", "properties": ["title": ["type": "string"], "capture_system_audio": ["type": "boolean"]]]]]
                        ],
                        "responses": ["200": ["description": "Gravação iniciada"]]
                    ]
                ],
                "/api/recording/stop": [
                    "post": [
                        "summary": "Parar gravação ativa",
                        "operationId": "stopRecording",
                        "responses": ["200": ["description": "Gravação parada"]]
                    ]
                ]
            ]
        ]
        sendJSON(statusCode: 200, json: spec)
    }

    private func handleSSE(queryParams: [String: String]) {
        guard let server else { return }

        let sessionID = UUID().uuidString
        server.registerSession(id: sessionID, connection: connection)

        let initialHeaders = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "Access-Control-Allow-Origin": "*"
        ]

        var headerStr = "HTTP/1.1 200 OK\r\n"
        for (k, v) in initialHeaders {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "\r\n"

        // Send headers
        if let raw = headerStr.data(using: .utf8) {
            connection.send(content: raw, completion: .contentProcessed({ _ in }))
        }

        // Send endpoint event with message URI
        let endpointEvent = "event: endpoint\ndata: /message?sessionId=\(sessionID)\n\n"
        if let raw = endpointEvent.data(using: .utf8) {
            connection.send(content: raw, completion: .contentProcessed({ _ in }))
        }
    }

    private func handleSSEMessage(queryParams: [String: String], body: Data) {
        guard let server else { return }
        let sessionID = queryParams["sessionId"]

        Task {
            let responseData = await server.service.handle(data: body)
            if let sessionID, let responseStr = String(data: responseData, encoding: .utf8) {
                server.sendSSE(sessionID: sessionID, event: "message", data: responseStr)
            }
            // Return 200 OK with responseData also in the POST body for maximum client compatibility
            self.sendResponse(statusCode: 200, statusText: "OK", headers: ["Content-Type": "application/json"], bodyData: responseData)
        }
    }

    private func handleDirectMCP(body: Data) {
        guard let server else { return }

        Task {
            let responseData = await server.service.handle(data: body)
            self.sendResponse(statusCode: 200, statusText: "OK", headers: ["Content-Type": "application/json"], bodyData: responseData)
        }
    }

    // MARK: - REST Handlers

    private func handleRESTListMeetings(queryParams: [String: String]) {
        guard let server else { return }
        Task {
            let req = JSONRPCRequest(id: .int(1), method: "tools/call", params: AnyCodable([
                "name": AnyCodable("list_meetings"),
                "arguments": AnyCodable([
                    "limit": AnyCodable(Int(queryParams["limit"] ?? "20") ?? 20),
                    "search": AnyCodable(queryParams["search"] ?? "")
                ])
            ]))
            let res = await server.service.handle(request: req)
            self.sendToolResultJSON(res)
        }
    }

    private func handleRESTGetMeeting(id: String) {
        guard let server else { return }
        Task {
            let req = JSONRPCRequest(id: .int(1), method: "tools/call", params: AnyCodable([
                "name": AnyCodable("get_meeting"),
                "arguments": AnyCodable(["id": AnyCodable(id)])
            ]))
            let res = await server.service.handle(request: req)
            self.sendToolResultJSON(res)
        }
    }

    private func handleRESTSearchMeetings(body: Data) {
        guard let server else { return }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let query = json["query"] as? String ?? ""

        Task {
            let req = JSONRPCRequest(id: .int(1), method: "tools/call", params: AnyCodable([
                "name": AnyCodable("search_meetings"),
                "arguments": AnyCodable(["query": AnyCodable(query)])
            ]))
            let res = await server.service.handle(request: req)
            self.sendToolResultJSON(res)
        }
    }

    private func handleRESTRecordingStatus() {
        guard let server else { return }
        Task {
            let req = JSONRPCRequest(id: .int(1), method: "tools/call", params: AnyCodable([
                "name": AnyCodable("get_recording_status"),
                "arguments": AnyCodable([String: AnyCodable]())
            ]))
            let res = await server.service.handle(request: req)
            self.sendToolResultJSON(res)
        }
    }

    private func handleRESTStartRecording(body: Data) {
        guard let server else { return }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let title = json["title"] as? String
        let sys = json["capture_system_audio"] as? Bool

        Task {
            var args: [String: AnyCodable] = [:]
            if let title { args["title"] = AnyCodable(title) }
            if let sys { args["capture_system_audio"] = AnyCodable(sys) }

            let req = JSONRPCRequest(id: .int(1), method: "tools/call", params: AnyCodable([
                "name": AnyCodable("start_recording"),
                "arguments": AnyCodable(args)
            ]))
            let res = await server.service.handle(request: req)
            self.sendToolResultJSON(res)
        }
    }

    private func handleRESTStopRecording() {
        guard let server else { return }
        Task {
            let req = JSONRPCRequest(id: .int(1), method: "tools/call", params: AnyCodable([
                "name": AnyCodable("stop_recording"),
                "arguments": AnyCodable([String: AnyCodable]())
            ]))
            let res = await server.service.handle(request: req)
            self.sendToolResultJSON(res)
        }
    }

    private func sendToolResultJSON(_ response: JSONRPCResponse?) {
        guard let response,
              let resultDict = response.result?.dictionaryValue,
              let contentArray = resultDict["content"]?.arrayValue,
              let firstText = contentArray.first?.dictionaryValue?["text"]?.stringValue,
              let data = firstText.data(using: .utf8) else {
            sendJSON(statusCode: 500, json: ["error": "Falha ao processar comando"])
            return
        }
        sendResponse(statusCode: 200, statusText: "OK", headers: ["Content-Type": "application/json"], bodyData: data)
    }

    // MARK: - HTTP Response Helpers

    private func sendJSON(statusCode: Int, json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .withoutEscapingSlashes])) ?? Data()
        sendResponse(statusCode: statusCode, statusText: statusCode == 200 ? "OK" : "Error", headers: ["Content-Type": "application/json"], bodyData: data)
    }

    private func sendResponse(statusCode: Int, statusText: String, headers: [String: String] = [:], body: String) {
        sendResponse(statusCode: statusCode, statusText: statusText, headers: headers, bodyData: body.data(using: .utf8) ?? Data())
    }

    private func sendResponse(statusCode: Int, statusText: String, headers: [String: String] = [:], bodyData: Data) {
        var allHeaders = headers
        allHeaders["Content-Length"] = String(bodyData.count)
        allHeaders["Access-Control-Allow-Origin"] = "*"
        if allHeaders["Connection"] == nil {
            allHeaders["Connection"] = "close"
        }

        var headerStr = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        for (k, v) in allHeaders {
            headerStr += "\(k): \(v)\r\n"
        }
        headerStr += "\r\n"

        var fullData = headerStr.data(using: .utf8) ?? Data()
        fullData.append(bodyData)

        connection.send(content: fullData, completion: .contentProcessed({ [weak self] _ in
            if allHeaders["Connection"] == "close" {
                self?.connection.cancel()
            }
        }))
    }
}
