import Foundation
import AVFoundation

// MARK: - TTS Engine Selection

/// Top-level TTS engine choice exposed in the main agent and TTS Comparison Lab.
nonisolated public enum TTSEngine: String, CaseIterable, Identifiable, Sendable {
    case kokoro = "Kokoro"
    case apple = "Apple"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .kokoro:
            return "Kokoro (sherpa-onnx)"
        case .apple:
            return "Apple (AVSpeech)"
        }
    }
}

// MARK: - Kokoro Model Loading State

/// Lifecycle state for loading the bundled `kokoro-int8-multi-lang-v1_0` model at app launch.
nonisolated public enum KokoroLoadingState: Equatable, Sendable {
    case loading
    case ready
    case failed(String)

    public var displayName: String {
        switch self {
        case .loading:
            return "Loading Kokoro TTS..."
        case .ready:
            return "Kokoro TTS Ready"
        case .failed(let message):
            return "Kokoro TTS Failed (\(message)) — Using Apple TTS"
        }
    }
}

// MARK: - Kokoro Hinglish Text Strategies

/// Runtime-selectable Hinglish synthesis strategies for Kokoro multi-lang v1.0.
nonisolated public enum KokoroStrategy: String, CaseIterable, Identifiable, Sendable {
    /// K1) Roman Hinglish text, Hindi voice (`hf_beta` default), `lang = "hi"`.
    case k1RomanizedHi = "K1_romanizedHi"
    /// K2) Devanagari for Hindi words + Latin for English words, Hindi voice (`hf_beta` default), `lang = "hi"`.
    case k2DevanagariMixHi = "K2_devanagariMixHi"
    /// K3) Roman Hinglish text, English voice (`af_heart` default), `lang = "en-us"`.
    case k3RomanizedEnUS = "K3_romanizedEnUS"

    public var id: String { rawValue }

    public var shortName: String {
        switch self {
        case .k1RomanizedHi:
            return "K1: Roman + hi"
        case .k2DevanagariMixHi:
            return "K2: Deva Mix + hi"
        case .k3RomanizedEnUS:
            return "K3: Roman + en-us"
        }
    }

    public var displayName: String {
        switch self {
        case .k1RomanizedHi:
            return "K1: Romanized + Hindi (hi)"
        case .k2DevanagariMixHi:
            return "K2: Devanagari Mix + Hindi (hi)"
        case .k3RomanizedEnUS:
            return "K3: Romanized + English (en-us)"
        }
    }

    public var subtitle: String {
        switch self {
        case .k1RomanizedHi:
            return "Roman Hinglish text spoken with Hindi voice (hf_beta, lang=\"hi\")"
        case .k2DevanagariMixHi:
            return "Hindi words in Devanagari + English words in Latin with Hindi voice (hf_beta, lang=\"hi\")"
        case .k3RomanizedEnUS:
            return "Roman Hinglish text spoken with English voice (af_heart, lang=\"en-us\")"
        }
    }

    /// `espeak-ng` language code passed to `sherpa-onnx` for phonemization.
    public var kokoroLang: String {
        switch self {
        case .k1RomanizedHi, .k2DevanagariMixHi:
            return "hi"
        case .k3RomanizedEnUS:
            return "en-us"
        }
    }

    /// Recommended default speaker ID for this strategy.
    public var defaultSpeakerID: Int {
        switch self {
        case .k1RomanizedHi, .k2DevanagariMixHi:
            return KokoroSpeaker.defaultHindiSpeakerID
        case .k3RomanizedEnUS:
            return KokoroSpeaker.defaultEnglishSpeakerID
        }
    }
}

// MARK: - Kokoro Speaker Catalog (54 Speakers in kokoro-int8-multi-lang-v1_0)

