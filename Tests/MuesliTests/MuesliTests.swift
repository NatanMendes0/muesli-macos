import Testing
import Foundation
import AVFoundation
@testable import Muesli

@Suite struct WavWriterTests {
    @Test func headerAndPayload() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let samples: [Int16] = [0, 1000, -1000, 32767, -32768]
        try WavWriter.write(samples: samples, to: tmp)

        let data = try Data(contentsOf: tmp)
        #expect(data.count == 44 + samples.count * 2)
        #expect(String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF")
        #expect(String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE")

        let rate = data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16000)

        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: dataSize) == UInt32(samples.count * 2))

        // Payload round-trips exactly.
        let payload = data.subdata(in: 44..<data.count).withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self))
        }
        #expect(payload == samples)
    }

    @Test func streamingAppendPatchesHeader() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = try WavWriter(url: tmp)
        writer.append([1, 2, 3])
        writer.append([4, 5])
        writer.finalize()

        let data = try Data(contentsOf: tmp)
        let dataSize = data.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: dataSize) == 10)
    }
}

@Suite struct WhisperParsingTests {
    @Test func parsesSegmentsAndFiltersArtifacts() throws {
        let json = """
        {"transcription":[
          {"offsets":{"from":0,"to":2500},"text":" Hello there, this is a meeting."},
          {"offsets":{"from":2500,"to":4000},"text":" [BLANK_AUDIO]"},
          {"offsets":{"from":4000,"to":5000},"text":" (soft music)"},
          {"offsets":{"from":5000,"to":9000},"text":" We decided to ship on Friday."}
        ]}
        """
        let segments = try WhisperTranscriber.parse(json: Data(json.utf8))
        #expect(segments.count == 2)
        #expect(segments[0].text == "Hello there, this is a meeting.")
        #expect(segments[0].start == 0)
        #expect(segments[0].end == 2.5)
        #expect(segments[1].text == "We decided to ship on Friday.")
    }

    @Test func cleanDropsPhantoms() {
        #expect(WhisperTranscriber.clean(" Thank you. ") == "")
        #expect(WhisperTranscriber.clean("[Silence]") == "")
        #expect(WhisperTranscriber.clean(" ♪♪ ") == "")
        #expect(WhisperTranscriber.clean(" Real sentence here. ") == "Real sentence here.")
    }
}

@Suite struct TranscriptModelTests {
    @Test func coalescingGroupsBySpeakerAndGap() {
        let segments: [TranscriptSegment] = [
            .init(speaker: .me, start: 0, end: 2, text: "First."),
            .init(speaker: .me, start: 3, end: 5, text: "Second."),
            .init(speaker: .them, start: 6, end: 8, text: "Reply."),
            .init(speaker: .me, start: 30, end: 31, text: "Much later."),
        ]
        let groups = segments.coalesced()
        #expect(groups.count == 3)
        #expect(groups[0].text == "First. Second.")
        #expect(groups[0].speaker == .me)
        #expect(groups[1].speaker == .them)
        #expect(groups[2].text == "Much later.")
    }

    @Test func meetingRoundTripsThroughJSON() throws {
        // Whole-second dates: ISO8601 encoding has no sub-second precision.
        var meeting = Meeting(title: "Roundtrip", createdAt: Date(timeIntervalSince1970: 1_755_000_000), folderName: "rt")
        meeting.transcript = [.init(speaker: .them, start: 1.5, end: 3.25, text: "hi")]
        meeting.chat = [.init(role: "user", text: "question?", date: Date(timeIntervalSince1970: 1_755_000_100))]
        meeting.notesMD = "- note"
        meeting.enhancedMD = "# Done"

        let data = try JSONEncoder.muesli.encode(meeting)
        let back = try JSONDecoder.muesli.decode(Meeting.self, from: data)
        #expect(back == meeting)
    }

    @Test func clockFormatting() {
        #expect(formatClock(0) == "0:00")
        #expect(formatClock(65) == "1:05")
        #expect(formatClock(3671) == "1:01:11")
    }
}

