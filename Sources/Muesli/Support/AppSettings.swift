import Foundation
import SwiftUI
import Combine

enum AppThemeMode: String, CaseIterable, Identifiable {
    case light = "light"
    case dark = "dark"
    case auto = "auto"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Claro (padrão)"
        case .dark: return "Escuro"
        case .auto: return "Automático (sistema)"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .auto: return nil
        }
    }
}

enum STTEngine: String, CaseIterable, Identifiable {
    case local = "local"
    case groq = "groq"
    case openai = "openai"
    case openrouter = "openrouter"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Whisper Local (offline, gratuito)"
        case .groq: return "Groq Whisper API (gratuito · ultrarrápido)"
        case .openai: return "OpenAI Whisper API"
        case .openrouter: return "OpenRouter STT API"
        }
    }

    var shortLabel: String {
        switch self {
        case .local: return "Whisper Local"
        case .groq: return "Groq STT"
        case .openai: return "OpenAI STT"
        case .openrouter: return "OpenRouter STT"
        }
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case auto = "auto"
    case groq = "groq"
    case gemini = "gemini"
    case openai = "openai"
    case anthropic = "anthropic"
    case ollama = "ollama"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Automático (melhor disponível)"
        case .groq: return "Groq (Gratuito · Rápido)"
        case .gemini: return "Google Gemini"
        case .openai: return "OpenAI / Compatível"
        case .anthropic: return "Anthropic (Claude)"
        case .ollama: return "Ollama (Local)"
        }
    }
}

enum RecordingPrivacyNotice {
    static func text(
        sttEngine: STTEngine,
        cloudFallback: Bool,
        cloudSTTConfigured: Bool = true,
        systemAudio: Bool,
        automaticEnhancement: Bool,
        aiProvider: AIProvider?,
        aiProviderIsLocal: Bool = false
    ) -> String {
        var parts = [systemAudio
            ? "Captura configurada: microfone e áudio do sistema (sem vídeo)."
            : "Captura configurada: somente microfone (sem vídeo)."]

        switch sttEngine {
        case .local:
            parts.append("Transcrição processada localmente com Whisper; o áudio fica neste Mac.")
        case .groq, .openai, .openrouter:
            if cloudSTTConfigured {
                var detail = "Transcrição na nuvem via \(sttEngine.shortLabel): os blocos de áudio são enviados a esse provedor."
                if cloudFallback {
                    detail += " Se a API falhar, o Whisper local será usado como reserva."
                }
                parts.append(detail)
            } else if cloudFallback {
                parts.append("Nenhuma chave de STT na nuvem está configurada; o áudio não será enviado a um provedor e o app tentará Whisper local como reserva.")
            } else {
                parts.append("Nenhuma chave de STT na nuvem está configurada; a transcrição não funcionará até configurar uma chave ou selecionar Whisper local.")
            }
        }

        if automaticEnhancement, aiProviderIsLocal {
            parts.append("Ao parar, o endpoint local de IA gerará a ata automaticamente; o texto permanece neste Mac.")
        } else if automaticEnhancement, aiProvider == .ollama {
            parts.append("Ao parar, o Ollama local gerará a ata automaticamente; o texto permanece neste Mac.")
        } else if automaticEnhancement, let aiProvider {
            parts.append("Ao parar, a transcrição e as notas serão enviadas ao provedor de IA (\(aiProvider.label)) para gerar a ata automaticamente.")
        }
        return parts.joined(separator: " ")
    }
}

enum CollapsedCategoryPreferences {
    static func decode(_ rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: ",").map(String.init))
    }

    static func encode(_ categoryIDs: Set<String>) -> String {
        categoryIDs.sorted().joined(separator: ",")
    }

    static func toggle(_ categoryID: String, in rawValue: String) -> String {
        var categoryIDs = decode(rawValue)
        if !categoryIDs.insert(categoryID).inserted {
            categoryIDs.remove(categoryID)
        }
        return encode(categoryIDs)
    }
}

