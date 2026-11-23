import Foundation
import SwiftUI
import Combine

/// Manages the in-app HTTP/SSE MCP server lifecycle and publishes live status to the UI.
@MainActor
final class MCPServerManager: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var currentPort: Int = 4040
    @Published private(set) var clientCount: Int = 0
    @Published private(set) var lastError: String? = nil
    @Published private(set) var serverURL: String = "http://127.0.0.1:4040"

    private let store: MeetingStore
    private let settings: AppSettings
    private weak var recorder: RecordingController?
    private var server: MCPHTTPServer?
    private var service: MCPService?

    init(store: MeetingStore, settings: AppSettings, recorder: RecordingController? = nil) {
        self.store = store
        self.settings = settings
        self.recorder = recorder
        self.currentPort = settings.mcpPort > 0 ? settings.mcpPort : 4040
        self.serverURL = "http://127.0.0.1:\(currentPort)"

        if settings.mcpEnabled {
            start()
        }
    }

    func start() {
        stop()
        lastError = nil

        guard settings.mcpEnabled else { return }

        let port = settings.mcpPort > 0 ? settings.mcpPort : 4040
        currentPort = port
        serverURL = "http://127.0.0.1:\(port)"

        let svc = MCPService(store: store, settings: settings, recorder: recorder)
        self.service = svc

        let srv = MCPHTTPServer(
            port: UInt16(port),
            allowRemote: settings.mcpAllowRemote,
            requireAuth: settings.mcpRequireAuth,
            authToken: settings.mcpAuthToken,
            service: svc
        )

        srv.onClientCountChange = { [weak self] count in
            Task { @MainActor [weak self] in
                self?.clientCount = count
            }
        }

        do {
            try srv.start()
            self.server = srv
            self.isRunning = true
        } catch {
            self.lastError = error.localizedDescription
            self.isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        service = nil
        isRunning = false
        clientCount = 0
    }

    func restart() {
        stop()
        start()
    }

    func generateNewToken() -> String {
        let newToken = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        settings.mcpAuthToken = newToken
        if isRunning {
            restart()
        }
        return newToken
    }
}