@Suite struct AudioMathTests {
    @Test func rmsAndSilenceGate() {
        let silence = [Int16](repeating: 0, count: 16000)
        #expect(AudioMath.rms(silence) == 0)
        #expect(AudioMath.trailingQuiet(silence))

        let loud = [Int16](repeating: 8000, count: 16000)
        #expect(AudioMath.rms(loud) == 8000)
        #expect(!AudioMath.trailingQuiet(loud))
    }
}

@Suite struct MultiProviderAndExportTests {
    @Test func stripThinkAndCleanTitle() {
        let raw = "<think>analisando transcrição\npasso 2</think>\nAlinhamento Projeto Spectrum 3D"
        #expect(Enhancer.stripThink(raw) == "Alinhamento Projeto Spectrum 3D")
        #expect(Enhancer.cleanSuggestedTitle("Título: \"# Planejamento Q4!\"") == "Planejamento Q4!")
        #expect(Enhancer.stripThink("<think>sem fechar") == "")
    }

    @Test func keyRotatorRoundRobinAndCooldown() {
        let keys = ["k1", "k2", "k3"]
        let pool = "test_pool_\(UUID().uuidString)"
        let first = KeyRotator.shared.orderedKeys(pool: pool, keys: keys)
        #expect(first == ["k1", "k2", "k3"])

        KeyRotator.shared.markSuccess(pool: pool, key: "k1", allKeys: keys)
        let second = KeyRotator.shared.orderedKeys(pool: pool, keys: keys)
        #expect(second == ["k2", "k3", "k1"])

        KeyRotator.shared.markFailure(pool: pool, key: "k2", statusCode: 429)
        let third = KeyRotator.shared.orderedKeys(pool: pool, keys: keys)
        #expect(third.first == "k3")
        #expect(third.last == "k2")
    }

    @Test func copilotPromptAndObsidianMarkdown() {
        var m = Meeting(title: "Reunião SESI", createdAt: Date(timeIntervalSince1970: 1_755_000_000), durationSeconds: 125, folderName: "sesi")
        m.notesMD = "- revisar API"
        m.enhancedMD = "## Resumo Executivo\n- Tudo aprovado."
        m.transcript = [.init(speaker: .me, start: 10, end: 15, text: "Vamos publicar hoje.")]

        let prompt = Enhancer.buildCopilotPrompt(meeting: m)
        #expect(prompt.contains("| Ação / Tarefa | Responsável | Prazo / Momento |"))
        #expect(prompt.contains("Reunião SESI"))
        #expect(prompt.contains("Vamos publicar hoje."))

        let md = Enhancer.buildObsidianMarkdown(meeting: m, includeTranscript: true)
        #expect(md.contains("tipo: reuniao"))
        #expect(md.contains("# 📋 Reunião SESI"))
        #expect(md.contains("## 📌 Resumo & Pontos Chave"))
        #expect(md.contains("## 💬 Transcrição Completa"))
    }

    @Test func legacyMeetingJSONDecodesWithoutIsManualTitle() throws {
        let legacyJSON = """
        {"id":"11111111-1111-1111-1111-111111111111","title":"Antiga","createdAt":"2026-01-01T10:00:00Z","durationSeconds":30,"templateID":"auto","notesMD":"ok","transcript":[],"chat":[],"folderName":"old"}
        """
        let decoded = try JSONDecoder.muesli.decode(Meeting.self, from: Data(legacyJSON.utf8))
        #expect(decoded.title == "Antiga")
        #expect(decoded.isManualTitle == false)
        #expect(decoded.categoryID == nil)
    }

    @Test func updateVersionComparison() {
        #expect(UpdateChecker.isNewerVersion("v1.2.0", than: "1.1.0"))
        #expect(UpdateChecker.isNewerVersion("1.1.1", than: "1.1.0"))
        #expect(!UpdateChecker.isNewerVersion("v1.1.0", than: "1.1.0"))
        #expect(!UpdateChecker.isNewerVersion("v1.0.0", than: "1.1.0"))
    }