/// Speaker metadata for `kokoro-int8-multi-lang-v1_0` (54 voices across 8 languages, 24 kHz).
nonisolated public struct KokoroSpeaker: Identifiable, Equatable, Hashable, Sendable {
    /// Locked-in Hindi female speaker (`hf_beta`, ID 32).
    public static let defaultHindiSpeakerID: Int = 32
    /// Best US English female speaker (`af_heart`, ID 3).
    public static let defaultEnglishSpeakerID: Int = 3

    public let id: Int
    public let name: String
    public let languageGroup: String
    public let isHindi: Bool
    public let isEnglish: Bool
    public let isRecommended: Bool

    public init(
        id: Int,
        name: String,
        languageGroup: String,
        isHindi: Bool,
        isEnglish: Bool,
        isRecommended: Bool = false
    ) {
        self.id = id
        self.name = name
        self.languageGroup = languageGroup
        self.isHindi = isHindi
        self.isEnglish = isEnglish
        self.isRecommended = isRecommended
    }

    public var displayLabel: String {
        let defaultSuffix = (id == Self.defaultHindiSpeakerID) ? " (default)" : ""
        return "\(name)\(defaultSuffix) — \(languageGroup)"
    }

    /// The 4 voices compared in Vaani: Hindi `hf_beta` (default) and `hf_alpha`; English `af_heart` and `bf_emma`.
    public static let curatedSpeakers: [KokoroSpeaker] = [
        KokoroSpeaker(id: 32, name: "hf_beta", languageGroup: "Hindi (hi-IN) • Female", isHindi: true, isEnglish: false, isRecommended: true),
        KokoroSpeaker(id: 31, name: "hf_alpha", languageGroup: "Hindi (hi-IN) • Female", isHindi: true, isEnglish: false),
        KokoroSpeaker(id: 3, name: "af_heart", languageGroup: "English (US) • Female", isHindi: false, isEnglish: true, isRecommended: true),
        KokoroSpeaker(id: 21, name: "bf_emma", languageGroup: "English (UK) • Female", isHindi: false, isEnglish: true, isRecommended: true)
    ]

    public static let hindiAndEnglishSpeakers: [KokoroSpeaker] = curatedSpeakers

    public static func speaker(forID id: Int) -> KokoroSpeaker {
        if let match = curatedSpeakers.first(where: { $0.id == id }) {
            return match
        }
        return KokoroSpeaker(id: id, name: "speaker_\(id)", languageGroup: "Multi-Lang", isHindi: false, isEnglish: false)
    }
}

// MARK: - Kokoro Synthesis Metrics

/// Detailed timing and real-time factor (RTF) metrics for a Kokoro TTS utterance.
nonisolated public struct KokoroSynthesisMetrics: Equatable, Sendable {
    /// Time in milliseconds from `speak()` invocation until the first audio buffer is scheduled and starts playing.
    public let firstAudioMs: Double
    /// Total neural synthesis time in milliseconds inside `sherpa-onnx`.
    public let synthMs: Double
    /// Total elapsed wall-clock time in milliseconds until audio playback completes.
    public let totalDurationMs: Double
    /// Generated audio length in seconds (`totalSamples / 24000.0`).
    public let audioDurationSec: Double
    /// Real-time factor (`synthSeconds / audioDurationSec`). Values < 1.0 mean faster than real-time.
    public let rtf: Double
    /// Speaker ID used (`0...53`).
    public let speakerID: Int
    /// Speaker name (e.g., `hf_alpha`, `af_heart`).
    public let speakerName: String
    /// Phonemizer language tag (`hi` or `en-us`).
    public let lang: String
    /// Strategy identifier (`K1_romanizedHi`, `K2_devanagariMixHi`, `K3_romanizedEnUS`, `englishDefault`).
    public let strategy: String
    /// Speech speed multiplier (`0.8...1.3`).
    public let speed: Float
    /// Exact text sent to the Kokoro model (after any K2 Devanagari transliteration).
    public let spokenText: String

    public init(
        firstAudioMs: Double,
        synthMs: Double,
        totalDurationMs: Double,
        audioDurationSec: Double,
        rtf: Double,
        speakerID: Int,
        speakerName: String,
        lang: String,
        strategy: String,
        speed: Float,
        spokenText: String
    ) {
        self.firstAudioMs = firstAudioMs
        self.synthMs = synthMs
        self.totalDurationMs = totalDurationMs
        self.audioDurationSec = audioDurationSec
        self.rtf = rtf
        self.speakerID = speakerID
        self.speakerName = speakerName
        self.lang = lang
        self.strategy = strategy
        self.speed = speed
        self.spokenText = spokenText
    }
}

// MARK: - KokoroTTS Errors

nonisolated public enum KokoroTTSError: LocalizedError, Sendable {
    case modelDirectoryNotFound(String)
    case missingRequiredFiles([String])
    case engineInitializationFailed
    case modelNotReady

    public var errorDescription: String? {
        switch self {
        case .modelDirectoryNotFound(let path):
            return "Kokoro model folder not found at \(path)"
        case .missingRequiredFiles(let files):
            return "Missing Kokoro model files: \(files.joined(separator: ", "))"
        case .engineInitializationFailed:
            return "Failed to initialize sherpa-onnx Kokoro TTS engine"
        case .modelNotReady:
            return "Kokoro TTS model is not ready"
        }
    }
}

// MARK: - Streaming Callback Context

