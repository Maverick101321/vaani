import Foundation

/// Protocol for Speech-To-Text (STT) transcription services.
nonisolated public protocol SpeechToText: Sendable {
    /// Transcribes audio samples into text.
    /// - Parameters:
    ///   - audioSamples: Mono 16 kHz Float32 audio samples.
    ///   - language: Language target (English or Hinglish).
    /// - Returns: Transcribed text.
    func transcribe(audioSamples: [Float], language: VoiceAgentViewModel.Language) async throws -> String
}

public extension SpeechToText {
    nonisolated func transcribe(audioSamples: [Float]) async throws -> String {
        try await transcribe(audioSamples: audioSamples, language: .english)
    }
}

/// Protocol for Large Language Model (LLM) query clients.
nonisolated public protocol LLMClient: Sendable {
    /// Generates a response for the provided prompt.
    /// - Parameters:
    ///   - prompt: The input prompt/query text.
    ///   - language: Language target (English or Hinglish).
    /// - Returns: Generated reply text.
    func generateResponse(prompt: String, language: VoiceAgentViewModel.Language) async throws -> String
}

public extension LLMClient {
    nonisolated func generateResponse(prompt: String) async throws -> String {
        try await generateResponse(prompt: prompt, language: .english)
    }
}

/// Protocol for Text-To-Speech (TTS) synthesis services.
nonisolated public protocol TextToSpeech: Sendable {
    /// Synthesizes and plays back speech for the given text.
    /// - Parameters:
    ///   - text: Text string to synthesize.
    ///   - language: Language target (English or Hinglish).
    func speak(text: String, language: VoiceAgentViewModel.Language) async throws
    
    /// Stops any active speech playback.
    func stop()
}

public extension TextToSpeech {
    nonisolated func speak(text: String) async throws {
        try await speak(text: text, language: .english)
    }
    
    nonisolated func stop() {}
}

// MARK: - Mock / Stub Implementations

/// Mock STT service for testing and Phase 1 skeleton.
nonisolated public final class MockSpeechToText: SpeechToText, Sendable {
    public let simulatedDelay: TimeInterval
    public let customResult: String?

    public nonisolated init(simulatedDelay: TimeInterval = 0.45, customResult: String? = nil) {
        self.simulatedDelay = simulatedDelay
        self.customResult = customResult
    }

    public nonisolated func transcribe(audioSamples: [Float], language: VoiceAgentViewModel.Language) async throws -> String {
        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }
        if let customResult = customResult {
            return customResult
        }
        switch language {
        case .english:
            return "What is the weather today?"
        case .hinglish:
            return "Aaj mausam kaisa hai?"
        }
    }
}

/// Mock LLM client for testing and Phase 1 skeleton.
nonisolated public final class MockLLMClient: LLMClient, Sendable {
    public let simulatedDelay: TimeInterval
    public let customResponse: String?

    public nonisolated init(simulatedDelay: TimeInterval = 0.65, customResponse: String? = nil) {
        self.simulatedDelay = simulatedDelay
        self.customResponse = customResponse
    }

    public nonisolated func generateResponse(prompt: String, language: VoiceAgentViewModel.Language) async throws -> String {
        if simulatedDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDelay * 1_000_000_000))
        }
        if let customResponse = customResponse {
            return customResponse
        }
        switch language {
        case .english:
            return "The weather is sunny and pleasant at 24 degrees Celsius."
        case .hinglish:
            return "Aaj mausam bilkul suhana aur dhoop wala hai, lagbhag 24 degrees."
        }
    }
}

/// Mock TTS engine for testing and Phase 1 skeleton.
nonisolated public final class MockTextToSpeech: TextToSpeech, @unchecked Sendable {
    public let simulatedDuration: TimeInterval
    private let lock = NSLock()
    private var _isSpeaking: Bool = false

    public var isSpeaking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isSpeaking
    }

    public nonisolated init(simulatedDuration: TimeInterval = 0.75) {
        self.simulatedDuration = simulatedDuration
    }

    public nonisolated func speak(text: String, language: VoiceAgentViewModel.Language) async throws {
        setSpeaking(true)
        
        if simulatedDuration > 0 {
            try await Task.sleep(nanoseconds: UInt64(simulatedDuration * 1_000_000_000))
        }
        
        setSpeaking(false)
    }

    public nonisolated func stop() {
        setSpeaking(false)
    }

    private nonisolated func setSpeaking(_ isSpeaking: Bool) {
        lock.lock()
        _isSpeaking = isSpeaking
        lock.unlock()
    }
}