    @Test func cloudSTTParsesSegmentsAndTextFallback() {
        let verbose = """
        {"segments":[{"start":0.0,"end":2.4,"text":" Olá pessoal."},{"start":2.4,"end":3.1,"text":" [BLANK_AUDIO]"}]}
        """
        let segs = CloudTranscriber.parseCloudJSON(Data(verbose.utf8), fallbackDuration: 5)
        #expect(segs.count == 1)
        #expect(segs[0].text == "Olá pessoal.")
        #expect(segs[0].end == 2.4)

        let simple = #"{"text":" Apenas texto simples. "}"#
        let segs2 = CloudTranscriber.parseCloudJSON(Data(simple.utf8), fallbackDuration: 8)
        #expect(segs2.count == 1)
        #expect(segs2[0].text == "Apenas texto simples.")
        #expect(segs2[0].end == 8)
    }

    @Test func audioMathSubWindowSpeechGate() {
        var mostlyQuiet = [Int16](repeating: 0, count: 16000 * 10)
        // 1 second of speech at second 4 inside 10s of silence
        for i in (16000 * 4)..<(16000 * 5) {
            mostlyQuiet[i] = 1200
        }
        #expect(AudioMath.hasSpeech(mostlyQuiet, sampleRate: 16000))
        let pureSilence = [Int16](repeating: 0, count: 16000 * 10)
        #expect(!AudioMath.hasSpeech(pureSilence, sampleRate: 16000))
    }

    @Test func extractsOpenAIStandardAndSSEFallback() {
        let std = #"{"choices":[{"message":{"content":"Conexão OK"}}]}"#
        #expect(Enhancer.extractOpenAIStyleContent(from: Data(std.utf8)) == "Conexão OK")

        let sse = """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"reasoning_content":"pensando..."}}]}

        data: {"choices":[{"delta":{"content":"Conexão"}}]}

        data: {"choices":[{"delta":{"content":" OK"}}]}

        data: [DONE]
        """
        #expect(Enhancer.extractOpenAIStyleContent(from: Data(sse.utf8)) == "Conexão OK")
    }
}

@Suite struct CategoryAndPrivacyTests {
    @MainActor
    @Test func categoriesOrganizeMeetingsAndDeletingCategoryUnassignsThem() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-categories-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let store = MeetingStore(baseDir: base)
        let category = try #require(store.createCategory(name: "Projeto 1"))
        #expect(store.createCategory(name: "  ") == nil)
        #expect(store.createCategory(name: "projeto 1") == nil)
        let meeting = store.createMeeting(title: "Alinhamento", categoryID: category.id)

        #expect(store.meeting(meeting.id)?.categoryID == category.id)
        let reloaded = MeetingStore(baseDir: base)
        #expect(reloaded.categories.contains(category))
        #expect(reloaded.meeting(meeting.id)?.categoryID == category.id)

        store.deleteCategory(category.id)
        #expect(store.meeting(meeting.id)?.categoryID == nil)
        let afterDelete = MeetingStore(baseDir: base)
        #expect(afterDelete.categories.isEmpty)
        #expect(afterDelete.meeting(meeting.id)?.categoryID == nil)
    }

    @Test func privacyNoticeMatchesSelectedTranscriptionEngine() {
        let local = RecordingPrivacyNotice.text(sttEngine: .local, cloudFallback: false,
            systemAudio: true, automaticEnhancement: false, aiProvider: nil)
        #expect(local.contains("localmente"))
        #expect(local.contains("sem vídeo"))

        let cloud = RecordingPrivacyNotice.text(sttEngine: .groq, cloudFallback: false,
            systemAudio: true, automaticEnhancement: false, aiProvider: nil)
        #expect(cloud.contains("Groq"))
        #expect(cloud.contains("enviados"))

        let noCloudKey = RecordingPrivacyNotice.text(sttEngine: .groq, cloudFallback: true,
            cloudSTTConfigured: false, systemAudio: true, automaticEnhancement: false, aiProvider: nil)
        #expect(noCloudKey.contains("o áudio não será enviado a um provedor"))

        let fallback = RecordingPrivacyNotice.text(sttEngine: .openrouter, cloudFallback: true,
            systemAudio: true, automaticEnhancement: true, aiProvider: .ollama)
        #expect(fallback.contains("Whisper local será usado como reserva"))
        #expect(fallback.contains("Ollama local"))

        let cloudAI = RecordingPrivacyNotice.text(sttEngine: .local, cloudFallback: false,
            systemAudio: false, automaticEnhancement: true, aiProvider: .groq)
        #expect(cloudAI.contains("provedor de IA (Groq"))

        let localAI = RecordingPrivacyNotice.text(sttEngine: .local, cloudFallback: false,
            systemAudio: false, automaticEnhancement: true, aiProvider: .openai, aiProviderIsLocal: true)
        #expect(localAI.contains("endpoint local de IA"))
    }
}