/// Thread-safe state shared between the `sherpa-onnx` C progress callback and the streaming `AVAudioPlayerNode`.
nonisolated private final class KokoroStreamContext: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled: Bool = false
    private var _firstAudioMs: Double?
    private var _scheduledChunks: Int = 0
    private var _completedChunks: Int = 0
    private var _totalSamplesScheduled: Int = 0
    private var _generationFinished: Bool = false
    private var _completionContinuation: CheckedContinuation<Void, Never>?

    let startTime: ContinuousClock.Instant
    let sampleRate: Double
    let playbackFormat: AVAudioFormat
    let playerNode: AVAudioPlayerNode
    let engine: AVAudioEngine
    let onFirstAudio: (@MainActor @Sendable (Double) -> Void)?

    init(
        startTime: ContinuousClock.Instant,
        sampleRate: Double,
        playbackFormat: AVAudioFormat,
        playerNode: AVAudioPlayerNode,
        engine: AVAudioEngine,
        onFirstAudio: (@MainActor @Sendable (Double) -> Void)?
    ) {
        self.startTime = startTime
        self.sampleRate = sampleRate
        self.playbackFormat = playbackFormat
        self.playerNode = playerNode
        self.engine = engine
        self.onFirstAudio = onFirstAudio
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    var firstAudioMs: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _firstAudioMs
    }

    var totalSamplesScheduled: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalSamplesScheduled
    }

    /// Invoked from the C progress callback or clause scheduler to enqueue a chunk of 24 kHz mono Float32 samples.
    /// Applies a 64-sample (~2.6 ms) cosine/linear edge ramp to eliminate any inter-clause boundary click.
    /// Returns `true` if synthesis should continue, `false` if cancelled.
    func enqueueSamples(_ samplesPtr: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return !isCancelled }

        lock.lock()
        if _isCancelled {
            lock.unlock()
            return false
        }
        lock.unlock()

        guard let pcmBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(count)
        ), let channelData = pcmBuffer.floatChannelData?[0] else {
            return !isCancelled
        }

        pcmBuffer.frameLength = AVAudioFrameCount(count)
        channelData.update(from: samplesPtr, count: count)

        let rampSamples = min(64, count / 4)
        if rampSamples > 1 {
            let denom = Float(rampSamples)
            for i in 0..<rampSamples {
                let gain = Float(i) / denom
                channelData[i] *= gain
                channelData[count - 1 - i] *= gain
            }
        }

        var recordedFirstAudio: Double?
        lock.lock()
        if _isCancelled {
            lock.unlock()
            return false
        }
        _scheduledChunks += 1
        _totalSamplesScheduled += count
        let isFirstChunk = (_firstAudioMs == nil)
        if isFirstChunk {
            let elapsed = (ContinuousClock.now - startTime).milliseconds
            _firstAudioMs = elapsed
            recordedFirstAudio = elapsed
        }
        lock.unlock()

        playerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.handleChunkCompleted()
        }

        if isFirstChunk {
            if !engine.isRunning {
                try? engine.start()
            }
            if !playerNode.isPlaying {
                try? playerNode.playAudio()
            }
            if let firstMs = recordedFirstAudio, let callback = onFirstAudio {
                Task { @MainActor in
                    callback(firstMs)
                }
            }
        }

        return !isCancelled
    }

    private func handleChunkCompleted() {
        var continuationToResume: CheckedContinuation<Void, Never>?
        lock.lock()
        _completedChunks += 1
        if _generationFinished && _completedChunks >= _scheduledChunks {
            continuationToResume = _completionContinuation
            _completionContinuation = nil
        }
        lock.unlock()

        continuationToResume?.resume()
    }

    /// Marks synthesis generation as finished and suspends until all scheduled audio buffers have finished playing
    /// (or `cancel()` is invoked).
    func waitForPlaybackCompletion() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            _generationFinished = true
            if _isCancelled || _completedChunks >= _scheduledChunks {
                lock.unlock()
                continuation.resume()
                return
            }
            _completionContinuation = continuation
            lock.unlock()
        }
    }

    /// Immediately cancels synthesis and resumes any awaiting playback continuation.
    func cancel() {
        var continuationToResume: CheckedContinuation<Void, Never>?
        lock.lock()
        _isCancelled = true
        continuationToResume = _completionContinuation
        _completionContinuation = nil
        lock.unlock()

        if playerNode.isPlaying {
            playerNode.stop()
        }
        if engine.isRunning {
            engine.stop()
        }

        continuationToResume?.resume()
    }
}

