import Foundation
import Observation

/// Metrics tracking execution latency across agent pipeline stages.
public struct LatencyMetrics: Equatable, Sendable {
    public var sttMs: Double
    public var llmMs: Double
    public var ttsMs: Double
    public var totalMs: Double
    
    public init(sttMs: Double = 0, llmMs: Double = 0, ttsMs: Double = 0, totalMs: Double = 0) {
        self.sttMs = sttMs
        self.llmMs = llmMs
        self.ttsMs = ttsMs
        self.totalMs = totalMs
    }
}

/// Helper extension to compute duration in milliseconds.
private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = self.components
        return Double(seconds) * 1000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
    }
}

/// Main view model driving the Vaani voice assistant state, recording, and agent loop.
@Observable
@MainActor
public final class VoiceAgentViewModel {
    // MARK: - State & Enums
    
    /// Agent execution state.
    public enum State: String, CaseIterable, Sendable {
        case idle
        case listening
        case transcribing
        case thinking
        case speaking
        
        public var displayName: String {
            switch self {
            case .idle: return "Idle"
            case .listening: return "Listening..."
            case .transcribing: return "Transcribing..."
            case .thinking: return "Thinking..."
            case .speaking: return "Speaking..."
            }
        }
    }
    
    public typealias AgentState = State
    
    /// Supported interaction languages.
    public enum Language: String, CaseIterable, Identifiable, Sendable {
        case english = "English"
        case hinglish = "Hinglish"
        
        public var id: String { rawValue }
    }
    
    // MARK: - Observable Properties
    
    /// Current lifecycle state of the voice agent.
    public var state: State = .idle
    
    /// Current recognized user transcript.
    public var transcript: String = ""
    
    /// Current LLM generated response.
    public var response: String = ""
    
    /// Selected language (English or Hinglish).
    public var language: Language = .english
    
    /// Latency breakdown metrics for STT, LLM, TTS, and total pipeline duration.
    public var latency: LatencyMetrics = LatencyMetrics()
    
    /// Live microphone input level [0.0 ... 1.0] for UI visualizer meters.
    public var audioLevel: Float = 0.0
    
    /// Optional error description for user-facing alerts or banners.
    public var errorMessage: String?
    
    // MARK: - Dependencies & Private State
    
    public let audioRecorder: AudioRecorder
    public let sttClient: SpeechToText
    public let llmClient: LLMClient
    public let ttsClient: TextToSpeech
    
    /// Cached audio samples from the last recorded utterance.
    public private(set) var lastAudioSamples: [Float] = []
    
    private var activeTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    public init(
        audioRecorder: AudioRecorder = AudioRecorder(),
        sttClient: SpeechToText = MockSpeechToText(),
        llmClient: LLMClient = MockLLMClient(),
        ttsClient: TextToSpeech = MockTextToSpeech()
    ) {
        self.audioRecorder = audioRecorder
        self.sttClient = sttClient
        self.llmClient = llmClient
        self.ttsClient = ttsClient
        
        // Link real-time audio meter updates directly to view model property
        audioRecorder.onLevelChange = { [weak self] level in
            self?.audioLevel = level
        }
    }
    
    // MARK: - Voice Pipeline Controls
    
    /// Toggles listening state on/off.
    public func toggleListening() {
        if state == .listening {
            stopListening()
        } else if state == .idle {
            startListening()
        } else {
            // Cancel current ongoing operation and return to idle
            reset()
        }
    }
    
    /// Begins recording audio from the microphone.
    public func startListening() {
        activeTask?.cancel()
        errorMessage = nil
        state = .listening
        
        activeTask = Task {
            do {
                try await audioRecorder.start()
            } catch is CancellationError {
                // Cancelled due to rapid stop or reset - do not show error banner
            } catch {
                self.errorMessage = error.localizedDescription
                self.state = .idle
            }
        }
    }
    
    /// Stops recording and runs the voice agent pipeline (STT -> LLM -> TTS).
    public func stopListening() {
        guard state == .listening else { return }
        
        let samples = audioRecorder.stop()
        self.lastAudioSamples = samples
        self.audioLevel = 0.0
        
        activeTask?.cancel()
        activeTask = Task {
            let pipelineStart = ContinuousClock.now
            latency = LatencyMetrics()
            
            // 1. Transcribe audio
            let transcribedText = await transcribe(samples: samples)
            guard !Task.isCancelled else { return }
            
            // 2. Query LLM
            let generatedAnswer = await ask(prompt: transcribedText)
            guard !Task.isCancelled else { return }
            
            // 3. Speak response
            await speak(text: generatedAnswer)
            guard !Task.isCancelled else { return }
            
            let totalElapsed = ContinuousClock.now - pipelineStart
            latency.totalMs = totalElapsed.milliseconds
        }
    }
    
    /// Cancels any active processing or speaking, returning to idle.
    public func reset() {
        activeTask?.cancel()
        activeTask = nil
        _ = audioRecorder.stop()
        ttsClient.stop()
        audioLevel = 0.0
        state = .idle
    }
    
    // MARK: - Stub Methods (Phase 1 Placeholders)
    
    /// Transcribes audio samples into text.
    /// - Parameter samples: Mono 16 kHz Float32 samples. Defaults to nil (uses last recorded audio).
    /// - Returns: Recognized transcript string.
    @discardableResult
    public func transcribe(samples: [Float]? = nil) async -> String {
        // TODO: Replace stub with production STT implementation (e.g. WhisperKit, Apple Speech, or API)
        state = .transcribing
        let start = ContinuousClock.now
        
        let audio = samples ?? lastAudioSamples
        let recognized: String
        do {
            recognized = try await sttClient.transcribe(audioSamples: audio, language: language)
        } catch {
            print("STT transcription error: \(error)")
            recognized = (language == .english)
                ? "What is the weather today?"
                : "Aaj mausam kaisa hai?"
        }
        
        let elapsed = ContinuousClock.now - start
        latency.sttMs = elapsed.milliseconds
        self.transcript = recognized
        return recognized
    }
    
    /// Queries the language model with the prompt.
    /// - Parameter prompt: Input prompt text. Defaults to nil (uses current transcript).
    /// - Returns: Generated response text.
    @discardableResult
    public func ask(prompt: String? = nil) async -> String {
        // TODO: Replace stub with production LLM client (e.g. Gemini, OpenAI, Claude, or local LLM)
        state = .thinking
        let start = ContinuousClock.now
        
        let inputPrompt = prompt ?? self.transcript
        let generated: String
        do {
            generated = try await llmClient.generateResponse(prompt: inputPrompt, language: language)
        } catch {
            print("LLM query error: \(error)")
            generated = (language == .english)
                ? "The weather is sunny and pleasant today."
                : "Aaj mausam bilkul suhana aur dhoop wala hai."
        }
        
        let elapsed = ContinuousClock.now - start
        latency.llmMs = elapsed.milliseconds
        self.response = generated
        return generated
    }
    
    /// Synthesizes and speaks the given response text.
    /// - Parameter text: Response text to synthesize. Defaults to nil (uses current response).
    public func speak(text: String? = nil) async {
        // TODO: Replace stub with production TTS engine (e.g. ElevenLabs, Apple TTS, or custom neural TTS)
        state = .speaking
        let start = ContinuousClock.now
        
        let inputSpeech = text ?? self.response
        do {
            try await ttsClient.speak(text: inputSpeech, language: language)
        } catch {
            print("TTS speech synthesis error: \(error)")
        }
        
        let elapsed = ContinuousClock.now - start
        latency.ttsMs = elapsed.milliseconds
        state = .idle
    }
}
