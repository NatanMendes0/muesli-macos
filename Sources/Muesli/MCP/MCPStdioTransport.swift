import Foundation

/// Stdio transport for Model Context Protocol (MCP).
/// Reads JSON-RPC messages line-by-line on a background reader thread and dispatches them
/// to the MainActor event loop.
/// If the main Muesli GUI application is already running on localhost, it transparently
/// proxies requests to it so live recording control and GUI updates work seamlessly.
/// Otherwise, it operates headlessly directly against the local MeetingStore.
@MainActor
final class MCPStdioTransport {
    private let settings: AppSettings
    private var localService: MCPService?
    private var isConnectedToLocalServer: Bool = false

    init(settings: AppSettings? = nil) {
        self.settings = settings ?? AppSettings()
    }

    static func run() {
        var finished = false
        let transport = MCPStdioTransport()
        transport.checkLocalServerConnection()

        if !transport.isConnectedToLocalServer {
            let store = MeetingStore(baseDir: transport.settings.baseDir)
            transport.localService = MCPService(store: store, settings: transport.settings, recorder: nil)
        }

        DispatchQueue.global(qos: .userInteractive).async {
            while let line = readLine() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                guard let lineData = trimmed.data(using: .utf8) else { continue }

                Task { @MainActor in
                    await transport.handleLine(lineData)
                }
            }
            finished = true
        }

        while !finished {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func checkLocalServerConnection() {
        let port = settings.mcpPort > 0 ? settings.mcpPort : 4040
        guard let url = URL(string: "http://127.0.0.1:\(port)/status") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.25
        let token = settings.mcpAuthToken
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let sema = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var active = false

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            if error == nil, let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                lock.lock()
                active = true
                lock.unlock()
            }
            sema.signal()
        }
        task.resume()
        _ = sema.wait(timeout: .now() + 0.3)

        lock.lock()
        self.isConnectedToLocalServer = active
        lock.unlock()
    }

    func handleLine(_ lineData: Data) async {
        if isConnectedToLocalServer {
            await forwardToLocalServer(lineData)
        } else {
            await handleWithLocalService(lineData)
        }
    }

    private func forwardToLocalServer(_ lineData: Data) async {
        let port = settings.mcpPort > 0 ? settings.mcpPort : 4040
        guard let url = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            await handleWithLocalService(lineData)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let token = settings.mcpAuthToken
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = lineData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty {
                writeToStdout(data)
            } else {
                isConnectedToLocalServer = false
                await handleWithLocalService(lineData)
            }
        } catch {
            isConnectedToLocalServer = false
            await handleWithLocalService(lineData)
        }
    }

    private func handleWithLocalService(_ lineData: Data) async {
        if localService == nil {
            let store = MeetingStore(baseDir: self.settings.baseDir)
            self.localService = MCPService(store: store, settings: self.settings, recorder: nil)
        }

        guard let service = self.localService else { return }
        let respData = await service.handle(data: lineData)
        if !respData.isEmpty {
            writeToStdout(respData)
        }
    }

    private func writeToStdout(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A])) // '\n'
    }
}
