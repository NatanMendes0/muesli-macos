import Foundation
import SwiftUI

/// Orchestrates a recording: permissions → mic + system audio capture →
/// chunker → transcription pipeline → store. One recording at a time.
@MainActor
final class RecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording(meetingID: UUID, started: Date)
        case paused(meetingID: UUID, elapsed: TimeInterval)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var isChangingCapture = false
    @Published var micLevel: Float = 0
    @Published var sysLevel: Float = 0
    @Published var pendingChunks: Int = 0
    @Published var lastError: String?
    /// Set when system audio couldn't start but the mic is still recording.
    @Published var systemAudioWarning: String?
    /// Mic status worth showing (echo-cancel fallback, silent input device).
    @Published var micWarning: String?
    /// Meeting currently running AI enhancement (manual or auto on stop).
    @Published var enhancingMeetingID: UUID?
    /// Immediate toast banner message for UI feedback.
    @Published var toastMessage: String?

    private var toastTask: Task<Void, Never>?

    let store: MeetingStore
    let settings: AppSettings
    private(set) var pipeline: TranscriptionPipeline!

    private var session: RecordingSession?
    private var mic: MicRecorder?
    private var system: SystemAudioRecorder?
    private var captureSystemAudio = false

    static private(set) weak var shared: RecordingController?

    var isRecording: Bool {
        recordingMeetingID != nil
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    var recordingMeetingID: UUID? {
        switch state {
        case .recording(let id, _), .paused(let id, _): return id
        case .idle: return nil
        }
    }

    func elapsedRecordingTime(at date: Date = .now) -> TimeInterval {
        switch state {
        case .recording(_, let started): return max(0, date.timeIntervalSince(started))
        case .paused(_, let elapsed): return elapsed
        case .idle: return 0
        }
    }

    init(store: MeetingStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        RecordingController.shared = self

        pipeline = TranscriptionPipeline(
            settings: settings,
            onSegments: { meetingID, segments, replace in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if replace { self.store.clearTranscript(meetingID) }
                    self.store.appendSegments(meetingID, segments: segments)
                }
            },
            onPending: { count in
                Task { @MainActor [weak self] in self?.pendingChunks = count }
            },
            onError: { message in
                Task { @MainActor [weak self] in self?.lastError = message }
            }
        )
    }

    // MARK: - Recording controls

    /// Creates a meeting and starts recording into it.
    @discardableResult
    func startNewMeeting(captureSystemAudio: Bool? = nil, categoryID: UUID? = nil) async -> UUID? {
        guard !isRecording, !isChangingCapture else { return nil }
        let meeting = store.createMeeting(categoryID: categoryID)
        await start(meetingID: meeting.id, captureSystemAudio: captureSystemAudio)
        return meeting.id
    }

    func start(meetingID: UUID, captureSystemAudio: Bool? = nil) async {
        guard !isRecording, !isChangingCapture, let meeting = store.meeting(meetingID) else { return }
        isChangingCapture = true
        defer { isChangingCapture = false }

        lastError = nil
        systemAudioWarning = nil
        micWarning = nil

        guard await Permissions.ensureMicAccess() else {
            lastError = "O acesso ao microfone é necessário para gravar. Ative-o em Ajustes do Sistema → Privacidade e Segurança → Microfone."
            return
        }

        self.captureSystemAudio = captureSystemAudio ?? settings.captureSystemAudio
        let folder = store.folder(for: meeting)

        do {
            let session = try RecordingSession(
                meetingID: meeting.id,
                folder: folder,
                chunkSeconds: settings.effectiveChunkSeconds,
                captureSystem: self.captureSystemAudio
            )
            session.onChunk = { [pipeline] job in
                Task { await pipeline?.enqueue(job) }
            }
            session.onLevels = { [weak self] micLevel, sysLevel in
                Task { @MainActor in
                    guard let self, self.recordingMeetingID == meetingID, !self.isPaused else { return }
                    self.micLevel = micLevel
                    self.sysLevel = sysLevel
                }
            }
            self.session = session

            let captureID = UUID()
            session.acceptSamples(from: captureID)
            try await startCapture(in: session, captureID: captureID)
            state = .recording(meetingID: meeting.id, started: Date())
        } catch {
            await stopCapture()
            session = nil
            lastError = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    func togglePause() async {
        guard !isChangingCapture, let session else { return }
        isChangingCapture = true
        defer { isChangingCapture = false }

        switch state {
        case .recording(let meetingID, _):
            let elapsed = elapsedRecordingTime()
            session.pause()
            state = .paused(meetingID: meetingID, elapsed: elapsed)
            micLevel = 0
            sysLevel = 0
            await stopCapture()
        case .paused(let meetingID, let elapsed):
            lastError = nil
            systemAudioWarning = nil
            micWarning = nil
            let captureID = UUID()
            do {
                try await startCapture(in: session, captureID: captureID)
                session.acceptSamples(from: captureID)
                state = .recording(meetingID: meetingID, started: Date().addingTimeInterval(-elapsed))
            } catch {
                await stopCapture()
                lastError = "Não foi possível retomar a gravação: \(error.localizedDescription)"
            }
        case .idle:
            break
        }
    }

    func stop() async {
        guard !isChangingCapture, let meetingID = recordingMeetingID else { return }
        isChangingCapture = true
        defer { isChangingCapture = false }

        await stopCapture()
        let elapsed = elapsedRecordingTime()
        let duration = session?.finish() ?? elapsed
        store.setDuration(meetingID, seconds: max(duration, elapsed))
        session = nil
        state = .idle
        micLevel = 0
        sysLevel = 0

        if settings.autoEnhanceOnStop && settings.hasAIConfigured {
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Wait up to 90s for any final queued Whisper chunks to finish.
                for _ in 0..<180 {
                    if await self.pipeline.pendingCount == 0 { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                guard !self.isRecording,
                      let m = self.store.meeting(meetingID),
                      (m.hasTranscript || !m.notesMD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                else { return }
                await self.enhance(meetingID: meetingID, automatic: true)
            }
        }
    }

    func showToast(_ message: String, duration: Double = 3.0) {
        toastTask?.cancel()
        toastMessage = message
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    func enhance(meetingID: UUID, automatic: Bool = false) async {
        guard enhancingMeetingID == nil, let meeting = store.meeting(meetingID) else { return }
        guard settings.hasAIConfigured else {
            if !automatic {
                lastError = EnhanceError.notConfigured.localizedDescription
            }
            return
        }
        enhancingMeetingID = meetingID
        lastError = nil
        defer { enhancingMeetingID = nil }
        do {
            let enhancer = Enhancer(settings: settings)
            let md = try await enhancer.enhance(meeting: meeting)
            store.setEnhanced(meetingID, markdown: md)
            if let updated = store.meeting(meetingID), !updated.isManualTitle {
                let suggested = await enhancer.suggestTitle(meeting: updated, enhancedMD: md)
                if !suggested.isEmpty {
                    store.setAutoTitle(meetingID, title: suggested)
                }
            }
            showToast(automatic ? "Ata aprimorada e título atualizado automaticamente ✨" : "Ata aprimorada com sucesso ✨")
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Synchronous best-effort stop for app termination: finalizes WAV headers.
    nonisolated func emergencyStop() {
        Task { @MainActor in
            await self.stop()
        }
        // Give the file finalization a beat before the process exits.
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func startCapture(in session: RecordingSession, captureID: UUID) async throws {
        // Settle the mic before starting system audio so the timelines stay aligned.
        let mic = MicRecorder()
        mic.onSamples = { [weak session] in session?.appendMic($0, captureID: captureID) }
        mic.onNotice = { [weak self] message in
            Task { @MainActor in self?.micWarning = message }
        }
        mic.onVoiceProcessingFailed = { [weak self] in
            Task { @MainActor in self?.settings.vpKnownBad = true }
        }
        try await mic.start(echoCancellation: settings.echoCancellation && !settings.vpKnownBad)
        self.mic = mic

        if captureSystemAudio {
            let sys = SystemAudioRecorder()
            sys.onSamples = { [weak session] in session?.appendSystem($0, captureID: captureID) }
            sys.onStoppedWithError = { [weak self] error in
                Task { @MainActor in
                    self?.systemAudioWarning = "System audio stopped: \(error.localizedDescription)"
                }
            }
            do {
                try await sys.start()
                self.system = sys
            } catch {
                systemAudioWarning = (error as? SystemAudioError)?.errorDescription
                    ?? "System audio unavailable (\(error.localizedDescription)) — recording your mic only."
            }
        }
    }

    private func stopCapture() async {
        mic?.stop()
        await system?.stop()
        mic = nil
        system = nil
    }

    // MARK: - Retranscribe

    func retranscribe(meetingID: UUID) {
        guard let meeting = store.meeting(meetingID), !isRecording else { return }
        let folder = store.folder(for: meeting)
        Task { await pipeline.retranscribe(meetingID: meetingID, folder: folder) }
    }
}
