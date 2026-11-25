import Foundation

/// Central dispatcher and business logic engine for the Model Context Protocol (MCP).
/// Provides full access to meetings, search, notes, transcripts, categories, templates,
/// and live audio recording control.
@MainActor
final class MCPService {
    let store: MeetingStore
    let settings: AppSettings
    weak var recorder: RecordingController?

    init(store: MeetingStore, settings: AppSettings, recorder: RecordingController? = nil) {
        self.store = store
        self.settings = settings
        self.recorder = recorder
    }

    // MARK: - Dispatch

    func handle(data: Data) async -> Data {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        guard let request = try? decoder.decode(JSONRPCRequest.self, from: data) else {
            let errResp = JSONRPCResponse(id: nil, error: .parseError())
            return (try? encoder.encode(errResp)) ?? Data()
        }

        if let response = await handle(request: request) {
            return (try? encoder.encode(response)) ?? Data()
        }
        return Data()
    }

    func handle(request: JSONRPCRequest) async -> JSONRPCResponse? {
        // Notification (no id) -> no response
        let isNotification = (request.id == nil)

        switch request.method {
        case "initialize":
            let result = MCPInitializeResult(
                protocolVersion: "2024-11-05",
                capabilities: MCPServerCapabilities(
                    tools: .init(listChanged: false),
                    resources: .init(subscribe: false, listChanged: false),
                    prompts: .init(listChanged: false),
                    logging: [:]
                ),
                serverInfo: MCPServerInfo(name: "muesli", version: AppVersion.current),
                instructions: """
                Muesli é o assistente inteligente de reuniões para macOS.
                Você tem acesso completo aos dados de reuniões do usuário: transcrições completas com identificação de falantes (Eu vs Outros), anotações manuais, atas aprimoradas por IA, categorias e status de gravação.
                Use as ferramentas para consultar reuniões passadas, pesquisar conversas, iniciar ou parar gravações ao vivo e atualizar anotações.
                """
            )
            return JSONRPCResponse(id: request.id, result: AnyCodable(try? AnyCodableWrapper.wrap(result)))

        case "notifications/initialized":
            return nil

        case "ping":
            return JSONRPCResponse(id: request.id, result: AnyCodable([String: AnyCodable]()))

        case "tools/list":
            let tools = allTools()
            let dict: [String: AnyCodable] = [
                "tools": AnyCodable(try? AnyCodableWrapper.wrap(tools))
            ]
            return JSONRPCResponse(id: request.id, result: AnyCodable(dict))

        case "tools/call":
            guard let id = request.id else { return nil }
            return await handleToolCall(id: id, params: request.params)

        case "resources/list":
            guard let id = request.id else { return nil }
            let resources = allResources()
            let dict: [String: AnyCodable] = [
                "resources": AnyCodable(try? AnyCodableWrapper.wrap(resources))
            ]
            return JSONRPCResponse(id: id, result: AnyCodable(dict))

        case "resources/read":
            guard let id = request.id else { return nil }
            return handleResourceRead(id: id, params: request.params)

        case "prompts/list":
            guard let id = request.id else { return nil }
            let prompts = allPrompts()
            let dict: [String: AnyCodable] = [
                "prompts": AnyCodable(try? AnyCodableWrapper.wrap(prompts))
            ]
            return JSONRPCResponse(id: id, result: AnyCodable(dict))

        case "prompts/get":
            guard let id = request.id else { return nil }
            return handlePromptGet(id: id, params: request.params)

        default:
            if isNotification { return nil }
            return JSONRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    // MARK: - Tool Definitions

    func allTools() -> [MCPTool] {
        [
            MCPTool(
                name: "list_meetings",
                description: "Lista as reuniões armazenadas no Muesli com metadados (ID, título, data, duração, categoria, notas e resumo).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "description": "Número máximo de reuniões a retornar (padrão: 20)."],
                        "category": ["type": "string", "description": "Filtrar por nome ou ID da categoria."],
                        "search": ["type": "string", "description": "Filtrar reuniões que contenham este texto no título ou anotações."]
                    ]
                ]
            ),
            MCPTool(
                name: "get_meeting",
                description: "Obtém todos os detalhes de uma reunião específica pelo ID (UUID ou nome da pasta) ou por título. Retorna anotações brutas, ata aprimorada gerada por IA e a transcrição na íntegra com falantes e timestamps.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "ID da reunião (UUID ou nome da pasta)."],
                        "title": ["type": "string", "description": "Título aproximado ou exato caso não tenha o ID."],
                        "include_transcript": ["type": "boolean", "description": "Se verdadeiro, inclui toda a transcrição (padrão: true)."]
                    ]
                ]
            ),
            MCPTool(
                name: "search_meetings",
                description: "Pesquisa por palavra-chave ou frase em todo o histórico de reuniões: títulos, anotações manuais, atas aprimoradas e transcrições completas de áudio.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Termo de busca."],
                        "limit": ["type": "integer", "description": "Limite máximo de resultados (padrão: 10)."]
                    ],
                    "required": ["query"]
                ]
            ),
            MCPTool(
                name: "create_meeting",
                description: "Cria uma nova reunião no Muesli com título, anotações iniciais em Markdown e categoria opcional.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Título da reunião."],
                        "notes": ["type": "string", "description": "Anotações iniciais em Markdown."],
                        "category": ["type": "string", "description": "Nome da categoria para atribuir."],
                        "template_id": ["type": "string", "description": "ID do modelo de ata (ex: auto, formal, 1on1, standup, brainstorm)."]
                    ]
                ]
            ),
            MCPTool(
                name: "update_notes",
                description: "Atualiza ou adiciona anotações em Markdown a uma reunião existente.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "ID ou nome da pasta da reunião."],
                        "notes": ["type": "string", "description": "Texto em Markdown a adicionar ou atualizar."],
                        "append": ["type": "boolean", "description": "Se true, concatena ao final das anotações existentes. Se false, substitui por completo."]
                    ],
                    "required": ["id", "notes"]
                ]
            ),
            MCPTool(
                name: "set_enhanced_notes",
                description: "Salva a ata aprimorada por IA (enhanced.md) de uma reunião.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "ID ou nome da pasta da reunião."],
                        "markdown": ["type": "string", "description": "Conteúdo da ata/resumo em Markdown."]
                    ],
                    "required": ["id", "markdown"]
                ]
            ),
            MCPTool(
                name: "enhance_meeting",
                description: "Aciona o mecanismo de aprimoramento por IA configurado no Muesli (Groq, Gemini, OpenAI, Claude ou Ollama) para produzir e salvar a ata da reunião.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "ID ou nome da pasta da reunião."]
                    ],
                    "required": ["id"]
                ]
            ),
            MCPTool(
                name: "delete_meeting",
                description: "Remove uma reunião do Muesli, movendo seus arquivos para a Lixeira do macOS.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "ID ou nome da pasta da reunião."]
                    ],
                    "required": ["id"]
                ]
            ),
            MCPTool(
                name: "list_categories",
                description: "Lista todas as categorias configuradas no Muesli com contagem de reuniões.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ),
            MCPTool(
                name: "create_category",
                description: "Cria uma nova categoria no Muesli.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "name": ["type": "string", "description": "Nome da categoria."]
                    ],
                    "required": ["name"]
                ]
            ),
            MCPTool(
                name: "list_templates",
                description: "Lista os modelos de atas disponíveis no Muesli (ex: Formal, Daily Scrum, 1-on-1, etc.).",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ),
            MCPTool(
                name: "get_recording_status",
                description: "Consulta o estado atual da gravação no Muesli: se está gravando, qual reunião está ativa, tempo decorrido e níveis de áudio.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ),
            MCPTool(
                name: "start_recording",
                description: "Inicia imediatamente uma gravação de reunião no aplicativo Muesli aberto.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Título opcional para a nova reunião."],
                        "capture_system_audio": ["type": "boolean", "description": "Se verdadeiro, grava também o áudio dos outros participantes."],
                        "category": ["type": "string", "description": "Categoria da reunião."]
                    ]
                ]
            ),
            MCPTool(
                name: "stop_recording",
                description: "Para a gravação atual em andamento no Muesli e finaliza a transcrição.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ),
            MCPTool(
                name: "get_live_transcript",
                description: "Obtém a transcrição em tempo real gerada até agora na reunião que está sendo gravada.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            )
        ]
    }

    // MARK: - Tool Execution

    private func handleToolCall(id: JSONRPCID, params: AnyCodable?) async -> JSONRPCResponse {
        guard let dict = params?.dictionaryValue,
              let name = dict["name"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams("Missing 'name' in tools/call"))
        }

        let args = dict["arguments"]?.dictionaryValue ?? [:]

        do {
            let textResult: String
            switch name {
            case "list_meetings":
                textResult = try executeListMeetings(args: args)
            case "get_meeting":
                textResult = try executeGetMeeting(args: args)
            case "search_meetings":
                textResult = try executeSearchMeetings(args: args)
            case "create_meeting":
                textResult = try executeCreateMeeting(args: args)
            case "update_notes":
                textResult = try executeUpdateNotes(args: args)
            case "set_enhanced_notes":
                textResult = try executeSetEnhancedNotes(args: args)
            case "enhance_meeting":
                textResult = try await executeEnhanceMeeting(args: args)
            case "delete_meeting":
                textResult = try executeDeleteMeeting(args: args)
            case "list_categories":
                textResult = try executeListCategories()
            case "create_category":
                textResult = try executeCreateCategory(args: args)
            case "list_templates":
                textResult = try executeListTemplates()
            case "get_recording_status":
                textResult = try executeGetRecordingStatus()
            case "start_recording":
                textResult = try await executeStartRecording(args: args)
            case "stop_recording":
                textResult = try await executeStopRecording()
            case "get_live_transcript":
                textResult = try executeGetLiveTranscript()
            default:
                return JSONRPCResponse(id: id, error: .methodNotFound("Unknown tool '\(name)'"))
            }

            let result = MCPToolCallResult.text(textResult)
            return JSONRPCResponse(id: id, result: AnyCodable(try? AnyCodableWrapper.wrap(result)))
        } catch {
            let errResult = MCPToolCallResult.text("Erro: \(error.localizedDescription)", isError: true)
            return JSONRPCResponse(id: id, result: AnyCodable(try? AnyCodableWrapper.wrap(errResult)))
        }
    }

    // MARK: - Tool Implementations

    private func executeListMeetings(args: [String: AnyCodable]) throws -> String {
        let limit = args["limit"]?.intValue ?? 20
        let categoryFilter = args["category"]?.stringValue?.lowercased().trimmingCharacters(in: .whitespaces)
        let searchFilter = args["search"]?.stringValue?.lowercased().trimmingCharacters(in: .whitespaces)

        var list = store.meetings

        if let cat = categoryFilter, !cat.isEmpty {
            list = list.filter { m in
                guard let catID = m.categoryID,
                      let category = store.categories.first(where: { $0.id == catID }) else { return false }
                return category.name.lowercased().contains(cat) || catID.uuidString.lowercased() == cat
            }
        }

        if let s = searchFilter, !s.isEmpty {
            list = list.filter { m in
                m.title.lowercased().contains(s) || m.notesMD.lowercased().contains(s)
            }
        }

        let slice = list.prefix(limit)
        let iso = ISO8601DateFormatter()
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        let items: [[String: Any]] = slice.map { m in
            let catName = m.categoryID.flatMap { id in store.categories.first(where: { $0.id == id })?.name }
            return [
                "id": m.id.uuidString,
                "folder": m.folderName,
                "title": m.title,
                "date": iso.string(from: m.createdAt),
                "formatted_date": df.string(from: m.createdAt),
                "duration_seconds": m.durationSeconds,
                "duration_formatted": formatClock(m.durationSeconds),
                "category": catName ?? "",
                "has_transcript": m.hasTranscript,
                "transcript_segments_count": m.transcript.count,
                "has_enhanced_notes": m.enhancedMD != nil && !(m.enhancedMD?.isEmpty ?? true),
                "notes_preview": String(m.notesMD.prefix(120)).replacingOccurrences(of: "\n", with: " ")
            ]
        }

        let total = store.meetings.count
        let output: [String: Any] = [
            "total_meetings": total,
            "returned_count": items.count,
            "meetings": items
        ]
        return toJSONString(output)
    }

    private func findMeeting(by idOrTitle: String) -> Meeting? {
        let clean = idOrTitle.trimmingCharacters(in: .whitespaces)
        if let uuid = UUID(uuidString: clean), let m = store.meeting(uuid) {
            return m
        }
        if let m = store.meetings.first(where: { $0.folderName == clean }) {
            return m
        }
        let lower = clean.lowercased()
        return store.meetings.first(where: { $0.title.lowercased() == lower })
            ?? store.meetings.first(where: { $0.title.lowercased().contains(lower) })
    }

    private func executeGetMeeting(args: [String: AnyCodable]) throws -> String {
        let idArg = args["id"]?.stringValue
        let titleArg = args["title"]?.stringValue
        let query = idArg ?? titleArg ?? ""

        guard !query.isEmpty, let meeting = findMeeting(by: query) else {
            throw NSError(domain: "MuesliMCP", code: 404, userInfo: [NSLocalizedDescriptionKey: "Reunião não encontrada para '\(query)'."])
        }

        let includeTranscript = args["include_transcript"]?.boolValue ?? true
        let iso = ISO8601DateFormatter()
        let catName = meeting.categoryID.flatMap { id in store.categories.first(where: { $0.id == id })?.name }

        var transcriptMarkdown = ""
        var segmentsArray: [[String: Any]] = []

        if includeTranscript && meeting.hasTranscript {
            transcriptMarkdown = MeetingStore.transcriptMarkdown(meeting)
            segmentsArray = meeting.transcript.map { s in
                [
                    "speaker": s.speaker.rawValue,
                    "speaker_label": s.speaker.label,
                    "start": s.start,
                    "end": s.end,
                    "time": "[\(formatClock(s.start)) - \(formatClock(s.end))]",
                    "text": s.text
                ]
            }
        }

        let folder = store.folder(for: meeting)
        let micWav = folder.appendingPathComponent("mic.wav")
        let sysWav = folder.appendingPathComponent("system.wav")

        var dict: [String: Any] = [
            "id": meeting.id.uuidString,
            "folder": meeting.folderName,
            "folder_path": folder.path,
            "title": meeting.title,
            "created_at": iso.string(from: meeting.createdAt),
            "duration_seconds": meeting.durationSeconds,
            "duration_formatted": formatClock(meeting.durationSeconds),
            "category": catName ?? "",
            "template_id": meeting.templateID,
            "notes": meeting.notesMD,
            "enhanced_notes": meeting.enhancedMD ?? "",
            "has_mic_audio": FileManager.default.fileExists(atPath: micWav.path),
            "has_system_audio": FileManager.default.fileExists(atPath: sysWav.path),
            "transcript_summary": [
                "segment_count": meeting.transcript.count,
                "has_transcript": meeting.hasTranscript
            ]
        ]

        if includeTranscript {
            dict["transcript_markdown"] = transcriptMarkdown
            dict["transcript_segments"] = segmentsArray
        }

        return toJSONString(dict)
    }

    private func executeSearchMeetings(args: [String: AnyCodable]) throws -> String {
        guard let query = args["query"]?.stringValue?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw NSError(domain: "MuesliMCP", code: 400, userInfo: [NSLocalizedDescriptionKey: "O argumento 'query' é obrigatório."])
        }

        let limit = args["limit"]?.intValue ?? 10
        let lowerQuery = query.lowercased()

        struct SearchMatch {
            let meeting: Meeting
            let matchedFields: [String]
            let snippet: String
            let score: Int
        }

        var matches: [SearchMatch] = []

        for m in store.meetings {
            var matchedFields: [String] = []
            var score = 0
            var snippet = ""

            if m.title.lowercased().contains(lowerQuery) {
                matchedFields.append("título")
                score += 10
                snippet = m.title
            }

            if m.notesMD.lowercased().contains(lowerQuery) {
                matchedFields.append("anotações")
                score += 5
                if snippet.isEmpty {
                    snippet = extractSnippet(from: m.notesMD, match: lowerQuery)
                }
            }

            if let enhanced = m.enhancedMD, enhanced.lowercased().contains(lowerQuery) {
                matchedFields.append("ata_aprimorada")
                score += 5
                if snippet.isEmpty {
                    snippet = extractSnippet(from: enhanced, match: lowerQuery)
                }
            }

            for seg in m.transcript where seg.text.lowercased().contains(lowerQuery) {
                if !matchedFields.contains("transcrição") {
                    matchedFields.append("transcrição")
                    score += 8
                    if snippet.isEmpty {
                        snippet = "[\(seg.speaker.label) \(formatClock(seg.start))]: " + extractSnippet(from: seg.text, match: lowerQuery)
                    }
                }
            }

            if !matchedFields.isEmpty {
                matches.append(SearchMatch(meeting: m, matchedFields: matchedFields, snippet: snippet, score: score))
            }
        }

        matches.sort { $0.score > $1.score }
        let slice = matches.prefix(limit)

        let iso = ISO8601DateFormatter()
        let results: [[String: Any]] = slice.map { match in
            let m = match.meeting
            let catName = m.categoryID.flatMap { id in store.categories.first(where: { $0.id == id })?.name }
            return [
                "id": m.id.uuidString,
                "folder": m.folderName,
                "title": m.title,
                "created_at": iso.string(from: m.createdAt),
                "duration_formatted": formatClock(m.durationSeconds),
                "category": catName ?? "",
                "matched_in": match.matchedFields,
                "context_snippet": match.snippet
            ]
        }

        return toJSONString([
            "query": query,
            "total_matches": matches.count,
            "results": results
        ])
    }

    private func extractSnippet(from text: String, match: String) -> String {
        guard let range = text.range(of: match, options: .caseInsensitive) else {
            return String(text.prefix(150))
        }
        let start = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 60, limitedBy: text.endIndex) ?? text.endIndex
        let snippet = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return "…\(snippet)…"
    }

    private func executeCreateMeeting(args: [String: AnyCodable]) throws -> String {
        let title = args["title"]?.stringValue
        let notes = args["notes"]?.stringValue ?? ""
        let templateID = args["template_id"]?.stringValue ?? "auto"
        let categoryName = args["category"]?.stringValue

        var catID: UUID?
        if let catName = categoryName?.trimmingCharacters(in: .whitespaces), !catName.isEmpty {
            if let existing = store.categories.first(where: { $0.name.localizedCaseInsensitiveCompare(catName) == .orderedSame }) {
                catID = existing.id
            } else if let created = store.createCategory(name: catName) {
                catID = created.id
            }
        }

        let meeting = store.createMeeting(title: title, templateID: templateID, categoryID: catID)
        if !notes.isEmpty {
            store.updateNotes(meeting.id, notes: notes)
        }

        return toJSONString([
            "message": "Reunião criada com sucesso.",
            "id": meeting.id.uuidString,
            "folder": meeting.folderName,
            "title": meeting.title,
            "template_id": templateID,
            "notes": notes
        ])
    }

    private func executeUpdateNotes(args: [String: AnyCodable]) throws -> String {
        guard let idStr = args["id"]?.stringValue,
              let meeting = findMeeting(by: idStr) else {
            throw NSError(domain: "MuesliMCP", code: 404, userInfo: [NSLocalizedDescriptionKey: "Reunião não encontrada."])
        }
        guard let notes = args["notes"]?.stringValue else {
            throw NSError(domain: "MuesliMCP", code: 400, userInfo: [NSLocalizedDescriptionKey: "O campo 'notes' é obrigatório."])
        }

        let append = args["append"]?.boolValue ?? false
        let finalNotes = append ? (meeting.notesMD + "\n\n" + notes) : notes
        store.updateNotes(meeting.id, notes: finalNotes)

        return toJSONString([
            "message": "Anotações atualizadas com sucesso.",
            "id": meeting.id.uuidString,
            "title": meeting.title,
            "notes": finalNotes
        ])
    }

    private func executeSetEnhancedNotes(args: [String: AnyCodable]) throws -> String {
        guard let idStr = args["id"]?.stringValue,
              let meeting = findMeeting(by: idStr) else {
            throw NSError(domain: "MuesliMCP", code: 404, userInfo: [NSLocalizedDescriptionKey: "Reunião não encontrada."])
        }
        guard let md = args["markdown"]?.stringValue else {
            throw NSError(domain: "MuesliMCP", code: 400, userInfo: [NSLocalizedDescriptionKey: "O campo 'markdown' é obrigatório."])
        }

        store.setEnhanced(meeting.id, markdown: md)

        return toJSONString([
            "message": "Ata aprimorada salva com sucesso.",
            "id": meeting.id.uuidString,
            "title": meeting.title
        ])
    }

    private func executeEnhanceMeeting(args: [String: AnyCodable]) async throws -> String {
        guard let idStr = args["id"]?.stringValue,
              let meeting = findMeeting(by: idStr) else {
            throw NSError(domain: "MuesliMCP", code: 404, userInfo: [NSLocalizedDescriptionKey: "Reunião não encontrada."])
        }

        guard settings.hasAIConfigured else {
            return toJSONString([
                "status": "ai_not_configured_in_muesli",
                "message": "Nenhum provedor de IA está configurado no aplicativo Muesli. Você pode gerar a ata com as instruções do próprio assistente e salvá-la chamando a ferramenta 'set_enhanced_notes(id: \"\(meeting.id.uuidString)\", markdown: \"...\")'."
            ])
        }

        let enhancer = Enhancer(settings: settings)
        let generated = try await enhancer.enhance(meeting: meeting)
        store.setEnhanced(meeting.id, markdown: generated)

        return toJSONString([
            "message": "Ata aprimorada gerada e salva com sucesso.",
            "id": meeting.id.uuidString,
            "title": meeting.title,
            "enhanced_notes": generated
        ])
    }

    private func executeDeleteMeeting(args: [String: AnyCodable]) throws -> String {
        guard let idStr = args["id"]?.stringValue,
              let meeting = findMeeting(by: idStr) else {
            throw NSError(domain: "MuesliMCP", code: 404, userInfo: [NSLocalizedDescriptionKey: "Reunião não encontrada."])
        }

        let title = meeting.title
        store.delete(meeting)

        return toJSONString([
            "message": "Reunião '\(title)' movida para a Lixeira do macOS com sucesso."
        ])
    }

    private func executeListCategories() throws -> String {
        let items: [[String: Any]] = store.categories.map { cat in
            let count = store.meetings.filter { $0.categoryID == cat.id }.count
            return [
                "id": cat.id.uuidString,
                "name": cat.name,
                "meeting_count": count
            ]
        }
        return toJSONString(["categories": items])
    }

    private func executeCreateCategory(args: [String: AnyCodable]) throws -> String {
        guard let name = args["name"]?.stringValue?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw NSError(domain: "MuesliMCP", code: 400, userInfo: [NSLocalizedDescriptionKey: "O campo 'name' é obrigatório."])
        }
        guard let cat = store.createCategory(name: name) else {
            throw NSError(domain: "MuesliMCP", code: 409, userInfo: [NSLocalizedDescriptionKey: "Categoria já existe ou nome inválido."])
        }
        return toJSONString([
            "message": "Categoria criada com sucesso.",
            "id": cat.id.uuidString,
            "name": cat.name
        ])
    }

    private func executeListTemplates() throws -> String {
        let items: [[String: Any]] = MeetingTemplate.all.map { t in
            [
                "id": t.id,
                "name": t.name,
                "description": t.description,
                "sections": t.sections
            ]
        }
        return toJSONString(["templates": items])
    }

    private func executeGetRecordingStatus() throws -> String {
        guard let recorder else {
            return toJSONString([
                "app_running": false,
                "is_recording": false,
                "message": "O controlador de gravação não está ativo nesta instância."
            ])
        }

        let isRec = recorder.isRecording
        var dict: [String: Any] = [
            "app_running": true,
            "is_recording": isRec,
            "mic_level": recorder.micLevel,
            "system_level": recorder.sysLevel,
            "pending_chunks": recorder.pendingChunks
        ]

        if isRec, let meetingID = recorder.recordingMeetingID, let meeting = store.meeting(meetingID) {
            dict["meeting_id"] = meeting.id.uuidString
            dict["meeting_title"] = meeting.title
            dict["meeting_duration"] = formatClock(meeting.durationSeconds)
            dict["transcript_segment_count"] = meeting.transcript.count
        }

        return toJSONString(dict)
    }

    private func executeStartRecording(args: [String: AnyCodable]) async throws -> String {
        guard let recorder else {
            throw NSError(domain: "MuesliMCP", code: 503, userInfo: [NSLocalizedDescriptionKey: "O aplicativo Muesli deve estar aberto para gravar áudio com microfone e sistema."])
        }

        if recorder.isRecording {
            throw NSError(domain: "MuesliMCP", code: 409, userInfo: [NSLocalizedDescriptionKey: "Já existe uma gravação em andamento no Muesli."])
        }

        let title = args["title"]?.stringValue
        let captureSys = args["capture_system_audio"]?.boolValue
        let catName = args["category"]?.stringValue

        var catID: UUID?
        if let catName = catName?.trimmingCharacters(in: .whitespaces), !catName.isEmpty {
            catID = store.categories.first(where: { $0.name.localizedCaseInsensitiveCompare(catName) == .orderedSame })?.id
        }

        let meeting = store.createMeeting(title: title, categoryID: catID)
        await recorder.start(meetingID: meeting.id, captureSystemAudio: captureSys)

        return toJSONString([
            "message": "Gravação iniciada com sucesso.",
            "meeting_id": meeting.id.uuidString,
            "title": meeting.title
        ])
    }

    private func executeStopRecording() async throws -> String {
        guard let recorder else {
            throw NSError(domain: "MuesliMCP", code: 503, userInfo: [NSLocalizedDescriptionKey: "O aplicativo Muesli deve estar aberto."])
        }

        guard recorder.isRecording else {
            return toJSONString([
                "message": "Nenhuma gravação estava em andamento."
            ])
        }

        let meetingID = recorder.recordingMeetingID
        await recorder.stop()

        var result: [String: Any] = [
            "message": "Gravação encerrada com sucesso."
        ]
        if let meetingID, let meeting = store.meeting(meetingID) {
            result["meeting_id"] = meeting.id.uuidString
            result["title"] = meeting.title
            result["duration_seconds"] = meeting.durationSeconds
            result["duration_formatted"] = formatClock(meeting.durationSeconds)
            result["transcript_segment_count"] = meeting.transcript.count
        }
        return toJSONString(result)
    }

    private func executeGetLiveTranscript() throws -> String {
        guard let recorder, recorder.isRecording, let meetingID = recorder.recordingMeetingID, let meeting = store.meeting(meetingID) else {
            throw NSError(domain: "MuesliMCP", code: 400, userInfo: [NSLocalizedDescriptionKey: "Nenhuma reunião está sendo gravada no momento."])
        }

        let segments = meeting.transcript.map { s in
            [
                "speaker": s.speaker.rawValue,
                "speaker_label": s.speaker.label,
                "start": s.start,
                "end": s.end,
                "time": "[\(formatClock(s.start)) - \(formatClock(s.end))]",
                "text": s.text
            ]
        }

        return toJSONString([
            "meeting_id": meeting.id.uuidString,
            "meeting_title": meeting.title,
            "segment_count": segments.count,
            "segments": segments,
            "formatted_transcript": MeetingStore.transcriptMarkdown(meeting)
        ])
    }

    // MARK: - Resources

    func allResources() -> [MCPResource] {
        [
            MCPResource(
                uri: "muesli://meetings",
                name: "Lista de Reuniões",
                description: "Visão geral em Markdown de todas as reuniões salvas no Muesli.",
                mimeType: "text/markdown"
            ),
            MCPResource(
                uri: "muesli://status",
                name: "Status do Muesli",
                description: "Estado do aplicativo Muesli, estatísticas de reuniões e gravação ativa.",
                mimeType: "text/markdown"
            )
        ]
    }

    private func handleResourceRead(id: JSONRPCID, params: AnyCodable?) -> JSONRPCResponse {
        guard let dict = params?.dictionaryValue,
              let uri = dict["uri"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams("Missing 'uri' in resources/read"))
        }

        if uri == "muesli://meetings" {
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .short

            var md = "# Reuniões do Muesli (\(store.meetings.count) total)\n\n"
            for m in store.meetings {
                let cat = m.categoryID.flatMap { id in store.categories.first(where: { $0.id == id })?.name }
                let catSuffix = cat != nil ? " [\(cat!)]" : ""
                md += "- **[\(m.title)](muesli://meetings/\(m.id.uuidString))**\(catSuffix) — \(df.string(from: m.createdAt)) (\(formatClock(m.durationSeconds)))\n"
            }
            let content = MCPResourceContent(uri: uri, mimeType: "text/markdown", text: md)
            let result = ["contents": [content]]
            return JSONRPCResponse(id: id, result: AnyCodable(try? AnyCodableWrapper.wrap(result)))
        }

        if uri == "muesli://status" {
            let isRec = recorder?.isRecording ?? false
            var md = "# Status do Muesli v\(AppVersion.current)\n\n"
            md += "- **Total de Reuniões:** \(store.meetings.count)\n"
            md += "- **Categorias:** \(store.categories.count)\n"
            md += "- **Gravação Ativa:** \(isRec ? "Sim" : "Não")\n"
            if isRec, let meetingID = recorder?.recordingMeetingID, let m = store.meeting(meetingID) {
                md += "- **Reunião Atual:** \(m.title) (\(formatClock(m.durationSeconds)))\n"
            }
            md += "- **Diretório:** `\(store.meetingsDir.path)`\n"

            let content = MCPResourceContent(uri: uri, mimeType: "text/markdown", text: md)
            let result = ["contents": [content]]
            return JSONRPCResponse(id: id, result: AnyCodable(try? AnyCodableWrapper.wrap(result)))
        }

        if uri.hasPrefix("muesli://meetings/") {
            let sub = String(uri.dropFirst("muesli://meetings/".count))
            if let meeting = findMeeting(by: sub) {
                let df = DateFormatter()
                df.dateStyle = .long
                df.timeStyle = .short

                var md = "# \(meeting.title)\n\n"
                md += "- **Data:** \(df.string(from: meeting.createdAt))\n"
                md += "- **Duração:** \(formatClock(meeting.durationSeconds))\n"
                if let catID = meeting.categoryID, let cat = store.categories.first(where: { $0.id == catID }) {
                    md += "- **Categoria:** \(cat.name)\n"
                }
                md += "- **Pasta:** `\(meeting.folderName)`\n\n"

                if !meeting.notesMD.isEmpty {
                    md += "## Anotações\n\n\(meeting.notesMD)\n\n"
                }
                if let enh = meeting.enhancedMD, !enh.isEmpty {
                    md += "## Ata Aprimorada (IA)\n\n\(enh)\n\n"
                }
                if meeting.hasTranscript {
                    md += "## Transcrição Completa\n\n"
                    md += MeetingStore.transcriptMarkdown(meeting)
                }

                let content = MCPResourceContent(uri: uri, mimeType: "text/markdown", text: md)
                let result = ["contents": [content]]
                return JSONRPCResponse(id: id, result: AnyCodable(try? AnyCodableWrapper.wrap(result)))
            }
        }

        return JSONRPCResponse(id: id, error: .invalidParams("URI de recurso desconhecido: \(uri)"))
    }

    // MARK: - Prompts

    func allPrompts() -> [MCPPrompt] {
        [
            MCPPrompt(
                name: "summarize_meeting",
                description: "Prepara uma instrução estruturada para gerar uma ata executiva detalhada de uma reunião específica.",
                arguments: [
                    MCPPromptArgument(name: "meeting_id", description: "ID ou título da reunião a ser resumida.", required: true)
                ]
            ),
            MCPPrompt(
                name: "extract_action_items",
                description: "Prepara uma instrução para extrair com precisão todas as tarefas, responsáveis e prazos decididos na reunião.",
                arguments: [
                    MCPPromptArgument(name: "meeting_id", description: "ID ou título da reunião.", required: true)
                ]
            ),
            MCPPrompt(
                name: "meeting_prep",
                description: "Prepara uma pauta e tópicos prioritários para uma reunião de acompanhamento com base na reunião anterior.",
                arguments: [
                    MCPPromptArgument(name: "meeting_id", description: "ID ou título da reunião de referência.", required: true)
                ]
            )
        ]
    }

    private func handlePromptGet(id: JSONRPCID, params: AnyCodable?) -> JSONRPCResponse {
        guard let dict = params?.dictionaryValue,
              let name = dict["name"]?.stringValue else {
            return JSONRPCResponse(id: id, error: .invalidParams("Missing 'name' in prompts/get"))
        }

        let args = dict["arguments"]?.dictionaryValue ?? [:]
        guard let meetingQuery = args["meeting_id"]?.stringValue,
              let meeting = findMeeting(by: meetingQuery) else {
            return JSONRPCResponse(id: id, error: .invalidParams("Reunião não encontrada."))
        }

        let transcript = meeting.hasTranscript ? MeetingStore.transcriptMarkdown(meeting) : "(Sem transcrição capturada)"
        let notes = !meeting.notesMD.isEmpty ? meeting.notesMD : "(Sem anotações manuais)"

        var promptText = ""
        switch name {
        case "summarize_meeting":
            promptText = """
            Por favor, elabore uma ata executiva clara e estruturada da seguinte reunião realizada no Muesli:

            # Reunião: \(meeting.title)
            Duração: \(formatClock(meeting.durationSeconds))

            ## Anotações Rápidas do Usuário:
            \(notes)

            ## Transcrição do Áudio:
            \(transcript)

            Estrutura desejada para a resposta:
            1. **Resumo Executivo** (visão geral em 2-3 parágrafos)
            2. **Principais Discussões e Decisões** (com contexto)
            3. **Ações e Encaminhamentos** (tabela com: Ação | Responsável | Prazo sugerido)
            """

        case "extract_action_items":
            promptText = """
            Com base na transcrição e notas da reunião abaixo, liste exaustivamente todas as ações, decisões, tarefas atribuídas e prazos mencionados.

            # Reunião: \(meeting.title)
            \(transcript)

            Apresente em formato de checklist Markdown com colunas:
            - [ ] **Tarefa** (descrição clara) — Responsável (se identificado) — Prazo (se citado)
            """

        case "meeting_prep":
            promptText = """
            Com base no histórico da reunião abaixo, elabore uma pauta de alinhamento e perguntas de acompanhamento para a próxima conversa com os mesmos participantes:

            # Reunião Anterior: \(meeting.title)
            \(notes)
            \(transcript)
            """

        default:
            return JSONRPCResponse(id: id, error: .methodNotFound("Unknown prompt '\(name)'"))
        }

        let message = MCPPromptMessage(role: "user", content: .text(promptText))
        let result: [String: Any] = [
            "description": "Prompt gerado para '\(meeting.title)'",
            "messages": [
                [
                    "role": message.role,
                    "content": [
                        "type": message.content.type,
                        "text": message.content.text ?? ""
                    ]
                ]
            ]
        ]

        return JSONRPCResponse(id: id, result: AnyCodable(result))
    }

    // MARK: - Utilities

    private func toJSONString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - AnyCodableWrapper

enum AnyCodableWrapper {
    static func wrap<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data, options: [])
    }
}
