import Foundation
import Observation

/// Metrics tracking execution latency across agent pipeline stages.
public struct LatencyMetrics: Equatable, Sendable {
    public var sttMs: Double
    /// Time until the first LLM token arrives (TTFT in ms).
    public var llmFirstTokenMs: Double
    /// Total LLM generation time in ms (including any tool calls).
    public var llmTotalMs: Double
    /// Total LLM time in ms (kept synchronized with `llmTotalMs`).
    public var llmMs: Double
    /// Time until TTS audio begins (time-to-first-audio).
    public var ttsMs: Double
    /// Explicit time-to-first-audio in ms (first scheduled buffer or `didStart` delegate callback).
    public var ttsFirstAudioMs: Double
    /// Total TTS synthesis time in ms (for neural TTS engines like Kokoro).
    public var ttsSynthMs: Double
    /// Real-time factor (`synthSeconds / audioDurationSeconds`) for neural TTS.
    public var ttsRTF: Double
    /// Total TTS playback duration in ms (until audio finishes playing).
    public var ttsTotalDurationMs: Double
    public var totalMs: Double
    
    public init(
        sttMs: Double = 0,
        llmFirstTokenMs: Double = 0,
        llmTotalMs: Double = 0,
        llmMs: Double = 0,
        ttsMs: Double = 0,
        ttsFirstAudioMs: Double = 0,
        ttsSynthMs: Double = 0,
        ttsRTF: Double = 0,
        ttsTotalDurationMs: Double = 0,
        totalMs: Double = 0
    ) {
        self.sttMs = sttMs
        self.llmFirstTokenMs = llmFirstTokenMs
        let resolvedTotalLLM = llmTotalMs > 0 ? llmTotalMs : llmMs
        self.llmTotalMs = resolvedTotalLLM
        self.llmMs = llmMs > 0 ? llmMs : resolvedTotalLLM
        self.ttsMs = ttsMs
        self.ttsFirstAudioMs = ttsFirstAudioMs > 0 ? ttsFirstAudioMs : ttsMs
        self.ttsSynthMs = ttsSynthMs
        self.ttsRTF = ttsRTF
        self.ttsTotalDurationMs = ttsTotalDurationMs
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
    
    /// Whether the user has explicitly touched a dev TTS engine/strategy toggle in the collapsible Dev section.
    /// When `false` (default), routing is strictly: English -> Apple Isha (en-IN), Hinglish -> Kokoro hf_beta K2 (lang="hi").
    public var devTTSOverrideEnabled: Bool = false

    /// Selected TTS engine (used in TTS Lab or when `devTTSOverrideEnabled == true`).
    public var ttsEngine: TTSEngine = .kokoro
    
    /// Selected Kokoro Hinglish strategy (locked-in default `.k2DevanagariMixHi` with Hindi voice `hf_beta`).
    public var kokoroStrategy: KokoroStrategy = .k2DevanagariMixHi {
        didSet {
            kokoroTTS.hinglishStrategy = kokoroStrategy
        }
    }
    
    /// Selected Kokoro speaker ID for Hindi/Hinglish (locked-in default `32` `hf_beta`).
    public var kokoroHindiSpeakerID: Int = KokoroSpeaker.defaultHindiSpeakerID {
        didSet {
            kokoroTTS.hindiSpeakerID = kokoroHindiSpeakerID
        }
    }
    
    /// Selected Kokoro speaker ID for English (defaults to `3` `af_heart`).
    public var kokoroEnglishSpeakerID: Int = KokoroSpeaker.defaultEnglishSpeakerID {
        didSet {
            kokoroTTS.englishSpeakerID = kokoroEnglishSpeakerID
        }
    }
    
    /// Selected Kokoro speech speed (`0.8 ... 1.3`, defaults to `1.0`).
    public var kokoroSpeed: Float = 1.0 {
        didSet {
            kokoroTTS.speed = kokoroSpeed
        }
    }
    
    /// Selected Apple Hinglish TTS strategy (defaults to `.romanizedHiIN`).
    public var ttsStrategy: TTSStrategy = .romanizedHiIN {
        didSet {
            appleTTS.hinglishStrategy = ttsStrategy
        }
    }
    
    /// Latency breakdown metrics for STT, LLM, TTS (time-to-first-audio), and total pipeline duration.
    public var latency: LatencyMetrics = LatencyMetrics()
    
    /// Convenience accessor for time-to-first-audio in ms.
    public var ttsFirstAudioMs: Double {
        latency.ttsFirstAudioMs
    }
    
    /// Convenience accessor for total TTS speech duration in ms.
    public var ttsTotalDurationMs: Double {
        latency.ttsTotalDurationMs
    }
    
    /// Live microphone input level [0.0 ... 1.0] for UI visualizer meters.
    public var audioLevel: Float = 0.0
    
    /// Optional error description for user-facing alerts or banners.
    public var errorMessage: String?

    /// Name of the LLM provider + model that answered the most recent turn (e.g. `"Groq • llama-3.3-70b-versatile"`).
    public var lastAnsweringProvider: String?

    /// Phase 6 hook: invoked on `@MainActor` as each complete sentence is streamed from the LLM.
    public var onSentenceStreamed: ((String) -> Void)?

    /// Download/load lifecycle for the on-device WhisperKit model.
    public var sttLoadingState: STTLoadingState = .loading

    public var isSTTReady: Bool {
        sttLoadingState == .ready
    }

    /// Load lifecycle for the bundled on-device Kokoro TTS model.
    public var kokoroLoadingState: KokoroLoadingState = .loading

    public var isKokoroReady: Bool {
        kokoroLoadingState == .ready
    }
    
    // MARK: - Dependencies & Private State
    
    public let audioRecorder: AudioRecorder
    public let sttClient: SpeechToText
    public let llmClient: LLMClient
    public let orchestrator: AgentOrchestrator
    public let ttsClient: TextToSpeech
    public let kokoroTTS: KokoroTTS
    public let appleTTS: AppleTTS
    
    /// Cached audio samples from the last recorded utterance.
    public private(set) var lastAudioSamples: [Float] = []
    
    private var activeTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    public init(
        audioRecorder: AudioRecorder = AudioRecorder(),
        sttClient: SpeechToText = WhisperKitSTT(),
        llmClient: LLMClient = AgentOrchestrator(),
        ttsClient: TextToSpeech = KokoroTTS(),
        appleFallbackTTS: AppleTTS = AppleTTS()
    ) {
        self.audioRecorder = audioRecorder
        self.sttClient = sttClient
        self.llmClient = llmClient
        self.orchestrator = (llmClient as? AgentOrchestrator) ?? AgentOrchestrator(customClientOverride: llmClient)
        self.ttsClient = ttsClient
        self.kokoroTTS = (ttsClient as? KokoroTTS) ?? KokoroTTS()
        self.appleTTS = (ttsClient as? AppleTTS) ?? appleFallbackTTS
        
        // Link real-time audio meter updates directly to view model property
        audioRecorder.onLevelChange = { [weak self] level in
            self?.audioLevel = level
        }

        kokoroTTS.hinglishStrategy = kokoroStrategy
        kokoroTTS.hindiSpeakerID = kokoroHindiSpeakerID
        kokoroTTS.englishSpeakerID = kokoroEnglishSpeakerID
        kokoroTTS.speed = kokoroSpeed
        kokoroTTS.onFirstAudio = { [weak self] firstAudioMs in
            guard let self else { return }
            self.latency.ttsFirstAudioMs = firstAudioMs
            self.latency.ttsMs = firstAudioMs
            self.latency.totalMs = self.latency.sttMs + self.latency.llmMs + firstAudioMs
        }

        appleTTS.hinglishStrategy = ttsStrategy
        appleTTS.onFirstAudio = { [weak self] firstAudioMs in
            guard let self else { return }
            self.latency.ttsFirstAudioMs = firstAudioMs
            self.latency.ttsMs = firstAudioMs
            self.latency.totalMs = self.latency.sttMs + self.latency.llmMs + firstAudioMs
        }

        if !(sttClient is WhisperKitSTT) {
            sttLoadingState = .ready
        }

        if !(ttsClient is KokoroTTS) {
            kokoroLoadingState = .ready
        }

        if llmClient is AgentOrchestrator {
            validateAPIKeysForBanner()
        }
    }

    /// Checks whether `Secrets.groqKey` or `Secrets.geminiKey` is empty and surfaces a clear in-UI banner if so.
    public func validateAPIKeysForBanner() {
        let groqEmpty = Secrets.groqKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let geminiEmpty = Secrets.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if groqEmpty && geminiEmpty {
            errorMessage = LLMError.missingAllAPIKeys.localizedDescription
        } else if groqEmpty {
            errorMessage = LLMError.missingAPIKey(provider: .groq).localizedDescription
        } else if geminiEmpty {
            errorMessage = LLMError.missingAPIKey(provider: .gemini).localizedDescription
        }
    }

    /// Starts STT and Kokoro TTS model setup asynchronously once the app UI has appeared.
    public func prepareSpeechToText() {
        validateAPIKeysForBanner()
        prepareTextToSpeech()

        guard let whisperSTT = sttClient as? WhisperKitSTT, !isSTTReady else { return }

        Task { [weak self] in
            do {
                try await whisperSTT.prepare { [weak self] loadingState in
                    self?.sttLoadingState = loadingState
                    if case .failed(let message) = loadingState {
                        self?.errorMessage = message
                    }
                }
            } catch {
                // The state callback already contains a concise user-facing failure reason.
                print("WhisperKit model preparation error: \(error)")
            }
        }
    }

    /// Loads the bundled Kokoro multi-lang TTS model asynchronously; falls back to AppleTTS if loading fails.
    public func prepareTextToSpeech() {
        guard !isKokoroReady else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.kokoroTTS.prepare { [weak self] state in
                    guard let self else { return }
                    self.kokoroLoadingState = state
                    if case .failed = state {
                        self.ttsEngine = .apple
                    }
                }
            } catch {
                print("Kokoro TTS model preparation error (falling back to AppleTTS): \(error)")
            }
        }
    }
    
    // MARK: - Voice & Dev Text Pipeline Controls
    
    /// Toggles listening state on/off.
    public func toggleListening() {
        guard isSTTReady else { return }
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
        kokoroTTS.stop()
        appleTTS.stop()
        ttsClient.stop()
        errorMessage = nil
        validateAPIKeysForBanner()
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
            latency = LatencyMetrics()
            
            // 1. Transcribe audio
            let transcribedText = await transcribe(samples: samples)
            guard !Task.isCancelled else { return }
            guard !transcribedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                return
            }
            
            // 2. Query LLM via AgentOrchestrator with the current language toggle (streams deltas to self.response)
            let generatedAnswer = await ask(prompt: transcribedText)
            guard !Task.isCancelled else { return }
            guard !generatedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                return
            }
            
            // 3. Speak full reply (updates latency.ttsMs on first scheduled buffer / didStart and returns to .idle on completion)
            await speak(text: generatedAnswer)
            guard !Task.isCancelled else { return }
            
            // Total latency reflects time until audio begins (STT + LLM + TTS first-audio)
            latency.totalMs = latency.sttMs + latency.llmMs + latency.ttsMs
        }
    }

    /// Sends a typed text prompt directly through the agent loop (LLM -> TTS) without voice input (used by `kDevTools`).
    public func sendTextPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeTask?.cancel()
        _ = audioRecorder.stop()
        kokoroTTS.stop()
        appleTTS.stop()
        ttsClient.stop()
        audioLevel = 0.0
        errorMessage = nil
        validateAPIKeysForBanner()
        transcript = trimmed

        activeTask = Task {
            latency = LatencyMetrics(sttMs: 0)

            let generatedAnswer = await ask(prompt: trimmed)
            guard !Task.isCancelled else { return }
            guard !generatedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                return
            }

            await speak(text: generatedAnswer)
            guard !Task.isCancelled else { return }

            latency.totalMs = latency.sttMs + latency.llmMs + latency.ttsMs
        }
    }
    
    /// Cancels any active processing or speaking, returning to idle.
    public func reset() {
        activeTask?.cancel()
        activeTask = nil
        _ = audioRecorder.stop()
        kokoroTTS.stop()
        appleTTS.stop()
        ttsClient.stop()
        audioLevel = 0.0
        state = .idle
    }
    
    // MARK: - Pipeline Stage Methods
    
    /// Transcribes audio samples into text.
    /// - Parameter samples: Mono 16 kHz Float32 samples. Defaults to nil (uses last recorded audio).
    /// - Returns: Recognized transcript string.
    @discardableResult
    public func transcribe(samples: [Float]? = nil) async -> String {
        state = .transcribing
        let start = ContinuousClock.now
        
        let audio = samples ?? lastAudioSamples
        let recognized: String
        do {
            recognized = try await sttClient.transcribe(audioSamples: audio, language: language)
        } catch {
            print("STT transcription error: \(error)")
            errorMessage = error.localizedDescription
            recognized = ""
        }
        
        let elapsed = ContinuousClock.now - start
        latency.sttMs = elapsed.milliseconds
        self.transcript = recognized
        return recognized
    }
    
    /// Queries the language model via `AgentOrchestrator`, streaming text deltas to `self.response` and recording `llmFirstTokenMs` and `llmTotalMs`.
    /// - Parameter prompt: Input prompt text. Defaults to nil (uses current transcript).
    /// - Returns: Final generated response text.
    @discardableResult
    public func ask(prompt: String? = nil) async -> String {
        state = .thinking
        let start = ContinuousClock.now
        
        let inputPrompt = (prompt ?? self.transcript).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputPrompt.isEmpty else {
            return ""
        }

        self.response = ""
        self.errorMessage = nil
        validateAPIKeysForBanner()

        do {
            let turnResult = try await orchestrator.runTurn(
                userText: inputPrompt,
                language: language,
                onFirstToken: { [weak self] ttftMs in
                    Task { @MainActor [weak self] in
                        self?.latency.llmFirstTokenMs = ttftMs
                    }
                },
                onTextDelta: { [weak self] delta in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.response += delta
                    }
                },
                onSentenceReady: { [weak self] sentence in
                    // Phase 6 hook for sentence-level TTS streaming
                    Task { @MainActor [weak self] in
                        self?.onSentenceStreamed?(sentence)
                    }
                }
            )

            latency.llmFirstTokenMs = turnResult.firstTokenMs
            latency.llmTotalMs = turnResult.totalMs
            latency.llmMs = turnResult.totalMs
            lastAnsweringProvider = "\(turnResult.providerName) • \(turnResult.modelName)"
            self.response = turnResult.reply
            return turnResult.reply
        } catch is CancellationError {
            return self.response
        } catch {
            print("LLM query error: \(error)")
            let elapsed = (ContinuousClock.now - start).milliseconds
            latency.llmTotalMs = elapsed
            latency.llmMs = elapsed
            errorMessage = error.localizedDescription
            return ""
        }
    }
    
    /// Synthesizes and speaks the given response text using the locked-in TTS configuration:
    /// - **English mode (default)**: Apple `AVSpeechSynthesizer` (`Isha (Premium, en-IN)`).
    /// - **Hinglish mode (default)**: Kokoro (`hf_beta`, strategy `K2` Devanagari mix, `lang = "hi"`), falling back to Apple TTS if Kokoro fails to load.
    /// - **Dev Override (`devTTSOverrideEnabled == true`)**: Uses `ttsEngine` and `kokoroStrategy` / `ttsStrategy` only if the user explicitly touched the dev controls.
    /// `latency.ttsMs` records time-to-first-audio, while `latency.ttsTotalDurationMs` records full speech duration.
    /// - Parameter text: Response text to synthesize. Defaults to nil (uses current response).
    public func speak(text: String? = nil) async {
        let inputSpeech = (text ?? self.response).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inputSpeech.isEmpty else {
            if !Task.isCancelled {
                state = .idle
            }
            return
        }

        state = .speaking
        let start = ContinuousClock.now

        // Default routing unless the user explicitly touched a dev TTS override control:
        // English -> Apple Isha (en-IN)
        // Hinglish -> Kokoro hf_beta K2 (lang="hi")
        let useKokoro: Bool
        if devTTSOverrideEnabled {
            useKokoro = (ttsEngine == .kokoro) && kokoroTTS.isReady
        } else {
            useKokoro = (language == .hinglish) && kokoroTTS.isReady
        }

        do {
            if useKokoro {
                let activeStrategy: KokoroStrategy = devTTSOverrideEnabled ? kokoroStrategy : .k2DevanagariMixHi
                let activeSpeakerID: Int
                if devTTSOverrideEnabled {
                    activeSpeakerID = (language == .english) ? kokoroEnglishSpeakerID : kokoroHindiSpeakerID
                } else {
                    activeSpeakerID = KokoroSpeaker.defaultHindiSpeakerID
                }

                kokoroTTS.hinglishStrategy = activeStrategy
                kokoroTTS.hindiSpeakerID = KokoroSpeaker.defaultHindiSpeakerID
                kokoroTTS.speed = kokoroSpeed

                let metrics = try await kokoroTTS.speakWithMetrics(
                    text: inputSpeech,
                    language: language,
                    strategyOverride: (language == .hinglish || devTTSOverrideEnabled) ? activeStrategy : nil,
                    speakerIDOverride: activeSpeakerID,
                    speedOverride: kokoroSpeed
                )
                latency.ttsFirstAudioMs = metrics.firstAudioMs
                latency.ttsMs = metrics.firstAudioMs
                latency.ttsSynthMs = metrics.synthMs
                latency.ttsRTF = metrics.rtf
                latency.ttsTotalDurationMs = metrics.totalDurationMs
                latency.totalMs = latency.sttMs + latency.llmMs + metrics.firstAudioMs
            } else if (ttsClient is KokoroTTS) || (ttsClient is AppleTTS) {
                // English mode (Isha Premium en-IN) or automatic AppleTTS fallback if Kokoro is not ready in Hinglish mode
                latency.ttsSynthMs = 0.0
                latency.ttsRTF = 0.0
                appleTTS.hinglishStrategy = ttsStrategy
                let metrics = try await appleTTS.speakWithMetrics(
                    text: inputSpeech,
                    language: language,
                    strategyOverride: language == .hinglish ? ttsStrategy : nil,
                    voiceIdentifierOverride: language == .english ? AppleTTS.ishaVoiceInfo.id : nil
                )
                latency.ttsFirstAudioMs = metrics.firstAudioMs
                latency.ttsMs = metrics.firstAudioMs
                latency.ttsSynthMs = 0.0
                latency.ttsRTF = 0.0
                latency.ttsTotalDurationMs = metrics.totalDurationMs
                latency.totalMs = latency.sttMs + latency.llmMs + metrics.firstAudioMs
            } else {
                latency.ttsSynthMs = 0.0
                latency.ttsRTF = 0.0
                try await ttsClient.speak(text: inputSpeech, language: language)
                let elapsed = (ContinuousClock.now - start).milliseconds
                latency.ttsFirstAudioMs = elapsed
                latency.ttsMs = elapsed
                latency.ttsTotalDurationMs = elapsed
                latency.totalMs = latency.sttMs + latency.llmMs + elapsed
            }
        } catch is CancellationError {
            // Cancelled cleanly
        } catch {
            print("TTS speech synthesis error: \(error)")
            errorMessage = error.localizedDescription
        }
        
        if !Task.isCancelled {
            state = .idle
        }
    }
}
