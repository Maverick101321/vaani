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

/// Role of a message in a multi-turn LLM conversation.
nonisolated public enum LLMMessageRole: String, Sendable, Equatable {
    case system
    case user
    case assistant
    case tool
}

/// A message item in a conversation or tool-calling turn.
nonisolated public struct LLMChatMessage: Sendable, Equatable {
    public let role: LLMMessageRole
    public let content: String
    public let toolCalls: [LLMToolCall]
    public let toolCallId: String?
    public let toolName: String?

    public init(
        role: LLMMessageRole,
        content: String,
        toolCalls: [LLMToolCall] = [],
        toolCallId: String? = nil,
        toolName: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
    }

    public static func user(_ text: String) -> LLMChatMessage {
        LLMChatMessage(role: .user, content: text)
    }

    public static func assistant(_ text: String, toolCalls: [LLMToolCall] = []) -> LLMChatMessage {
        LLMChatMessage(role: .assistant, content: text, toolCalls: toolCalls)
    }

    public static func toolResult(id: String, name: String, content: String) -> LLMChatMessage {
        LLMChatMessage(role: .tool, content: content, toolCallId: id, toolName: name)
    }
}

/// Output from a single streaming LLM generation request.
nonisolated public struct LLMStreamResult: Sendable, Equatable {
    public let text: String
    public let toolCalls: [LLMToolCall]
    public let providerName: String
    public let modelName: String

    public init(
        text: String,
        toolCalls: [LLMToolCall] = [],
        providerName: String = "Mock",
        modelName: String = "mock"
    ) {
        self.text = text
        self.toolCalls = toolCalls
        self.providerName = providerName
        self.modelName = modelName
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

    /// Streams a chat completion with tool-calling support.
    /// - Parameters:
    ///   - messages: Conversation messages (user, assistant, tool results).
    ///   - systemPrompt: System instruction string.
    ///   - tools: Available tool schema definitions.
    ///   - onFirstToken: Invoked once when the first token or tool-call chunk arrives.
    ///   - onTextDelta: Invoked for each streamed text delta chunk.
    /// - Returns: Final accumulated text and any requested tool calls.
    func streamChat(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        onFirstToken: (@Sendable () -> Void)?,
        onTextDelta: (@Sendable (String) -> Void)?
    ) async throws -> LLMStreamResult
}

public extension LLMClient {
    nonisolated func generateResponse(prompt: String) async throws -> String {
        try await generateResponse(prompt: prompt, language: .english)
    }

    nonisolated func streamChat(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        onFirstToken: (@Sendable () -> Void)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMStreamResult {
        let lastUserPrompt = messages.last(where: { $0.role == .user })?.content ?? ""
        let reply = try await generateResponse(prompt: lastUserPrompt, language: .english)
        onFirstToken?()
        if !reply.isEmpty {
            onTextDelta?(reply)
        }
        return LLMStreamResult(text: reply, toolCalls: [], providerName: "Mock", modelName: "mock")
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

#if DEBUG
/// Preview-only mock LLM client (restricted to SwiftUI Previews; never used in runtime path).
nonisolated public final class MockLLMClient: LLMClient, Sendable {
    public let simulatedDelay: TimeInterval
    public let customResponse: String?

    public nonisolated init(simulatedDelay: TimeInterval = 0.0, customResponse: String? = nil) {
        self.simulatedDelay = simulatedDelay
        self.customResponse = customResponse
    }

    public nonisolated func generateResponse(prompt: String, language: VoiceAgentViewModel.Language) async throws -> String {
        if let customResponse = customResponse {
            return customResponse
        }
        return "[Preview] \(prompt)"
    }
}
#endif

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