@Suite struct CategoryCollapseTests {
    @Test func collapsePreferencesPersistMultipleCategoryIDsAndToggleIndividually() {
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let raw = CollapsedCategoryPreferences.encode([firstID, secondID])
        let collapsed = CollapsedCategoryPreferences.toggle(firstID, in: raw)

        #expect(CollapsedCategoryPreferences.decode(raw) == [firstID, secondID])
        #expect(CollapsedCategoryPreferences.decode(collapsed) == [secondID])
        #expect(CollapsedCategoryPreferences.decode(CollapsedCategoryPreferences.toggle(firstID, in: collapsed)) == [firstID, secondID])
    }
}

@Suite struct StreamConverterTests {
    @Test func convertsMultiChannelDiscreteVoiceProcessingFormatToNonSilentMono() throws {
        let tag = kAudioChannelLayoutTag_DiscreteInOrder | 5
        let layout = AVAudioChannelLayout(layoutTag: tag)!
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            interleaved: false,
            channelLayout: layout
        )
        let frameCount: AVAudioFrameCount = 4800
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount

        let floatData = try #require(buffer.floatChannelData)
        for ch in 0..<5 {
            for i in 0..<Int(frameCount) {
                floatData[ch][i] = sinf(2.0 * .pi * 440.0 * Float(i) / 48000.0) * 0.5
            }
        }

        let converter = StreamConverter()
        let out = converter.convert(buffer)
        let peak = out.map { Int($0.magnitude) }.max() ?? 0
        #expect(out.count > 1000)
        #expect(peak > 10000)
    }
}

@Suite struct KeychainBundleTests {
    @Test func bundleRoundTripsAndNormalizesKeys() throws {
        let encoded = try #require(KeychainHelper.encodeKeyBundle([
            "groq": [" gsk_1 ", "gsk_1", "", "gsk_2"],
            "openai": ["   "],
            "sttOpenRouter": [" sk-or-1 "],
        ]))
        let decoded = try #require(KeychainHelper.decodeKeyBundle(encoded))
        #expect(decoded["groq"] == ["gsk_1", "gsk_2"])
        #expect(decoded["openai"] == nil)
        #expect(decoded["sttOpenRouter"] == ["sk-or-1"])
    }
}

@Suite struct MCPServerTests {
    @Test func jsonRPCSpecRoundTrip() throws {
        // ID variants
        let idInt = JSONRPCID.int(10)
        let idStr = JSONRPCID.string("req-1")
        let encInt = try JSONEncoder().encode(idInt)
        let encStr = try JSONEncoder().encode(idStr)
        #expect(try JSONDecoder().decode(JSONRPCID.self, from: encInt) == .int(10))
        #expect(try JSONDecoder().decode(JSONRPCID.self, from: encStr) == .string("req-1"))

        // Request with params
        let req = JSONRPCRequest(
            id: .int(1),
            method: "tools/call",
            params: AnyCodable([
                "name": AnyCodable("list_meetings"),
                "arguments": AnyCodable(["limit": AnyCodable(10)])
            ])
        )
        let reqData = try JSONEncoder().encode(req)
        let decodedReq = try JSONDecoder().decode(JSONRPCRequest.self, from: reqData)
        #expect(decodedReq.method == "tools/call")
        #expect(decodedReq.id == .int(1))
        #expect(decodedReq.params?.dictionaryValue?["name"]?.stringValue == "list_meetings")

        // Response with error
        let errResp = JSONRPCResponse(id: .string("abc"), error: .methodNotFound("test"))
        let errData = try JSONEncoder().encode(errResp)
        let decodedErr = try JSONDecoder().decode(JSONRPCResponse.self, from: errData)
        #expect(decodedErr.error?.code == -32601)
    }