/// Persistent preferences. Everything non-secret lives in UserDefaults;
/// API key lists live in the macOS Keychain.
@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("themeMode") var themeModeRaw: String = AppThemeMode.light.rawValue
    @AppStorage("autoEnhanceOnStop") var autoEnhanceOnStop: Bool = true
    @AppStorage("sttEngine") var sttEngineRaw: String = STTEngine.local.rawValue
    @AppStorage("sttCloudIntervalSec") var sttCloudIntervalSec: Double = 12
    @AppStorage("sttCloudFallback") var sttCloudFallback: Bool = true
    @AppStorage("sttGroqModel") var sttGroqModel: String = "whisper-large-v3-turbo"
    @AppStorage("sttOpenAIModel") var sttOpenAIModel: String = "whisper-1"
    @AppStorage("sttOpenRouterModel") var sttOpenRouterModel: String = "openai/whisper-large-v3-turbo"
    @AppStorage("whisperPathOverride") var whisperPathOverride: String = ""
    @AppStorage("modelFileName") var modelFileName: String = "ggml-large-v3-turbo.bin"
    @AppStorage("language") var language: String = "pt"
    @AppStorage("chunkSeconds") var chunkSeconds: Double = 20
    @AppStorage("echoCancellation") var echoCancellation: Bool = true {
        didSet { if vpKnownBad { vpKnownBad = false } }
    }
    @AppStorage("vpKnownBadV2") var vpKnownBad: Bool = false
    @AppStorage("captureSystemAudio") var captureSystemAudio: Bool = true
    @AppStorage("showConsentNotice") var showConsentNotice: Bool = true
    @AppStorage("consentSnippet") var consentSnippet: String = "Esta reunião está sendo gravada pelo Muesli."
    @AppStorage("storageBookmark") var storagePath: String = ""

    @AppStorage("aiProvider") var aiProviderRaw: String = AIProvider.auto.rawValue

    // Models & endpoints
    @AppStorage("groqModel") var groqModel: String = "qwen/qwen3.8-27b"
    @AppStorage("geminiModel") var geminiModel: String = "gemini-2.5-flash"
    @AppStorage("openAIModel") var openAIModel: String = "gpt-4o-mini"
    @AppStorage("openAIBaseURL") var openAIBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("anthropicModel") var anthropicModel: String = "claude-haiku-4-5-20251001"
    @AppStorage("ollamaBaseURL") var ollamaBaseURL: String = "http://localhost:11434"
    @AppStorage("ollamaModel") var ollamaModel: String = ""

    var ollamaURL: String {
        get { ollamaBaseURL }
        set { ollamaBaseURL = newValue }
    }

    // Multi-key lists persisted in a single consolidated Keychain bundle
    @Published var groqKeys: [String] {
        didSet { persistKeyBundle() }
    }
    @Published var geminiKeys: [String] {
        didSet { persistKeyBundle() }
    }
    @Published var openAIKeys: [String] {
        didSet { persistKeyBundle() }
    }
    @Published var anthropicKeys: [String] {
        didSet { persistKeyBundle() }
    }

    // Dedicated STT multi-key lists persisted in Keychain (falls back to AI keys if empty)
    @Published var sttGroqKeys: [String] {
        didSet { persistKeyBundle() }
    }
    @Published var sttOpenAIKeys: [String] {
        didSet { persistKeyBundle() }
    }
    @Published var sttOpenRouterKeys: [String] {
        didSet { persistKeyBundle() }
    }

    // Convenience single-key bridges for CLI / tests / simple callers
    var groqKey: String {
        get { groqKeys.first ?? "" }
        set { groqKeys = KeychainHelper.cleanKeys([newValue]) }
    }
    var geminiKey: String {
        get { geminiKeys.first ?? "" }
        set { geminiKeys = KeychainHelper.cleanKeys([newValue]) }
    }
    var openAIKey: String {
        get { openAIKeys.first ?? "" }
        set { openAIKeys = KeychainHelper.cleanKeys([newValue]) }
    }
    var anthropicKey: String {
        get { anthropicKeys.first ?? "" }
        set { anthropicKeys = KeychainHelper.cleanKeys([newValue]) }
    }

    var themeMode: AppThemeMode {
        get { AppThemeMode(rawValue: themeModeRaw) ?? .light }
        set { themeModeRaw = newValue.rawValue; objectWillChange.send() }
    }

    var aiProvider: AIProvider {
        get { AIProvider(rawValue: aiProviderRaw) ?? .auto }
        set { aiProviderRaw = newValue.rawValue; objectWillChange.send() }
    }

    var sttEngine: STTEngine {
        get { STTEngine(rawValue: sttEngineRaw) ?? .local }
        set { sttEngineRaw = newValue.rawValue; objectWillChange.send() }
    }

    init() {
        if let bundle = KeychainHelper.loadKeyBundle() {
            self.groqKeys = bundle["groq"] ?? []
            self.geminiKeys = bundle["gemini"] ?? []
            self.openAIKeys = bundle["openai"] ?? []
            self.anthropicKeys = bundle["anthropic"] ?? []
            self.sttGroqKeys = bundle["sttGroq"] ?? []
            self.sttOpenAIKeys = bundle["sttOpenAI"] ?? []
            self.sttOpenRouterKeys = bundle["sttOpenRouter"] ?? []
        } else {
            let groq = KeychainHelper.loadKeys(account: "groq-api-keys")
            let gemini = KeychainHelper.loadKeys(account: "gemini-api-keys")
            let openAI = KeychainHelper.loadKeys(account: "openai-api-keys", fallbackSingleAccount: "openai-api-key")
            let anthropic = KeychainHelper.loadKeys(account: "anthropic-api-keys", fallbackSingleAccount: "anthropic-api-key")
            let sttGroq = KeychainHelper.loadKeys(account: "stt-groq-api-keys")
            let sttOpenAI = KeychainHelper.loadKeys(account: "stt-openai-api-keys")
            let sttOpenRouter = KeychainHelper.loadKeys(account: "stt-openrouter-api-keys")

            self.groqKeys = groq
            self.geminiKeys = gemini
            self.openAIKeys = openAI
            self.anthropicKeys = anthropic
            self.sttGroqKeys = sttGroq
            self.sttOpenAIKeys = sttOpenAI
            self.sttOpenRouterKeys = sttOpenRouter

            if !groq.isEmpty || !gemini.isEmpty || !openAI.isEmpty || !anthropic.isEmpty
                || !sttGroq.isEmpty || !sttOpenAI.isEmpty || !sttOpenRouter.isEmpty {
                persistKeyBundle()
            }
        }
    }

    private func persistKeyBundle() {
        KeychainHelper.saveKeyBundle([
            "groq": groqKeys,
            "gemini": geminiKeys,
            "openai": openAIKeys,
            "anthropic": anthropicKeys,
            "sttGroq": sttGroqKeys,
            "sttOpenAI": sttOpenAIKeys,
            "sttOpenRouter": sttOpenRouterKeys,
        ])
    }

    func resolvedSTTKeys(for engine: STTEngine? = nil) -> [String] {
        let target = engine ?? sttEngine
        switch target {
        case .local:
            return []
        case .groq:
            let k = KeychainHelper.cleanKeys(sttGroqKeys)
            return k.isEmpty ? KeychainHelper.cleanKeys(groqKeys) : k
        case .openai:
            let k = KeychainHelper.cleanKeys(sttOpenAIKeys)
            return k.isEmpty ? KeychainHelper.cleanKeys(openAIKeys) : k
        case .openrouter:
            let k = KeychainHelper.cleanKeys(sttOpenRouterKeys)
            if !k.isEmpty { return k }
            if openAIBaseURL.lowercased().contains("openrouter.ai") {
                return KeychainHelper.cleanKeys(openAIKeys)
            }
            return []
        }
    }

    func resolvedSTTModel(for engine: STTEngine? = nil) -> String {
        let target = engine ?? sttEngine
        switch target {
        case .local: return modelFileName
        case .groq:
            let m = sttGroqModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "whisper-large-v3-turbo" : m
        case .openai:
            let m = sttOpenAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "whisper-1" : m
        case .openrouter:
            let m = sttOpenRouterModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return m.isEmpty ? "openai/whisper-large-v3-turbo" : m
        }
    }

    var effectiveChunkSeconds: Double {
        sttEngine == .local ? chunkSeconds : max(10, min(480, sttCloudIntervalSec))
    }

    var isSTTReady: Bool {
        if sttEngine == .local {
            return resolveWhisperBinary() != nil && modelURL != nil
        }
        if !resolvedSTTKeys().isEmpty { return true }
        return sttCloudFallback && resolveWhisperBinary() != nil && modelURL != nil
    }

    var activeSTTSummary: String {
        if sttEngine == .local { return "Whisper Local" }
        let keys = resolvedSTTKeys()
        let base = sttEngine.shortLabel
        if keys.isEmpty { return "\(base) (sem chave)" }
        return "\(base) (\(keys.count)x)"
    }

    var hasGroq: Bool { !KeychainHelper.cleanKeys(groqKeys).isEmpty }
    var hasGemini: Bool { !KeychainHelper.cleanKeys(geminiKeys).isEmpty }
    var hasOpenAI: Bool { !KeychainHelper.cleanKeys(openAIKeys).isEmpty }
    var hasAnthropic: Bool { !KeychainHelper.cleanKeys(anthropicKeys).isEmpty }
    var hasOllama: Bool { !ollamaModel.trimmingCharacters(in: .whitespaces).isEmpty }

    var hasAIConfigured: Bool {
        switch aiProvider {
        case .auto:
            return hasGroq || hasGemini || hasAnthropic || hasOpenAI || hasOllama
        case .groq:
            return hasGroq
        case .gemini:
            return hasGemini
        case .openai:
            return hasOpenAI
        case .anthropic:
            return hasAnthropic
        case .ollama:
            return hasOllama
        }
    }

    var activeProviderSummary: String {
        let p = resolvedActiveProvider()
        switch p {
        case .groq:
            let count = KeychainHelper.cleanKeys(groqKeys).count
            let m = groqModel.isEmpty ? "qwen/qwen3.8-27b" : groqModel
            return "Groq (\(count)x) · \(m)"
        case .gemini:
            let count = KeychainHelper.cleanKeys(geminiKeys).count
            let m = geminiModel.isEmpty ? "gemini-2.5-flash" : geminiModel
            return "Gemini (\(count)x) · \(m)"
        case .openai:
            let m = openAIModel.isEmpty ? "gpt-4o-mini" : openAIModel
            return "OpenAI · \(m)"
        case .anthropic:
            let m = anthropicModel.isEmpty ? "claude-haiku-4-5" : anthropicModel
            return "Claude · \(m)"
        case .ollama:
            let m = ollamaModel.isEmpty ? "Ollama" : ollamaModel
            return "Ollama · \(m)"
        case .auto:
            return "Sem chave de IA (Extrativo)"
        }
    }

    /// Returns the provider that will run first given the current configuration.
    func resolvedActiveProvider() -> AIProvider {
        if aiProvider != .auto { return aiProvider }
        if hasGroq { return .groq }
        if hasGemini { return .gemini }
        if hasAnthropic { return .anthropic }
        if hasOpenAI { return .openai }
        if hasOllama { return .ollama }
        return .auto
    }

    // MARK: - Paths

    var baseDir: URL {
        if !storagePath.isEmpty {
            return URL(fileURLWithPath: storagePath, isDirectory: true)
        }
        return MeetingStore.defaultBaseDir()
    }

    var modelsDir: URL {
        MeetingStore.defaultBaseDir().appendingPathComponent("models", isDirectory: true)
    }

    var modelURL: URL? {
        let url = modelsDir.appendingPathComponent(modelFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static let whisperCandidates = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/homebrew/opt/whisper-cpp/bin/whisper-cli",
        "/usr/local/opt/whisper-cpp/bin/whisper-cli",
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp",
    ]

    /// Searches PATH and common Homebrew locations for `whisper-cli` (or legacy `main`).
    func resolveWhisperBinary() -> URL? {
        let fm = FileManager.default
        let override = whisperPathOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for path in AppSettings.whisperCandidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in envPath.split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent("whisper-cli")
            if fm.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Model strings are kept in sync across Anthropic/Groq/Gemini/OpenAI.
    static let groqRecommendedModels: [String] = [
        "qwen/qwen3.8-27b",
        "llama-3.3-70b-versatile",
        "llama-3.1-8b-instant",
        "openai/gpt-oss-120b",
    ]

    static let geminiRecommendedModels: [String] = [
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.5-flash-lite",
    ]

    static let openAIRecommendedModels: [String] = [
        "gpt-4o-mini",
        "gpt-4o",
        "o4-mini",
    ]

    static let anthropicModels: [(id: String, label: String)] = [
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5 (rápido e econômico)"),
        ("claude-sonnet-4-5", "Claude Sonnet 4.5 (equilibrado)"),
        ("claude-opus-4-1", "Claude Opus 4.1 (máxima qualidade)"),
    ]

    static let sttGroqModels: [String] = [
        "whisper-large-v3-turbo",
        "whisper-large-v3",
    ]

    static let sttOpenAIModels: [String] = [
        "whisper-1",
        "gpt-4o-mini-transcribe",
        "gpt-4o-transcribe",
    ]

    nonisolated static let sttOpenRouterModels: [String] = [
        "openai/whisper-large-v3-turbo",
        "openai/whisper-large-v3",
    ]
}
