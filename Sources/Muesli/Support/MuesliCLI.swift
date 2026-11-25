import Foundation

/// Hidden CLI entry points used for headless verification:
///
///     Muesli --mcp                   run stdio Model Context Protocol (MCP) server
///     Muesli --mcp-serve [--port N]  run headless HTTP/SSE MCP server
///     Muesli --mcp-test              run automated tests on MCP protocol
///     Muesli --selftest              storage round-trip, wav writer, parser checks
///     Muesli --transcribe file.wav   run the app's whisper path on a file
///     Muesli --enhance-test          ping the configured AI provider (key from env or keychain)
///     Muesli --mictest [log]         capture 3 s with and without echo cancellation, report levels
///     Muesli --version
@MainActor
enum MuesliCLI {
    static func runIfNeeded() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--version") {
            print("Muesli \(AppVersion.current)")
            return true
        }
        if args.contains("--mcp") {
            MCPStdioTransport.run()
            return true
        }
        if args.contains("--mcp-serve") {
            let portIndex = args.firstIndex(of: "--port")
            let port = portIndex.flatMap { args.count > $0 + 1 ? Int(args[$0 + 1]) : nil } ?? 4040
            return runMCPServer(port: port)
        }
        if args.contains("--mcp-test") {
            return mcpTest()
        }
        if args.contains("--selftest") {
            return selftest()
        }
        if let i = args.firstIndex(of: "--transcribe"), args.count > i + 1 {
            return transcribe(path: args[i + 1])
        }
        if args.contains("--enhance-test") {
            return enhanceTest()
        }
        if let i = args.firstIndex(of: "--mictest") {
            let log = args.count > i + 1 && !args[i + 1].hasPrefix("--")
                ? args[i + 1] : "/tmp/muesli-mictest.log"
            return micTest(logPath: log)
        }
        return false
    }

    // MARK: - Mic diagnostic

    /// Runs the app's real mic path twice (echo cancellation on, then off) and
    /// reports buffer counts and peak levels. Designed to run inside the .app
    /// bundle so it uses the app's own microphone permission.
    private static func micTest(logPath: String) -> Bool {
        var lines: [String] = ["Muesli mictest"]
        var finished = false

        Task { @MainActor in
            for vp in [true, false] {
                let mic = MicRecorder()
                let lock = NSLock()
                var bufferCount = 0
                var sampleCount = 0
                var peak = 0
                mic.onSamples = { samples in
                    lock.lock()
                    bufferCount += 1
                    sampleCount += samples.count
                    for v in samples {
                        let magnitude = Int(v.magnitude)
                        if magnitude > peak { peak = magnitude }
                    }
                    lock.unlock()
                }
                mic.onNotice = { note in
                    lock.lock(); lines.append("  notice: \(note)"); lock.unlock()
                }
                do {
                    try await mic.start(echoCancellation: vp)
                    try? await Task.sleep(nanoseconds: 3_500_000_000)
                    let vpActive = mic.voiceProcessingActive
                    mic.stop()
                    lock.lock()
                    lines.append("echoCancel=\(vp): buffers=\(bufferCount) samples=\(sampleCount) peak=\(peak) vpStillActive=\(vpActive)")
                    lock.unlock()
                } catch {
                    lines.append("echoCancel=\(vp): START ERROR \(error.localizedDescription)")
                }
            }
            finished = true
        }

        // Keep the main run loop alive so main-queue hops (watchdog restarts) run.
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let output = lines.joined(separator: "\n") + "\n"
        try? output.write(toFile: logPath, atomically: true, encoding: .utf8)
        print(output)
        return true
    }

    // MARK: - Self test

    private static func selftest() -> Bool {
        var failures: [String] = []

        // 1. WAV round trip: header must describe the payload exactly.
        do {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("muesli-selftest.wav")
            let samples = (0..<16000).map { Int16(truncatingIfNeeded: $0 &* 7) }
            try WavWriter.write(samples: samples, to: tmp)
            let data = try Data(contentsOf: tmp)
            if data.count != 44 + 32000 { failures.append("wav size \(data.count) != 32044") }
            let rate = data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            if UInt32(littleEndian: rate) != 16000 { failures.append("wav rate wrong") }
            try FileManager.default.removeItem(at: tmp)
        } catch {
            failures.append("wav: \(error)")
        }

        // 2. Meeting JSON round trip. (Whole-second dates: ISO8601 has no sub-second precision.)
        do {
            var m = Meeting(title: "Test", createdAt: Date(timeIntervalSince1970: 1_755_000_000), folderName: "t")
            m.transcript = [TranscriptSegment(speaker: .me, start: 1, end: 2, text: "hello")]
            m.chat = [ChatMessage(role: "user", text: "hi", date: Date(timeIntervalSince1970: 1_755_000_100))]
            let data = try JSONEncoder.muesli.encode(m)
            let back = try JSONDecoder.muesli.decode(Meeting.self, from: data)
            if back != m { failures.append("meeting codable mismatch") }
        } catch {
            failures.append("codable: \(error)")
        }

        // 3. Whisper JSON parsing.
        do {
            let sample = #"{"transcription":[{"offsets":{"from":0,"to":2500},"text":" Hello world."},{"offsets":{"from":2500,"to":3000},"text":" [BLANK_AUDIO]"}]}"#
            let segs = try WhisperTranscriber.parse(json: Data(sample.utf8))
            if segs.count != 1 || segs[0].text != "Hello world." || segs[0].end != 2.5 {
                failures.append("whisper parse wrong: \(segs)")
            }
        } catch {
            failures.append("whisper parse: \(error)")
        }

        // 4. Transcript coalescing.
        let segs: [TranscriptSegment] = [
            .init(speaker: .me, start: 0, end: 2, text: "One."),
            .init(speaker: .me, start: 3, end: 5, text: "Two."),
            .init(speaker: .them, start: 6, end: 8, text: "Three."),
        ]
        let groups = segs.coalesced()
        if groups.count != 2 || groups[0].text != "One. Two." {
            failures.append("coalesce wrong: \(groups)")
        }

        if failures.isEmpty {
            print("SELFTEST OK")
            return true
        } else {
            print("SELFTEST FAILED:\n" + failures.joined(separator: "\n"))
            exit(1)
        }
    }

    // MARK: - Transcribe a file through the app's own pipeline code

    private static func transcribe(path: String) -> Bool {
        var finished = false
        var exitCode: Int32 = 0
        Task { @MainActor in
            do {
                let settings = AppSettings()
                let transcriber = try WhisperTranscriber(settings: settings)
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let segments = try await transcriber.transcribe(wav: url, timeout: 600)
                for s in segments {
                    print("[\(formatClock(s.start))-\(formatClock(s.end))] \(s.text)")
                }
                if segments.isEmpty { print("(no speech detected)") }
            } catch {
                print("ERROR: \(error.localizedDescription)")
                exitCode = 1
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if exitCode != 0 { exit(exitCode) }
        return true
    }

    // MARK: - Enhance connectivity test

    private static func enhanceTest() -> Bool {
        var finished = false
        var exitCode: Int32 = 0
        Task { @MainActor in
            let settings = AppSettings()
            if let envKey = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !envKey.isEmpty {
                settings.groqKey = envKey
            }
            if let envKey = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !envKey.isEmpty {
                settings.geminiKey = envKey
            }
            if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
                settings.openAIKey = envKey
            }
            if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !envKey.isEmpty {
                settings.anthropicKey = envKey
            }
            do {
                let reply = try await Enhancer(settings: settings).ping()
                print("ENHANCE OK: \(reply)")
            } catch {
                print("ENHANCE ERROR: \(error.localizedDescription)")
                exitCode = 1
            }
            finished = true
        }
        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if exitCode != 0 { exit(exitCode) }
        return true
    }

    // MARK: - MCP Server (Headless)

    private static func runMCPServer(port: Int) -> Bool {
        var failure = false
        Task { @MainActor in
            let settings = AppSettings()
            settings.mcpPort = port
            let store = MeetingStore(baseDir: settings.baseDir)
            let service = MCPService(store: store, settings: settings, recorder: nil)
            let server = MCPHTTPServer(
                port: UInt16(port),
                allowRemote: settings.mcpAllowRemote,
                requireAuth: settings.mcpRequireAuth,
                authToken: settings.mcpAuthToken,
                service: service
            )
            do {
                try server.start()
                print("Muesli MCP Server listening on http://127.0.0.1:\(port)")
                print("  SSE stream:   http://127.0.0.1:\(port)/sse")
                print("  Direct MCP:   http://127.0.0.1:\(port)/mcp")
                print("  OpenAPI spec: http://127.0.0.1:\(port)/openapi.json")
            } catch {
                print("MCP SERVER ERROR: \(error.localizedDescription)")
                failure = true
            }
        }

        while !failure {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))
        }
        return true
    }

    // MARK: - MCP Protocol Self-Test

    private static func mcpTest() -> Bool {
        var failures: [String] = []
        let settings = AppSettings()
        let store = MeetingStore(baseDir: settings.baseDir)
        let service = MCPService(store: store, settings: settings, recorder: nil)

        // 1. Tool definitions check
        let tools = service.allTools()
        let toolNames = tools.map(\.name)
        let expected = ["list_meetings", "get_meeting", "search_meetings", "create_meeting", "get_recording_status", "start_recording", "stop_recording", "get_live_transcript"]
        for e in expected {
            if !toolNames.contains(e) { failures.append("missing tool: \(e)") }
        }

        // 2. Resource definitions check
        let resources = service.allResources()
        let uris = resources.map(\.uri)
        if !uris.contains("muesli://meetings") || !uris.contains("muesli://status") {
            failures.append("missing expected resources")
        }

        // 3. Prompt definitions check
        let prompts = service.allPrompts()
        let pNames = prompts.map(\.name)
        if !pNames.contains("summarize_meeting") {
            failures.append("missing prompt summarize_meeting")
        }

        // 4. JSON-RPC serialization & AnyCodable
        do {
            let req = JSONRPCRequest(id: .int(42), method: "ping", params: AnyCodable(["foo": AnyCodable("bar")]))
            let data = try JSONEncoder().encode(req)
            let back = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
            if back.method != "ping" || back.id != .int(42) || back.params?.dictionaryValue?["foo"]?.stringValue != "bar" {
                failures.append("JSONRPC serialization round-trip failed")
            }
        } catch {
            failures.append("JSONRPC serialization error: \(error)")
        }

        if failures.isEmpty {
            print("MCP TEST OK")
            return true
        } else {
            print("MCP TEST FAILED:\n" + failures.joined(separator: "\n"))
            exit(1)
        }
    }
}