    @Test func mcpServiceToolAndResourceLifecycle() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-mcp-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settings = await MainActor.run { AppSettings() }
        let store = await MainActor.run { MeetingStore(baseDir: tmpDir) }
        let service = await MainActor.run { MCPService(store: store, settings: settings, recorder: nil) }

        // 1. Initialize
        let initReq = JSONRPCRequest(
            id: .int(1),
            method: "initialize",
            params: AnyCodable(["protocolVersion": AnyCodable("2024-11-05")])
        )
        let initResp = await service.handle(request: initReq)
        let initDict = try #require(initResp?.result?.dictionaryValue)
        #expect(initDict["protocolVersion"]?.stringValue == "2024-11-05")

        // 2. Tools list
        let toolsReq = JSONRPCRequest(id: .int(2), method: "tools/list")
        let toolsResp = await service.handle(request: toolsReq)
        let toolsDict = try #require(toolsResp?.result?.dictionaryValue)
        let toolsList = try #require(toolsDict["tools"]?.arrayValue)
        let toolNames = Set(toolsList.compactMap { $0.dictionaryValue?["name"]?.stringValue })
        #expect(toolNames.contains("list_meetings"))
        #expect(toolNames.contains("get_meeting"))
        #expect(toolNames.contains("search_meetings"))
        #expect(toolNames.contains("create_meeting"))
        #expect(toolNames.contains("update_notes"))
        #expect(toolNames.contains("set_enhanced_notes"))
        #expect(toolNames.contains("get_recording_status"))

        // 3. Create meeting tool call
        let createReq = JSONRPCRequest(
            id: .int(3),
            method: "tools/call",
            params: AnyCodable([
                "name": AnyCodable("create_meeting"),
                "arguments": AnyCodable([
                    "title": AnyCodable("Reunião MCP"),
                    "notes": AnyCodable("- Decidimos usar MCP"),
                    "category": AnyCodable("Engenharia")
                ])
            ])
        )
        let createResp = await service.handle(request: createReq)
        let createContent = try #require(createResp?.result?.dictionaryValue?["content"]?.arrayValue)
        let createText = try #require(createContent.first?.dictionaryValue?["text"]?.stringValue)
        #expect(createText.contains("Reunião MCP"))

        // 4. List meetings
        let listReq = JSONRPCRequest(
            id: .int(4),
            method: "tools/call",
            params: AnyCodable([
                "name": AnyCodable("list_meetings"),
                "arguments": AnyCodable(["limit": AnyCodable(10)])
            ])
        )
        let listResp = await service.handle(request: listReq)
        let listText = try #require(listResp?.result?.dictionaryValue?["content"]?.arrayValue?.first?.dictionaryValue?["text"]?.stringValue)
        #expect(listText.contains("Reunião MCP"))
        #expect(listText.contains("Engenharia"))

        // 5. Search meetings
        let searchReq = JSONRPCRequest(
            id: .int(5),
            method: "tools/call",
            params: AnyCodable([
                "name": AnyCodable("search_meetings"),
                "arguments": AnyCodable(["query": AnyCodable("usar MCP")])
            ])
        )
        let searchResp = await service.handle(request: searchReq)
        let searchText = try #require(searchResp?.result?.dictionaryValue?["content"]?.arrayValue?.first?.dictionaryValue?["text"]?.stringValue)
        #expect(searchText.contains("Reunião MCP"))

        // 6. Resources read
        let resReq = JSONRPCRequest(
            id: .int(6),
            method: "resources/read",
            params: AnyCodable(["uri": AnyCodable("muesli://meetings")])
        )
        let resResp = await service.handle(request: resReq)
        let resContents = try #require(resResp?.result?.dictionaryValue?["contents"]?.arrayValue)
        let resText = try #require(resContents.first?.dictionaryValue?["text"]?.stringValue)
        #expect(resText.contains("Reunião MCP"))

