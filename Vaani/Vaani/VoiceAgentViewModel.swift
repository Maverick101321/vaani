import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Single turn latency row for evaluation table and CSV export.
public struct TurnLatencyRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let turnText: String
    public let mode: String
    public let sttMs: Int
    public let llmFirstTokenMs: Int
    public let llmTotalMs: Int
    public let ttsFirstAudioMs: Int
    public let responseFirstAudioMs: Int
    public let fullDoneMs: Int

    public init(
        id: UUID = UUID(),
        turnText: String,
        mode: String,
        sttMs: Int,
        llmFirstTokenMs: Int,
        llmTotalMs: Int,
        ttsFirstAudioMs: Int,
        responseFirstAudioMs: Int,
        fullDoneMs: Int
    ) {
        self.id = id
        self.turnText = turnText
        self.mode = mode
        self.sttMs = sttMs
        self.llmFirstTokenMs = llmFirstTokenMs
        self.llmTotalMs = llmTotalMs
        self.ttsFirstAudioMs = ttsFirstAudioMs
        self.responseFirstAudioMs = responseFirstAudioMs
        self.fullDoneMs = fullDoneMs
    }
}

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
    /// Explicit time-to-first-audio in ms, measured on actual playback start.
    public var ttsFirstAudioMs: Double
    /// Total TTS synthesis time in ms (for neural TTS engines like Kokoro).
    public var ttsSynthMs: Double
    /// Real-time factor (`synthSeconds / audioDurationSeconds`) for neural TTS.
    public var ttsRTF: Double
    /// Total TTS playback duration in ms (until audio finishes playing).
    public var ttsTotalDurationMs: Double
    /// End-to-end response time in ms: from end of user speech (VAD auto-stop or tap-stop) to first audio out.
    public var totalMs: Double
    /// End-to-end time in ms: from end of user speech to the end of reply playback.
    public var fullReplyDoneMs: Double
    
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
        totalMs: Double = 0,
        fullReplyDoneMs: Double = 0
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
        self.fullReplyDoneMs = fullReplyDoneMs
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
    public var language: Language = .english {
        didSet {
            if language != oldValue {
                resetConversationHistory()
            }
        }
    }
    
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
    
    /// Selected Kokoro speech speed (`0.8 ... 1.3`, defaults to `1.1`).
    public var kokoroSpeed: Float = 1.1 {
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
    
    /// Latency breakdown metrics for STT, LLM, TTS (time-to-first-audio), and end-to-end response time (`totalMs`).
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

    /// Name of the LLM provider + model that answered the most recent turn (e.g. `"Groq • openai/gpt-oss-120b"`).
    public var lastAnsweringProvider: String?

    /// Phase 6 hook: invoked on `@MainActor` as each complete sentence/clause is streamed from the LLM.
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

    /// Outcome of the latest Calendar demo-data action, shown only in developer controls.
    public var demoEventsStatus: String?

    /// Currently scheduled Vaani alarms via AlarmKit, shown in the Dev section.
    public var scheduledAlarms: [VaaniAlarmSummary] = []

    /// Outcome of the latest Dev alarm action (`Test alarm in 1 min` / `Cancel all Vaani alarms`).
    public var alarmStatusMessage: String?

    /// Non-dev confirmation card note displayed below the response card when an alarm is scheduled.
    public var lastScheduledAlarmNote: String?

    /// Dev-only counter of K2 lexicon/loanword misses (`[K2 MISS]`).
    public var k2MissCount: Int = HinglishTransliterator.k2MissCount

    /// In-memory per-turn latency evaluation records for CSV export.
    public var turnResults: [TurnLatencyRecord] = []

    /// Status message shown in the Dev section after copying results CSV.
    public var csvCopyStatus: String?

    /// Whether the app is currently running the Dev "Offline echo test" (STT + TTS on-device with no LLM/network).
    public var isOfflineEchoActive: Bool = false
    
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
    private var currentTurnEndOfSpeechInstant: ContinuousClock.Instant?
    private var hasRecordedFirstAudioForTurn: Bool = false
    
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

        // Link energy-based VAD auto-stop callback
        audioRecorder.onVADAutoStop = { [weak self] event in
            self?.handleVADAutoStop(event)
        }

        kokoroTTS.hinglishStrategy = kokoroStrategy
        kokoroTTS.hindiSpeakerID = kokoroHindiSpeakerID
        kokoroTTS.englishSpeakerID = kokoroEnglishSpeakerID
        kokoroTTS.speed = kokoroSpeed
        kokoroTTS.onFirstAudio = { [weak self] firstAudioMs in
            guard let self else { return }
            self.latency.ttsFirstAudioMs = firstAudioMs
            self.latency.ttsMs = firstAudioMs
        }
        kokoroTTS.onPlaybackStarted = { [weak self] playbackStartedAt in
            Task { @MainActor [weak self] in
                self?.recordActualPlaybackStart(playbackStartedAt)
            }
        }

        appleTTS.hinglishStrategy = ttsStrategy
        appleTTS.onFirstAudio = { [weak self] firstAudioMs in
            guard let self else { return }
            self.latency.ttsFirstAudioMs = firstAudioMs
            self.latency.ttsMs = firstAudioMs
        }
        appleTTS.onPlaybackStarted = { [weak self] playbackStartedAt in
            Task { @MainActor [weak self] in
                self?.recordActualPlaybackStart(playbackStartedAt)
            }
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
        guard !isOfflineEchoActive else { return }
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

    /// Starts STT, Kokoro TTS, and DEBUG LLM startup self-test asynchronously once the app UI has appeared.
    public func prepareSpeechToText() {
        validateAPIKeysForBanner()
        prepareTextToSpeech()
        refreshAlarms()
        #if DEBUG
        HinglishTransliterator.runDebugSelfTestIfNeeded()
        k2MissCount = HinglishTransliterator.k2MissCount
        if llmClient is AgentOrchestrator {
            orchestrator.runStartupSelfTestIfNeeded()
        }
        #endif

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
    
    // MARK: - Voice, VAD, Offline Echo & Dev Text Pipeline Controls
    
    /// Toggles listening state on/off.
    public func toggleListening() {
        guard isSTTReady else { return }
        if state == .listening {
            stopListening()
        } else if state == .idle {
            isOfflineEchoActive = false
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
        lastScheduledAlarmNote = nil
        if !isOfflineEchoActive {
            validateAPIKeysForBanner()
        }
        state = .listening
        
        activeTask = Task {
            do {
                try await audioRecorder.start()
            } catch is CancellationError {
                // Cancelled due to rapid stop or reset - do not show error banner
            } catch {
                self.errorMessage = error.localizedDescription
                self.isOfflineEchoActive = false
                self.state = .idle
            }
        }
    }
    
    /// Stops recording manually and runs the active pipeline (normal voice turn or offline echo test).
    public func stopListening() {
        guard state == .listening else { return }
        
        let stopInstant = ContinuousClock.now
        let samples = audioRecorder.stop()
        self.lastAudioSamples = samples
        self.audioLevel = 0.0
        
        completeListeningAndProcess(samples: samples, endOfSpeechInstant: stopInstant)
    }

    /// Invoked on `@MainActor` when `AudioRecorder`'s energy-based VAD stops recording automatically.
    private func handleVADAutoStop(_ event: VADStopEvent) {
        guard state == .listening else { return }

        // The VAD callback marks the stop point; retrieve the accumulated 16 kHz samples
        // and tear down the mic engine before beginning STT.
        let samples = audioRecorder.stop()
        self.lastAudioSamples = samples
        self.audioLevel = 0.0

        // 6s no-speech timeout -> stop and show "Didn't catch that"
        if event.trigger == .timeout && !event.speechDetected {
            activeTask?.cancel()
            isOfflineEchoActive = false
            state = .idle
            errorMessage = "Didn't catch that"
            return
        }

        // Measure pipeline response time from the moment VAD auto-stop fires (end of speech detection)
        completeListeningAndProcess(samples: samples, endOfSpeechInstant: event.endOfSpeechInstant)
    }

    private func completeListeningAndProcess(
        samples: [Float],
        endOfSpeechInstant: ContinuousClock.Instant
    ) {
        activeTask?.cancel()
        currentTurnEndOfSpeechInstant = endOfSpeechInstant
        hasRecordedFirstAudioForTurn = false

        if isOfflineEchoActive {
            activeTask = Task {
                await executeOfflineEchoPipeline(samples: samples, endOfSpeechInstant: endOfSpeechInstant)
            }
            return
        }

        activeTask = Task {
            latency = LatencyMetrics()

            // 1. Transcribe audio
            let transcribedText = await transcribe(samples: samples)
            guard !Task.isCancelled else { return }
            let trimmedTranscript = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTranscript.isEmpty else {
                errorMessage = "Didn't catch that"
                state = .idle
                return
            }

            // 2. Stream LLM + Sentence/Clause Streaming TTS
            await executeStreamingAgentTurn(
                prompt: trimmedTranscript,
                endOfSpeechInstant: endOfSpeechInstant
            )
        }
    }

    /// Starts or stops the Dev "Offline echo test": records with VAD auto-stop, transcribes with Whisper on-device,
    /// and speaks the transcript back with the locked TTS for the selected language (no LLM or network call).
    public func startOfflineEchoTest() {
        guard isSTTReady else {
            errorMessage = "Whisper STT is still loading."
            return
        }
        if isOfflineEchoActive && state == .listening {
            stopListening()
            return
        }
        isOfflineEchoActive = true
        response = ""
        transcript = ""
        startListening()
    }

    private func executeOfflineEchoPipeline(
        samples: [Float],
        endOfSpeechInstant: ContinuousClock.Instant
    ) async {
        defer {
            if !Task.isCancelled {
                isOfflineEchoActive = false
            }
        }

        latency = LatencyMetrics()
        let transcribedText = await transcribe(samples: samples)
        guard !Task.isCancelled else { return }
        let trimmed = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Didn't catch that"
            state = .idle
            return
        }

        self.response = trimmed
        self.lastAnsweringProvider = "Offline Echo (Whisper + On-Device TTS)"
        await speak(text: trimmed)
        guard !Task.isCancelled else { return }

        recordTurnLatency(turnText: "[Offline] \(trimmed)")
    }

    /// Sends a typed text prompt directly through the agent loop (LLM -> Streaming TTS) without voice input (used by `kDevTools`).
    public func sendTextPrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        activeTask?.cancel()
        isOfflineEchoActive = false
        _ = audioRecorder.stop()
        kokoroTTS.stop()
        appleTTS.stop()
        ttsClient.stop()
        audioLevel = 0.0
        errorMessage = nil
        lastScheduledAlarmNote = nil
        validateAPIKeysForBanner()
        transcript = trimmed

        let promptStartInstant = ContinuousClock.now
        currentTurnEndOfSpeechInstant = promptStartInstant
        hasRecordedFirstAudioForTurn = false

        activeTask = Task {
            latency = LatencyMetrics(sttMs: 0)
            await executeStreamingAgentTurn(
                prompt: trimmed,
                endOfSpeechInstant: promptStartInstant
            )
        }
    }

    /// Executes `AgentOrchestrator.runTurn` while streaming sentence/clause chunks (`>= 4` words) directly into the active TTS engine's
    /// playback queue (`AVAudioPlayerNode` for Kokoro, `AVSpeechSynthesizer` for Apple Isha) so audio starts while the LLM is still streaming.
    private func executeStreamingAgentTurn(
        prompt: String,
        endOfSpeechInstant: ContinuousClock.Instant
    ) async {
        state = .thinking
        self.response = ""
        self.errorMessage = nil
        self.lastScheduledAlarmNote = nil
        validateAPIKeysForBanner()

        let llmStartInstant = ContinuousClock.now
        var llmFirstTokenInstant: ContinuousClock.Instant?
        var streamedChunkCount = 0

        let kokoroFailed: Bool
        if case .failed = kokoroLoadingState {
            kokoroFailed = true
        } else {
            kokoroFailed = false
        }
        let useKokoro: Bool
        if devTTSOverrideEnabled {
            useKokoro = (ttsEngine == .kokoro) && !kokoroFailed
        } else {
            useKokoro = (language == .hinglish) && !kokoroFailed
        }
        let supportsStreamingQueue = useKokoro || (ttsClient is KokoroTTS) || (ttsClient is AppleTTS)

        // Serial async task chain so chunk N+1 is synthesized/queued in strict order right after chunk N is scheduled
        var serialTTSChain: Task<Void, Never>?

        let enqueueChunkForStreamingTTS: @MainActor (String) -> Void = { [weak self] rawChunk in
            guard let self else { return }
            let trimmedChunk = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedChunk.isEmpty else { return }

            streamedChunkCount += 1
            let chunkIndex = streamedChunkCount
            let isFirstChunk = (chunkIndex == 1)
            let refInstant = llmFirstTokenInstant ?? llmStartInstant
            let readyMs = max(0, (ContinuousClock.now - refInstant).milliseconds)
            let previousTask = serialTTSChain

            serialTTSChain = Task { @MainActor [weak self] in
                if let previousTask {
                    await previousTask.value
                }
                guard let self, !Task.isCancelled else { return }
                await self.synthesizeAndQueueStreamingChunk(
                    chunk: trimmedChunk,
                    chunkIndex: chunkIndex,
                    isFirstChunk: isFirstChunk,
                    readyMs: readyMs,
                    useKokoro: useKokoro,
                    endOfSpeechInstant: endOfSpeechInstant
                )
            }
        }

        do {
            let turnResult = try await orchestrator.runTurn(
                userText: prompt,
                language: language,
                onFirstToken: { [weak self] ttftMs in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if llmFirstTokenInstant == nil {
                            llmFirstTokenInstant = ContinuousClock.now
                        }
                        self.latency.llmFirstTokenMs = ttftMs
                    }
                },
                onTextDelta: { [weak self] delta in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if llmFirstTokenInstant == nil {
                            llmFirstTokenInstant = ContinuousClock.now
                        }
                        self.response += delta
                    }
                },
                onSentenceReady: { [weak self] chunk in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.onSentenceStreamed?(chunk)
                        if supportsStreamingQueue {
                            enqueueChunkForStreamingTTS(chunk)
                        }
                    }
                }
            )

            // Allow any pending @MainActor tasks from onFirstToken/onTextDelta/onSentenceReady to drain before checking streamedChunkCount
            await Task.yield()
            guard !Task.isCancelled else { return }

            latency.llmFirstTokenMs = turnResult.firstTokenMs
            latency.llmTotalMs = turnResult.totalMs
            latency.llmMs = turnResult.totalMs
            lastAnsweringProvider = "\(turnResult.providerName) • \(turnResult.modelName)"
            self.response = turnResult.reply

            if turnResult.executedToolCalls.contains(where: { $0.name == "set_alarm" }) {
                refreshAlarms()
                for (index, toolCall) in turnResult.executedToolCalls.enumerated() where toolCall.name == "set_alarm" {
                    if index < turnResult.executedToolOutputs.count,
                       let note = Self.extractAlarmConfirmationNote(from: turnResult.executedToolOutputs[index]) {
                        self.lastScheduledAlarmNote = note
                    }
                }
            }

            let finalReply = turnResult.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !finalReply.isEmpty else {
                state = .idle
                return
            }

            if supportsStreamingQueue {
                if streamedChunkCount == 0 {
                    // Fallback if reply was synthesized deterministically after tool execution without streamed deltas
                    for chunk in SentenceStreamBuffer.splitText(finalReply, language: language) {
                        enqueueChunkForStreamingTTS(chunk)
                    }
                }
                if let serialTTSChain {
                    await serialTTSChain.value
                }
                guard !Task.isCancelled else { return }
                await finalizeStreamingTurnPlayback(useKokoro: useKokoro)
            } else {
                await speak(text: finalReply)
            }

            guard !Task.isCancelled else { return }
            recordTurnLatency(turnText: prompt)
            state = .idle
        } catch is CancellationError {
            return
        } catch {
            print("LLM query error: \(error)")
            let elapsed = (ContinuousClock.now - llmStartInstant).milliseconds
            latency.llmTotalMs = elapsed
            latency.llmMs = elapsed
            errorMessage = error.localizedDescription
            state = .idle
        }
    }

    private func synthesizeAndQueueStreamingChunk(
        chunk: String,
        chunkIndex: Int,
        isFirstChunk: Bool,
        readyMs: Double,
        useKokoro: Bool,
        endOfSpeechInstant: ContinuousClock.Instant
    ) async {
        if state != .speaking {
            state = .speaking
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

                let result = try await kokoroTTS.enqueueStreamingChunk(
                    text: chunk,
                    language: language,
                    isFirstChunk: isFirstChunk,
                    strategyOverride: (language == .hinglish || devTTSOverrideEnabled) ? activeStrategy : nil,
                    speakerIDOverride: activeSpeakerID,
                    speedOverride: kokoroSpeed
                )
                print("[PIPE] chunk=\(chunkIndex) chars=\(chunk.count) synth_ms=\(Int(result.synthMs.rounded())) firstAudio_ms=\(Int(result.firstAudioMs.rounded())) text=\(chunk.debugDescription) ready_ms=\(Int(readyMs.rounded()))")
            } else {
                appleTTS.hinglishStrategy = ttsStrategy
                let chunkFirstAudioMs = try await appleTTS.enqueueStreamingChunk(
                    text: chunk,
                    language: language,
                    isFirstChunk: isFirstChunk,
                    strategyOverride: language == .hinglish ? ttsStrategy : nil,
                    voiceIdentifierOverride: language == .english ? AppleTTS.ishaVoiceInfo.id : nil
                )
                print("[PIPE] chunk=\(chunkIndex) chars=\(chunk.count) synth_ms=0 firstAudio_ms=\(Int(chunkFirstAudioMs.rounded())) text=\(chunk.debugDescription) ready_ms=\(Int(readyMs.rounded()))")
            }
        } catch is CancellationError {
            // Cancelled cleanly
        } catch {
            print("Streaming TTS chunk error: \(error)")
        }
    }

    private func finalizeStreamingTurnPlayback(useKokoro: Bool) async {
        if useKokoro {
            if let metrics = await kokoroTTS.finishStreamingTurn() {
                latency.ttsFirstAudioMs = metrics.firstAudioMs
                latency.ttsMs = metrics.firstAudioMs
                latency.ttsSynthMs = metrics.synthMs
                latency.ttsRTF = metrics.rtf
                latency.ttsTotalDurationMs = metrics.totalDurationMs
            }
        } else {
            if let metrics = await appleTTS.finishStreamingTurn() {
                latency.ttsFirstAudioMs = metrics.firstAudioMs
                latency.ttsMs = metrics.firstAudioMs
                latency.ttsSynthMs = 0.0
                latency.ttsRTF = 0.0
                latency.ttsTotalDurationMs = metrics.totalDurationMs
            }
        }
        markFullReplyDone()
        k2MissCount = HinglishTransliterator.k2MissCount
    }

    /// Records the actual hardware playback start captured by AVSpeechSynthesizer's `didStart`
    /// or Kokoro's AVAudioEngine mixer render tap.
    private func recordActualPlaybackStart(_ playbackStartedAt: ContinuousClock.Instant) {
        guard !hasRecordedFirstAudioForTurn else { return }
        hasRecordedFirstAudioForTurn = true
        if let endOfSpeech = currentTurnEndOfSpeechInstant {
            latency.totalMs = (playbackStartedAt - endOfSpeech).milliseconds
        }
    }

    /// Records the true end of the final queued audio buffer, separately from first audio.
    private func markFullReplyDone() {
        guard let endOfSpeech = currentTurnEndOfSpeechInstant else { return }
        latency.fullReplyDoneMs = (ContinuousClock.now - endOfSpeech).milliseconds
    }

    private func recordTurnLatency(turnText: String) {
        let sttVal = Int(latency.sttMs.rounded())
        let llm1stVal = Int(latency.llmFirstTokenMs.rounded())
        let llmTotalVal = Int(latency.llmTotalMs.rounded())
        let tts1stVal = Int(latency.ttsFirstAudioMs.rounded())
        let responseVal = Int(latency.totalMs.rounded())
        let fullDoneVal = Int(latency.fullReplyDoneMs.rounded())
        let modeVal = language.rawValue

        print("[LATENCY] stt=\(sttVal) llm1st=\(llm1stVal) llmTotal=\(llmTotalVal) tts1st=\(tts1stVal) response_first_audio=\(responseVal) full_done=\(fullDoneVal) mode=\(modeVal)")

        let record = TurnLatencyRecord(
            turnText: turnText,
            mode: modeVal,
            sttMs: sttVal,
            llmFirstTokenMs: llm1stVal,
            llmTotalMs: llmTotalVal,
            ttsFirstAudioMs: tts1stVal,
            responseFirstAudioMs: responseVal,
            fullDoneMs: fullDoneVal
        )
        turnResults.append(record)
    }

    /// Formats all recorded turns as CSV and copies them to the system clipboard for the evaluation table.
    @discardableResult
    public func copyResultsCSV() -> String {
        var lines: [String] = [
            "turn_text,mode,stt,llm1st,llmTotal,tts1st,response_first_audio,full_done"
        ]
        for row in turnResults {
            let escapedText = row.turnText.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(escapedText)\",\(row.mode),\(row.sttMs),\(row.llmFirstTokenMs),\(row.llmTotalMs),\(row.ttsFirstAudioMs),\(row.responseFirstAudioMs),\(row.fullDoneMs)")
        }
        let csv = lines.joined(separator: "\n")
        #if canImport(UIKit)
        UIPasteboard.general.string = csv
        #endif
        csvCopyStatus = "Copied \(turnResults.count) turn(s) to clipboard"
        print("[LATENCY CSV]\n\(csv)")
        return csv
    }

    /// Human-readable description of the active TTS engine and voice for the Dev section.
    public var currentTTSEngineDescription: String {
        if devTTSOverrideEnabled {
            switch ttsEngine {
            case .apple:
                return "Apple Isha (en-IN) [Override]"
            case .kokoro:
                let speaker = (language == .hinglish) ? kokoroHindiSpeakerID : kokoroEnglishSpeakerID
                return "Kokoro \(speaker) (\(kokoroStrategy.rawValue)) [Override]"
            }
        }
        switch language {
        case .english:
            return "Apple Isha (Premium, en-IN) [Locked]"
        case .hinglish:
            return kokoroTTS.isReady
                ? "Kokoro hf_beta (K2 Devanagari) [Locked]"
                : "Apple Isha (Fallback • Kokoro loading)"
        }
    }

    /// Clears any dev TTS override and restores the locked routing (`English = Apple Isha`, `Hinglish = Kokoro hf_beta K2`).
    public func resetDevTTSOverride() {
        devTTSOverrideEnabled = false
        kokoroHindiSpeakerID = KokoroSpeaker.defaultHindiSpeakerID
        kokoroStrategy = .k2DevanagariMixHi
        kokoroSpeed = 1.1
        ttsStrategy = .romanizedHiIN
        ttsEngine = (language == .hinglish) ? .kokoro : .apple
    }

    /// Clears the conversation history in `AgentOrchestrator` (called automatically when the language toggle changes).
    public func resetConversationHistory() {
        Task { [weak self] in
            await self?.orchestrator.clearHistory()
        }
    }

    public func seedDemoEvents() {
        guard let tools = orchestrator.toolExecutor as? VaaniToolExecutor else {
            demoEventsStatus = "Real tools are unavailable."
            return
        }
        Task { [weak self] in
            let result = await tools.seedDemoEvents()
            self?.demoEventsStatus = result
        }
    }

    public func clearDemoEvents() {
        guard let tools = orchestrator.toolExecutor as? VaaniToolExecutor else {
            demoEventsStatus = "Real tools are unavailable."
            return
        }
        Task { [weak self] in
            let result = await tools.clearDemoEvents()
            self?.demoEventsStatus = result
        }
    }

    /// Refreshes the list of scheduled AlarmKit alarms for the Dev section.
    public func refreshAlarms() {
        guard let tools = orchestrator.toolExecutor as? VaaniToolExecutor else {
            scheduledAlarms = []
            return
        }
        scheduledAlarms = tools.fetchScheduledAlarms()
    }

    /// Schedules a 1-minute test alarm via `VaaniToolExecutor` and refreshes the alarm list.
    public func testAlarmInOneMinute() {
        guard let tools = orchestrator.toolExecutor as? VaaniToolExecutor else {
            alarmStatusMessage = "Real tools are unavailable."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let jsonResult = await tools.scheduleTestAlarmInOneMinute()
            self.refreshAlarms()
            if let note = Self.extractAlarmConfirmationNote(from: jsonResult) {
                self.lastScheduledAlarmNote = note
                self.alarmStatusMessage = note
            } else {
                self.alarmStatusMessage = jsonResult
            }
        }
    }

    /// Cancels all scheduled Vaani alarms via `VaaniToolExecutor` and refreshes the alarm list.
    public func cancelAllVaaniAlarms() {
        guard let tools = orchestrator.toolExecutor as? VaaniToolExecutor else {
            alarmStatusMessage = "Real tools are unavailable."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let status = await tools.cancelAllVaaniAlarms()
            self.alarmStatusMessage = status
            self.lastScheduledAlarmNote = nil
            self.refreshAlarms()
        }
    }

    private static func extractAlarmConfirmationNote(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = dict["status"] as? String,
              (status == "success" || status == "already_exists") else {
            return nil
        }
        let timeText = (dict["time_spoken"] as? String)
            ?? (dict["time_iso"] as? String)
            ?? "scheduled time"
        if status == "already_exists" {
            return "Alarm already set for \(timeText) (shows on lock screen when it rings; AlarmKit alarms are not listed in the Clock app)"
        }
        return "Alarm set for \(timeText) (shows on lock screen when it rings; AlarmKit alarms are not listed in the Clock app)"
    }
    
    /// Cancels any active processing or speaking, returning to idle.
    public func reset() {
        activeTask?.cancel()
        activeTask = nil
        isOfflineEchoActive = false
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
        self.lastScheduledAlarmNote = nil
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

            if turnResult.executedToolCalls.contains(where: { $0.name == "set_alarm" }) {
                refreshAlarms()
                for (index, toolCall) in turnResult.executedToolCalls.enumerated() where toolCall.name == "set_alarm" {
                    if index < turnResult.executedToolOutputs.count,
                       let note = Self.extractAlarmConfirmationNote(from: turnResult.executedToolOutputs[index]) {
                        self.lastScheduledAlarmNote = note
                    }
                }
            }

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
            } else {
                latency.ttsSynthMs = 0.0
                latency.ttsRTF = 0.0
                try await ttsClient.speak(text: inputSpeech, language: language)
                let elapsed = (ContinuousClock.now - start).milliseconds
                latency.ttsFirstAudioMs = elapsed
                latency.ttsMs = elapsed
                latency.ttsTotalDurationMs = elapsed
            }
        } catch is CancellationError {
            // Cancelled cleanly
        } catch {
            print("TTS speech synthesis error: \(error)")
            errorMessage = error.localizedDescription
        }
        
        k2MissCount = HinglishTransliterator.k2MissCount

        if !Task.isCancelled {
            markFullReplyDone()
        }

        if !Task.isCancelled {
            state = .idle
        }
    }
}
