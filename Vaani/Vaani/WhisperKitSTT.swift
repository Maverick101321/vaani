import Foundation
import WhisperKit

// MARK: - STT configuration

/// The single place to select the on-device Whisper model and decoding defaults.
nonisolated public struct STTConfig: Sendable {
    public enum LanguageMode: String, Sendable {
        case english
        case hinglish

        var whisperLanguageCode: String {
            switch self {
            case .english: return "en"
            case .hinglish: return "hi"
            }
        }
    }

    /// Multilingual variants: `base`, `small`, and `turbo` are easy drop-in choices.
    public var modelName: String
    public var languageMode: LanguageMode
    public var useHinglishPrompt: Bool

    public init(modelName: String = "small", languageMode: LanguageMode = .english, useHinglishPrompt: Bool = true) {
        self.modelName = modelName
        self.languageMode = languageMode
        self.useHinglishPrompt = useHinglishPrompt
    }
}

/// Lifecycle of the on-device speech model.
nonisolated public enum STTLoadingState: Equatable, Sendable {
    case downloading
    case loading
    case ready
    case failed(String)

    public var displayName: String {
        switch self {
        case .downloading: return "Downloading speech model…"
        case .loading: return "Loading speech model…"
        case .ready: return "Speech model ready"
        case .failed(let message): return "Speech model failed: \(message)"
        }
    }
}

nonisolated public enum WhisperKitSTTError: LocalizedError {
    case modelNotReady
    case tokenizerUnavailable

    public var errorDescription: String? {
        switch self {
        case .modelNotReady: return "The speech recognition model is not ready yet."
        case .tokenizerUnavailable: return "The Whisper tokenizer is unavailable."
        }
    }
}

/// On-device WhisperKit implementation. The mutable WhisperKit instance lives in an actor.
nonisolated public final class WhisperKitSTT: SpeechToText, Sendable {
    private let config: STTConfig
    private let store = WhisperKitStore()

    public init(config: STTConfig = STTConfig()) {
        self.config = config
    }

    /// Downloads (only when needed), specializes, and loads the model before recording is enabled.
    public nonisolated func prepare(
        stateHandler: @escaping @MainActor @Sendable (STTLoadingState) -> Void
    ) async throws {
        try await store.prepare(config: config, stateHandler: stateHandler)
    }

    public nonisolated func transcribe(audioSamples: [Float], language: VoiceAgentViewModel.Language) async throws -> String {
        let languageMode: STTConfig.LanguageMode = language == .english ? .english : .hinglish
        return try await store.transcribe(audioSamples: audioSamples, languageMode: languageMode, config: config)
    }
}

private actor WhisperKitStore {
    private var whisperKit: WhisperKit?
    private var isPreparing = false

    func prepare(config: STTConfig, stateHandler: @escaping @MainActor @Sendable (STTLoadingState) -> Void) async throws {
        if whisperKit != nil {
            await stateHandler(.ready)
            return
        }

        guard !isPreparing else { throw WhisperKitSTTError.modelNotReady }
        isPreparing = true
        defer { isPreparing = false }

        await stateHandler(.downloading)
        do {
            // `load: false` exposes download and model-loading as distinct UI states.
            let kit = try await WhisperKit(
                model: config.modelName,
                verbose: false,
                prewarm: false,
                load: false,
                download: true
            )
            await stateHandler(.loading)
            try await kit.prewarmModels()
            try await kit.loadModels()
            whisperKit = kit
            await stateHandler(.ready)
        } catch {
            await stateHandler(.failed(error.localizedDescription))
            throw error
        }
    }

    func transcribe(audioSamples: [Float], languageMode: STTConfig.LanguageMode, config: STTConfig) async throws -> String {
        guard let whisperKit else { throw WhisperKitSTTError.modelNotReady }

        let trimmedSamples = trimLeadingAndTrailingSilence(from: audioSamples)
        guard !trimmedSamples.isEmpty else { return "" }

        let promptTokens: [Int]?
        if languageMode == .hinglish && config.useHinglishPrompt {
            guard let tokenizer = whisperKit.tokenizer else { throw WhisperKitSTTError.tokenizerUnavailable }
            promptTokens = tokenizer.encode(text: Self.hinglishPrompt)
        } else {
            promptTokens = nil
        }

        // A zero fallback count prevents a fallback to non-greedy temperatures.
        let options = DecodingOptions(
            language: languageMode.whisperLanguageCode,
            temperature: 0,
            temperatureFallbackCount: 0,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens
        )

        let start = ContinuousClock.now
        let results = try await whisperKit.transcribe(audioArray: trimmedSamples, decodeOptions: options)
        let rawText = results.map(\.text).joined(separator: " ")
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = ContinuousClock.now - start
        let containsDevanagari = rawText.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        let sttMilliseconds = String(format: "%.0f", elapsed.milliseconds)

        // DEBUG: one compact diagnostic per transcription for the Xcode console.
        print("[WhisperKitSTT DEBUG] model=\(config.modelName) languageMode=\(languageMode.rawValue) rawText=\(rawText.debugDescription) containsDevanagari=\(containsDevanagari) sttMs=\(sttMilliseconds)")
        return text
    }

    /// Removes quiet leading/trailing samples while retaining 100 ms of speech context.
    private func trimLeadingAndTrailingSilence(from samples: [Float]) -> [Float] {
        let energyThreshold: Float = 0.008
        let contextSamples = 1_600 // 100 ms at 16 kHz.
        guard let firstSound = samples.firstIndex(where: { abs($0) >= energyThreshold }),
              let lastSound = samples.lastIndex(where: { abs($0) >= energyThreshold }) else {
            return []
        }
        let start = max(0, firstSound - contextSamples)
        let end = min(samples.count, lastSound + contextSamples + 1)
        return Array(samples[start..<end])
    }

    private static let hinglishPrompt = "Aaj ka schedule kya hai, aur meri next meeting kab hai? Mujhe kal subah 7 baje ka alarm set karna hai."
}

private extension Duration {
    nonisolated var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}