        // 7. Prompts get
        let promptReq = JSONRPCRequest(
            id: .int(7),
            method: "prompts/get",
            params: AnyCodable([
                "name": AnyCodable("summarize_meeting"),
                "arguments": AnyCodable(["meeting_id": AnyCodable("Reunião MCP")])
            ])
        )
        let promptResp = await service.handle(request: promptReq)
        let messages = try #require(promptResp?.result?.dictionaryValue?["messages"]?.arrayValue)
        let promptBody = try #require(messages.first?.dictionaryValue?["content"]?.dictionaryValue?["text"]?.stringValue)
        #expect(promptBody.contains("Reunião: Reunião MCP"))
    }

    @Test func mcpHTTPServerEndpointsAndAuth() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muesli-http-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let settings = await MainActor.run { AppSettings() }
        let store = await MainActor.run { MeetingStore(baseDir: tmpDir) }
        let service = await MainActor.run { MCPService(store: store, settings: settings, recorder: nil) }

        // Create a meeting first
        _ = await MainActor.run {
            store.createMeeting(title: "Demo Server Test")
        }

        let port: UInt16 = 4059
        let server = MCPHTTPServer(
            port: port,
            allowRemote: false,
            requireAuth: true,
            authToken: "test-auth-token-999",
            service: service
        )
        try server.start()
        defer { server.stop() }

        // Give listener a moment to bind
        try await Task.sleep(nanoseconds: 200_000_000)

        let session = URLSession.shared

        // 1. GET /status (allowed without auth for health checks)
        let statusURL = URL(string: "http://127.0.0.1:\(port)/status")!
        let (statusData, statusResp) = try await session.data(from: statusURL)
        let statusHTTP = try #require(statusResp as? HTTPURLResponse)
        #expect(statusHTTP.statusCode == 200)
        let statusJSON = try #require(try JSONSerialization.jsonObject(with: statusData) as? [String: Any])
        #expect(statusJSON["app"] as? String == "Muesli")
        #expect(statusJSON["status"] as? String == "ok")

        // 2. GET /openapi.json (public documentation)
        let openapiURL = URL(string: "http://127.0.0.1:\(port)/openapi.json")!
        let (openapiData, openapiResp) = try await session.data(from: openapiURL)
        let openapiHTTP = try #require(openapiResp as? HTTPURLResponse)
        #expect(openapiHTTP.statusCode == 200)
        let openapiJSON = try #require(try JSONSerialization.jsonObject(with: openapiData) as? [String: Any])
        #expect(openapiJSON["openapi"] as? String == "3.0.0")

        // 3. POST /mcp without Auth -> 401 Unauthorized
        let mcpURL = URL(string: "http://127.0.0.1:\(port)/mcp")!
        var unauthReq = URLRequest(url: mcpURL)
        unauthReq.httpMethod = "POST"
        unauthReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthReq.httpBody = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.data(using: .utf8)
        let (_, unauthResp) = try await session.data(for: unauthReq)
        let unauthHTTP = try #require(unauthResp as? HTTPURLResponse)
        #expect(unauthHTTP.statusCode == 401)

        // 4. POST /mcp with Bearer Auth -> 200 OK
        var authReq = unauthReq
        authReq.setValue("Bearer test-auth-token-999", forHTTPHeaderField: "Authorization")
        let (authData, authResp) = try await session.data(for: authReq)
        let authHTTP = try #require(authResp as? HTTPURLResponse)
        #expect(authHTTP.statusCode == 200)
        let authJSON = try #require(try JSONSerialization.jsonObject(with: authData) as? [String: Any])
        #expect(authJSON["jsonrpc"] as? String == "2.0")
        #expect(authJSON["result"] != nil)

        // 5. GET /api/meetings with Bearer Auth -> 200 OK with meeting list
        var restReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/meetings")!)
        restReq.setValue("Bearer test-auth-token-999", forHTTPHeaderField: "Authorization")
        let (restData, restResp) = try await session.data(for: restReq)
        let restHTTP = try #require(restResp as? HTTPURLResponse)
        #expect(restHTTP.statusCode == 200)
        let restJSON = try #require(try JSONSerialization.jsonObject(with: restData) as? [String: Any])
        let meetings = try #require(restJSON["meetings"] as? [[String: Any]])
        #expect(!meetings.isEmpty)
        #expect(meetings.first?["title"] as? String == "Demo Server Test")
    }
}