/// C-compatible progress callback forwarded to `SherpaOnnxOfflineTtsGenerateWithConfig`.
nonisolated private let kokoroProgressCallback: TtsProgressCallbackWithArg = { samplesPtr, numSamples, _, rawArg in
    guard let rawArg else { return 0 }
    let context = Unmanaged<KokoroStreamContext>.fromOpaque(rawArg).takeUnretainedValue()
    guard let samplesPtr, numSamples > 0 else {
        return context.isCancelled ? 0 : 1
    }
    let shouldContinue = context.enqueueSamples(samplesPtr, count: Int(numSamples))
    return shouldContinue ? 1 : 0
}

// MARK: - On-Device Kokoro TTS Service (sherpa-onnx v1.13.4)

/// On-device neural Text-To-Speech service backed by `kokoro-int8-multi-lang-v1_0` via `sherpa-onnx`.
/// Splits utterances into short clauses and streams synthesized chunks directly to `AVAudioEngine` + `AVAudioPlayerNode`
/// for low time-to-first-audio.
nonisolated public final class KokoroTTS: TextToSpeech, @unchecked Sendable {
    public static let modelFolderName = "kokoro-int8-multi-lang-v1_0"
    public static let defaultSampleRate: Double = 24_000.0
    /// Optimal CPU thread count from latency benchmark (4 threads gives lowest first-audio ms without crackle).
    public static let defaultNumThreads: Int = 4

    private let lock = NSLock()
    private var _loadingState: KokoroLoadingState = .loading
    private var _ttsWrapper: SherpaOnnxOfflineTtsWrapper?
    private var _sampleRate: Double = KokoroTTS.defaultSampleRate
    private var _hinglishStrategy: KokoroStrategy
    private var _hindiSpeakerID: Int
    private var _englishSpeakerID: Int
    private var _speed: Float
    private var _lastMetrics: KokoroSynthesisMetrics?
    private var _activeStreamContext: KokoroStreamContext?
    private var _onFirstAudio: (@MainActor @Sendable (Double) -> Void)?
    private var _onMetrics: (@MainActor @Sendable (KokoroSynthesisMetrics) -> Void)?

    /// Dedicated serial queue for C++ `sherpa-onnx` model loading and synthesis so calls never overlap.
    private let inferenceQueue = DispatchQueue(label: "com.vaani.kokoro.inference", qos: .userInitiated)
    /// Shared serial queue for `AVAudioSession` configuration (shared with `AudioRecorder` and `AppleTTS`).
    private let sessionQueue: DispatchQueue

    // MARK: - Public Thread-Safe Properties

    public var loadingState: KokoroLoadingState {
        lock.lock()
        defer { lock.unlock() }
        return _loadingState
    }

    public var isReady: Bool {
        if case .ready = loadingState { return true }
        return false
    }

    /// Selected Hinglish strategy (defaults to `.k2DevanagariMixHi`).
    public var hinglishStrategy: KokoroStrategy {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _hinglishStrategy
        }
        set {
            lock.lock()
            _hinglishStrategy = newValue
            lock.unlock()
        }
    }

    /// Selected speaker ID for Hindi/Hinglish strategies K1 & K2 (defaults to `32` `hf_beta`).
    public var hindiSpeakerID: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _hindiSpeakerID
        }
        set {
            lock.lock()
            _hindiSpeakerID = newValue
            lock.unlock()
        }
    }

    /// Selected speaker ID for English mode and strategy K3 (defaults to `3` `af_heart`).
    public var englishSpeakerID: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _englishSpeakerID
        }
        set {
            lock.lock()
            _englishSpeakerID = newValue
            lock.unlock()
        }
    }

    /// Speech speed multiplier (`0.8 ... 1.3`, default `1.0`).
    public var speed: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _speed
        }
        set {
            lock.lock()
            _speed = min(1.3, max(0.8, newValue))
            lock.unlock()
        }
    }

    /// Metrics from the most recent Kokoro utterance.
    public var lastMetrics: KokoroSynthesisMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return _lastMetrics
    }

    /// Callback invoked on `MainActor` as soon as the first audio buffer is scheduled for playback.
    public var onFirstAudio: (@MainActor @Sendable (Double) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onFirstAudio
        }
        set {
            lock.lock()
            _onFirstAudio = newValue
            lock.unlock()
        }
    }

    /// Callback invoked on `MainActor` when synthesis and playback finish.
    public var onMetrics: (@MainActor @Sendable (KokoroSynthesisMetrics) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onMetrics
        }
        set {
            lock.lock()
            _onMetrics = newValue
            lock.unlock()
        }
    }

    public nonisolated init(
        hinglishStrategy: KokoroStrategy = .k2DevanagariMixHi,
        hindiSpeakerID: Int = KokoroSpeaker.defaultHindiSpeakerID,
        englishSpeakerID: Int = KokoroSpeaker.defaultEnglishSpeakerID,
        speed: Float = 1.0,
        sessionQueue: DispatchQueue = AudioRecorder.sharedAudioSessionQueue
    ) {
        self._hinglishStrategy = hinglishStrategy
        self._hindiSpeakerID = hindiSpeakerID
        self._englishSpeakerID = englishSpeakerID
        self._speed = min(1.3, max(0.8, speed))
        self.sessionQueue = sessionQueue
    }

    // MARK: - Asynchronous Model Loading & Silent Warmup

    /// Loads `kokoro-int8-multi-lang-v1_0` from the app bundle and runs a short silent warmup synthesis on a background thread.
    public nonisolated func prepare(
        onStateChange: @escaping @MainActor @Sendable (KokoroLoadingState) -> Void
    ) async throws {
        if isReady {
            await onStateChange(.ready)
            return
        }

        updateLoadingState(.loading)
        await onStateChange(.loading)

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                inferenceQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    do {
                        try self.loadModelSync()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            updateLoadingState(.ready)
            await onStateChange(.ready)
        } catch {
            let reason = error.localizedDescription
            updateLoadingState(.failed(reason))
            await onStateChange(.failed(reason))
            throw error
        }
    }

    private nonisolated func loadModelSync() throws {
        let loadStart = ContinuousClock.now
        let fm = FileManager.default

        guard let resourceRoot = Bundle.main.resourcePath else {
            throw KokoroTTSError.modelDirectoryNotFound("Bundle.main.resourcePath is nil")
        }

        let subdirCandidate = (resourceRoot as NSString).appendingPathComponent(Self.modelFolderName)
        let modelDir: String
        if fm.fileExists(atPath: (subdirCandidate as NSString).appendingPathComponent("model.int8.onnx")) {
            modelDir = subdirCandidate
        } else if fm.fileExists(atPath: (resourceRoot as NSString).appendingPathComponent("model.int8.onnx")) {
            modelDir = resourceRoot
        } else {
            print("[KokoroTTS] ERROR: Folder \(Self.modelFolderName) not found in bundle at \(subdirCandidate)")
            throw KokoroTTSError.modelDirectoryNotFound(subdirCandidate)
        }

        let modelPath = (modelDir as NSString).appendingPathComponent("model.int8.onnx")
        let voicesPath = (modelDir as NSString).appendingPathComponent("voices.bin")
        let tokensPath = (modelDir as NSString).appendingPathComponent("tokens.txt")
        let lexiconEnPath = (modelDir as NSString).appendingPathComponent("lexicon-us-en.txt")
        let dataDirPath = (modelDir as NSString).appendingPathComponent("espeak-ng-data")
        let dictDirPath = (modelDir as NSString).appendingPathComponent("dict")

        // Verify required files and espeak-ng-data directory exist
        var missingItems: [String] = []
        for (name, path) in [
            ("model.int8.onnx", modelPath),
            ("voices.bin", voicesPath),
            ("tokens.txt", tokensPath),
            ("lexicon-us-en.txt", lexiconEnPath)
        ] {
            if !fm.fileExists(atPath: path) {
                missingItems.append(name)
            }
        }

        var isDataDir: ObjCBool = false
        if !fm.fileExists(atPath: dataDirPath, isDirectory: &isDataDir) || !isDataDir.boolValue {
            missingItems.append("espeak-ng-data/")
        }

        var isDictDir: ObjCBool = false
        let hasDictDir = fm.fileExists(atPath: dictDirPath, isDirectory: &isDictDir) && isDictDir.boolValue

        if !missingItems.isEmpty {
            print("[KokoroTTS] ERROR: Missing required model files in \(modelDir): \(missingItems.joined(separator: ", "))")
            throw KokoroTTSError.missingRequiredFiles(missingItems)
        }

        print("[KokoroTTS] Verified model bundle at \(modelDir) (espeak-ng-data: OK, dict: \(hasDictDir ? "OK" : "absent"))")

        let kokoroConfig = sherpaOnnxOfflineTtsKokoroModelConfig(
            model: modelPath,
            voices: voicesPath,
            tokens: tokensPath,
            dataDir: dataDirPath,
            lengthScale: 1.0,
            dictDir: hasDictDir ? dictDirPath : "",
            lexicon: lexiconEnPath,
            lang: "hi"
        )

        let modelConfig = sherpaOnnxOfflineTtsModelConfig(
            kokoro: kokoroConfig,
            numThreads: Self.defaultNumThreads,
            debug: 0,
            provider: "cpu"
        )

        var ttsConfig = sherpaOnnxOfflineTtsConfig(model: modelConfig)
        let wrapper = SherpaOnnxOfflineTtsWrapper(config: &ttsConfig)

        guard wrapper.tts != nil else {
            print("[KokoroTTS] ERROR: SherpaOnnxCreateOfflineTts returned nil")
            throw KokoroTTSError.engineInitializationFailed
        }

        let rate = Double(wrapper.sampleRate)
        let speakers = Int(wrapper.numSpeakers)
        let loadMs = (ContinuousClock.now - loadStart).milliseconds

        // Silent warmup synthesis so ONNX Runtime arena allocations and espeak-ng phonemizer tables are hot before first user utterance
        let warmupStart = ContinuousClock.now
        let warmupConfig = SherpaOnnxGenerationConfigSwift(
            speed: 1.0,
            sid: KokoroSpeaker.defaultHindiSpeakerID,
            extra: ["lang": "hi"]
        )
        _ = wrapper.generateWithConfig(text: "नमस्ते", config: warmupConfig, callback: nil, arg: nil)
        let warmupMs = (ContinuousClock.now - warmupStart).milliseconds

        lock.lock()
        _ttsWrapper = wrapper
        if rate > 0 {
            _sampleRate = rate
        }
        lock.unlock()

        print(String(
            format: "[KokoroTTS] Ready in %.0f ms + warmup %.0f ms (sampleRate=%.0f Hz, speakers=%d, threads=%d, provider=cpu)",
            loadMs,
            warmupMs,
            rate,
            speakers,
            Self.defaultNumThreads
        ))
    }

    private nonisolated func updateLoadingState(_ state: KokoroLoadingState) {
        lock.lock()
        _loadingState = state
        lock.unlock()
    }

    // MARK: - Clause Splitting for Low First-Audio Latency

    /// Splits an utterance into sentences or short clauses so the first clause can be synthesized and played immediately
    /// while remaining clauses are synthesized and queued onto `AVAudioPlayerNode`.
    public static nonisolated func splitIntoClauses(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let primaryDelimiters: Set<Character> = [".", "।", "?", "!", ";", ":", ",", "—", "–", "\n"]
        var rawParts: [String] = []
        var current = ""

        for ch in trimmed {
            current.append(ch)
            if primaryDelimiters.contains(ch) {
                let part = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !part.isEmpty {
                    rawParts.append(part)
                }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            rawParts.append(remainder)
        }

        // Merge tiny fragments (< 14 chars, e.g. abbreviations or short prefixes) into the following or preceding clause,
        // and split overly long unpunctuated clauses (> 55 chars) on natural Hindi/English conjunctions.
        var merged: [String] = []
        var pendingPrefix = ""

        for part in rawParts {
            let combined = pendingPrefix.isEmpty ? part : "\(pendingPrefix) \(part)"
            if combined.count < 14 {
                pendingPrefix = combined
            } else {
                merged.append(contentsOf: splitLongClauseIfNeeded(combined))
                pendingPrefix = ""
            }
        }
        if !pendingPrefix.isEmpty {
            if !merged.isEmpty {
                merged[merged.count - 1] += " " + pendingPrefix
            } else {
                merged.append(pendingPrefix)
            }
        }

        return merged.isEmpty ? [trimmed] : merged
    }

    private static nonisolated func splitLongClauseIfNeeded(_ clause: String) -> [String] {
        guard clause.count > 55 else { return [clause] }
        let conjunctions = [" और ", " लेकिन ", " पर ", " क्योंकि ", " तो ", " तथा ", " and ", " but ", " so "]
        for conj in conjunctions {
            if let range = clause.range(of: conj, options: .caseInsensitive) {
                let left = String(clause[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let right = String(clause[range.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if left.count >= 16 && right.count >= 14 {
                    return [left] + splitLongClauseIfNeeded(right)
                }
            }
        }
        return [clause]
    }

    // MARK: - TextToSpeech Protocol

    public nonisolated func speak(text: String, language: VoiceAgentViewModel.Language) async throws {
        _ = try await speakWithMetrics(text: text, language: language)
    }

    public nonisolated func stop() {
        lock.lock()
        let activeContext = _activeStreamContext
        _activeStreamContext = nil
        lock.unlock()

        activeContext?.cancel()
    }

    // MARK: - Extended Streaming Synthesis API

    /// Synthesizes and plays `text` via streaming `AVAudioPlayerNode` buffers, returning full timing and RTF metrics.
    @discardableResult
    public nonisolated func speakWithMetrics(
        text: String,
        language: VoiceAgentViewModel.Language,
        strategyOverride: KokoroStrategy? = nil,
        speakerIDOverride: Int? = nil,
        speedOverride: Float? = nil
    ) async throws -> KokoroSynthesisMetrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return KokoroSynthesisMetrics(
                firstAudioMs: 0,
                synthMs: 0,
                totalDurationMs: 0,
                audioDurationSec: 0,
                rtf: 0,
                speakerID: 0,
                speakerName: "none",
                lang: "",
                strategy: "empty",
                speed: 1.0,
                spokenText: ""
            )
        }

        guard isReady else {
            throw KokoroTTSError.modelNotReady
        }

        try Task.checkCancellation()

        // Cancel any currently playing Kokoro stream before starting a new one
        stop()

        // 1. Configure shared AVAudioSession (.playAndRecord + .defaultToSpeaker) off the main thread
        try await configurePlaybackAudioSession()

        try Task.checkCancellation()

        // 2. Resolve strategy, speaker ID, speed, phonemizer language, and text transformation
        let effectiveStrategy = strategyOverride ?? self.hinglishStrategy
        let effectiveSpeed = min(1.3, max(0.8, speedOverride ?? self.speed))
        let firstAudioCallback = self.onFirstAudio
        let metricsCallback = self.onMetrics

        let spokenText: String
        let strategyLabel: String
        let kokoroLang: String
        let speakerID: Int

        switch language {
        case .english:
            if let strategyOverride {
                strategyLabel = strategyOverride.rawValue
                kokoroLang = strategyOverride.kokoroLang
                speakerID = speakerIDOverride ?? strategyOverride.defaultSpeakerID
                spokenText = (strategyOverride == .k2DevanagariMixHi)
                    ? HinglishTransliterator.transliterate(trimmed)
                    : trimmed
            } else {
                strategyLabel = "englishDefault"
                kokoroLang = "en-us"
                speakerID = speakerIDOverride ?? self.englishSpeakerID
                spokenText = trimmed
            }
        case .hinglish:
            strategyLabel = effectiveStrategy.rawValue
            kokoroLang = effectiveStrategy.kokoroLang
            if let speakerIDOverride {
                speakerID = speakerIDOverride
            } else {
                switch effectiveStrategy {
                case .k1RomanizedHi, .k2DevanagariMixHi:
                    speakerID = self.hindiSpeakerID
                case .k3RomanizedEnUS:
                    speakerID = self.englishSpeakerID
                }
            }
            spokenText = (effectiveStrategy == .k2DevanagariMixHi)
                ? HinglishTransliterator.transliterate(trimmed)
                : trimmed
        }

        let speakerInfo = KokoroSpeaker.speaker(forID: speakerID)

        // 3. Set up AVAudioEngine + AVAudioPlayerNode for 24 kHz mono Float32 streaming
        let sampleRate = self.currentSampleRate()
        guard let playbackFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ) else {
            throw KokoroTTSError.engineInitializationFailed
        }

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        try engine.connectNode(playerNode, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()

        let utteranceStart = ContinuousClock.now
        let streamContext = KokoroStreamContext(
            startTime: utteranceStart,
            sampleRate: sampleRate,
            playbackFormat: playbackFormat,
            playerNode: playerNode,
            engine: engine,
            onFirstAudio: firstAudioCallback
        )

        setActiveStreamContext(streamContext)

        defer {
            clearActiveStreamContext(streamContext)
            streamContext.cancel()
        }

        return try await withTaskCancellationHandler {
            // 4. Split into clauses and synthesize Clause 1 immediately on inferenceQueue while queueing remaining clauses
            let (synthMs, generatedSampleCount) = try await runSynthesisOnQueue(
                spokenText: spokenText,
                speakerID: speakerID,
                speed: effectiveSpeed,
                kokoroLang: kokoroLang,
                streamContext: streamContext
            )

            // 5. Wait for all scheduled buffers on AVAudioPlayerNode to finish playing
            await streamContext.waitForPlaybackCompletion()

            let totalDurationMs = (ContinuousClock.now - utteranceStart).milliseconds
            let firstAudioMs = streamContext.firstAudioMs ?? synthMs
            let audioDurationSec = Double(generatedSampleCount) / sampleRate
            let rtf = audioDurationSec > 0 ? (synthMs / 1_000.0) / audioDurationSec : 0.0

            print(String(
                format: "[TTS DEBUG] engine=Kokoro sid=%d (%@) strategy=%@ lang=%@ speed=%.2f firstAudioMs=%.0f synthMs=%.0f rtf=%.3f text=%@",
                speakerID,
                speakerInfo.name,
                strategyLabel,
                kokoroLang,
                effectiveSpeed,
                firstAudioMs,
                synthMs,
                rtf,
                spokenText.debugDescription
            ))

            let metrics = KokoroSynthesisMetrics(
                firstAudioMs: firstAudioMs,
                synthMs: synthMs,
                totalDurationMs: totalDurationMs,
                audioDurationSec: audioDurationSec,
                rtf: rtf,
                speakerID: speakerID,
                speakerName: speakerInfo.name,
                lang: kokoroLang,
                strategy: strategyLabel,
                speed: effectiveSpeed,
                spokenText: spokenText
            )

            storeLastMetrics(metrics)
            if let metricsCallback {
                await metricsCallback(metrics)
            }

            if streamContext.isCancelled {
                throw CancellationError()
            }

            return metrics
        } onCancel: {
            streamContext.cancel()
        }
    }

    private nonisolated func runSynthesisOnQueue(
        spokenText: String,
        speakerID: Int,
        speed: Float,
        kokoroLang: String,
        streamContext: KokoroStreamContext
    ) async throws -> (synthMs: Double, sampleCount: Int) {
        let clauses = Self.splitIntoClauses(spokenText)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Double, Int), Error>) in
            inferenceQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if streamContext.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                guard let wrapper = self.currentWrapper() else {
                    continuation.resume(throwing: KokoroTTSError.modelNotReady)
                    return
                }

                let genConfig = SherpaOnnxGenerationConfigSwift(
                    speed: speed,
                    sid: speakerID,
                    extra: ["lang": kokoroLang]
                )

                var totalSynthMs: Double = 0
                var totalGeneratedSamples: Int = 0

                for clause in clauses {
                    if streamContext.isCancelled {
                        break
                    }
                    let clauseStart = ContinuousClock.now
                    let beforeScheduled = streamContext.totalSamplesScheduled

                    let unmanagedContext = Unmanaged.passRetained(streamContext)
                    let generatedAudio = wrapper.generateWithConfig(
                        text: clause,
                        config: genConfig,
                        callback: kokoroProgressCallback,
                        arg: unmanagedContext.toOpaque()
                    )
                    unmanagedContext.release()

                    totalSynthMs += (ContinuousClock.now - clauseStart).milliseconds

                    // If sherpa-onnx returned the clause samples without invoking the progress callback, schedule immediately
                    let afterScheduled = streamContext.totalSamplesScheduled
                    let fallbackSamples = generatedAudio.samples
                    if afterScheduled == beforeScheduled, !fallbackSamples.isEmpty, !streamContext.isCancelled {
                        fallbackSamples.withUnsafeBufferPointer { buffer in
                            if let base = buffer.baseAddress {
                                _ = streamContext.enqueueSamples(base, count: buffer.count)
                            }
                        }
                    }

                    totalGeneratedSamples += Int(generatedAudio.n)
                }

                let totalSamples = max(streamContext.totalSamplesScheduled, totalGeneratedSamples)
                continuation.resume(returning: (totalSynthMs, totalSamples))
            }
        }
    }

    private nonisolated func currentWrapper() -> SherpaOnnxOfflineTtsWrapper? {
        lock.lock()
        defer { lock.unlock() }
        return _ttsWrapper
    }

    private nonisolated func currentSampleRate() -> Double {
        lock.lock()
        defer { lock.unlock() }
        return _sampleRate
    }

    private nonisolated func storeLastMetrics(_ metrics: KokoroSynthesisMetrics) {
        lock.lock()
        _lastMetrics = metrics
        lock.unlock()
    }

    private nonisolated func setActiveStreamContext(_ context: KokoroStreamContext) {
        lock.lock()
        _activeStreamContext = context
        lock.unlock()
    }

    private nonisolated func clearActiveStreamContext(_ context: KokoroStreamContext) {
        lock.lock()
        if _activeStreamContext === context {
            _activeStreamContext = nil
        }
        lock.unlock()
    }

    // MARK: - Shared Audio Session Configuration

    private nonisolated func configurePlaybackAudioSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                #if os(iOS) || os(visionOS)
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setCategory(
                        .playAndRecord,
                        mode: .default,
                        options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
                    )
                    try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
                #else
                continuation.resume()
                #endif
            }
        }
    }
}

private extension Duration {
    nonisolated var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
    }
}
