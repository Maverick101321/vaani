import Foundation
import AVFoundation
import Observation

public enum AudioRecorderError: LocalizedError {
    case permissionDenied
    case unsupportedAudioFormat
    case invalidSampleRate
    case converterCreationFailed
    case engineStartFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone recording permission was denied."
        case .unsupportedAudioFormat:
            return "Target 16 kHz mono Float32 audio format is not supported."
        case .invalidSampleRate:
            return "Input audio device returned an invalid sample rate."
        case .converterCreationFailed:
            return "Failed to initialize AVAudioConverter for sample conversion."
        case .engineStartFailed(let error):
            return "Failed to start AVAudioEngine: \(error.localizedDescription)"
        }
    }
}

/// Reason why recording stopped (VAD silence, manual tap, or timeout).
nonisolated public enum VADStopTrigger: String, Sendable {
    case silence = "silence"
    case manual = "manual"
    case timeout = "timeout"
}

/// Metadata emitted when VAD or manual stop ends a recording session.
nonisolated public struct VADStopEvent: Sendable {
    public let trigger: VADStopTrigger
    public let speechDetected: Bool
    public let speechStartMs: Int
    public let endOfSpeechMs: Int
    public let silenceMs: Int
    public let endOfSpeechInstant: ContinuousClock.Instant

    public init(
        trigger: VADStopTrigger,
        speechDetected: Bool,
        speechStartMs: Int,
        endOfSpeechMs: Int,
        silenceMs: Int = 0,
        endOfSpeechInstant: ContinuousClock.Instant
    ) {
        self.trigger = trigger
        self.speechDetected = speechDetected
        self.speechStartMs = speechStartMs
        self.endOfSpeechMs = endOfSpeechMs
        self.silenceMs = silenceMs
        self.endOfSpeechInstant = endOfSpeechInstant
    }
}

/// AVAudioEngine-based microphone capture service.
/// Records mono 16 kHz Float32 PCM samples and exposes real-time audio levels and energy-based VAD auto-stop.
@Observable
nonisolated public final class AudioRecorder: @unchecked Sendable {
    // MARK: - VAD Constants

    /// Ignore the first 300 ms of audio after mic start to skip tap/Pop transients.
    public static let vadInitialIgnoreMs: Double = 300.0
    /// Energy threshold in dB above which speech is detected.
    public static let vadSpeechThresholdDB: Float = -45.0
    /// Short hangover (ms) after energy dips below threshold before silence counting begins.
    public static let vadHangoverMs: Double = 150.0
    /// Total silence duration (ms) following detected speech before auto-stopping (800 ms).
    public static let vadSilenceAutoStopMs: Double = 800.0
    /// Timeout (ms) when no speech is detected at all (6 s).
    public static let vadNoSpeechTimeoutMs: Double = 6000.0
    /// Maximum recording duration (ms) before automatic cutoff (15 s).
    public static let vadMaxRecordingMs: Double = 15000.0

    // MARK: - Properties
    
    /// Live audio input level for metering, normalized between 0.0 and 1.0.
    public var audioLevel: Float = 0.0
    
    /// True while recording is active.
    public private(set) var isRecording: Bool = false
    
    /// Optional callback invoked on MainActor when the live audio level changes.
    @ObservationIgnored
    public var onLevelChange: (@MainActor @Sendable (Float) -> Void)?

    /// Optional callback invoked on MainActor when VAD automatically triggers a stop (`silence` or `timeout`).
    @ObservationIgnored
    public var onVADAutoStop: (@MainActor @Sendable (VADStopEvent) -> Void)?
    
    // MARK: - Concurrency & Synchronization
    
    /// Shared serial queue for all AVAudioSession configuration, setActive calls,
    /// AVAudioEngine start/stop operations, and TTS session transitions off the main thread.
    public static let sharedAudioSessionQueue = DispatchQueue(label: "com.vaani.AudioSessionQueue", qos: .userInitiated)
    
    private let audioQueue: DispatchQueue = AudioRecorder.sharedAudioSessionQueue
    
    private let lock = NSLock()
    private var recordedSamples: [Float] = []
    private var smoothedLevel: Float = 0.0
    private var bufferCount: Int = 0
    private var minDB: Float = .greatestFiniteMagnitude
    private var maxDB: Float = -.greatestFiniteMagnitude

    // VAD state protected by `lock`
    private var recordingStartInstant: ContinuousClock.Instant = .now
    private var speechDetected: Bool = false
    private var consecutiveSpeechBuffers: Int = 0
    private var candidateSpeechStartMs: Double?
    private var speechStartMs: Int = -1
    private var lastSpeechActivityMs: Double = 0.0
    private var didEmitVADStop: Bool = false
    private var lastVADStopEvent: VADStopEvent?
    
    // Engine lifecycle state - accessed strictly on audioQueue
    private var audioEngine: AVAudioEngine?
    private var hasInstalledTap: Bool = false
    private var isEngineActive: Bool = false
    
    // MARK: - Initialization
    
    public nonisolated init() {}
    
    // MARK: - Permission
    
    /// Requests microphone recording permission via AVAudioApplication.
    /// - Returns: True if permission is granted, false otherwise.
    public func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
    
    // MARK: - Recording Control
    
    /// Requests permission, configures AVAudioSession, and starts audio recording off the main thread.
    public func start() async throws {
        let granted = await requestRecordPermission()
        guard granted else {
            throw AudioRecorderError.permissionDenied
        }
        
        try Task.checkCancellation()
        
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                audioQueue.async { [weak self] in
                    guard let self = self else {
                        continuation.resume()
                        return
                    }
                    do {
                        try self.performStart()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { [weak self] in
            self?.audioQueue.async {
                self?.performStop()
            }
        }
        
        if Task.isCancelled {
            audioQueue.async { [weak self] in
                self?.performStop()
            }
            throw CancellationError()
        }
    }
    
    /// Configures audio session and begins capturing microphone input into mono 16 kHz Float32 samples.
    /// Runs exclusively on audioQueue off the main thread.
    private func performStart() throws {
        if isEngineActive || audioEngine != nil {
            performStop()
        }
        
        #if os(iOS) || os(visionOS)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // Use inputNode.outputFormat(forBus: 0) as required for installTap
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        guard inputFormat.sampleRate > 0 else {
            throw AudioRecorderError.invalidSampleRate
        }
        
        // Target format: Mono 16 kHz Float32
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioRecorderError.unsupportedAudioFormat
        }
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterCreationFailed
        }
        
        let startInstant = ContinuousClock.now
        lock.lock()
        recordedSamples.removeAll()
        smoothedLevel = 0.0
        bufferCount = 0
        minDB = .greatestFiniteMagnitude
        maxDB = -.greatestFiniteMagnitude
        recordingStartInstant = startInstant
        speechDetected = false
        consecutiveSpeechBuffers = 0
        candidateSpeechStartMs = nil
        speechStartMs = -1
        lastSpeechActivityMs = 0.0
        didEmitVADStop = false
        lastVADStopEvent = nil
        lock.unlock()
        
        if hasInstalledTap {
            inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        
        try inputNode.__installTap(onBus: 0, bufferSize: 1024, format: inputFormat, error: ()) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // 1. Compute RMS from raw input buffer inside installTap BEFORE any resampling
            guard let channelData = buffer.floatChannelData else { return }
            let channelCount = Int(buffer.format.channelCount)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { return }
            
            var sumSquares: Float = 0
            for channel in 0..<channelCount {
                let channelSamples = channelData[channel]
                for frame in 0..<frameLength {
                    let sample = channelSamples[frame]
                    sumSquares += sample * sample
                }
            }
            let totalSampleCount = Float(frameLength * channelCount)
            let rms: Float = totalSampleCount > 0 ? sqrt(sumSquares / totalSampleCount) : 0
            
            // Convert to dB: 20 * log10(max(rms, 0.00001))
            let dB = 20.0 * log10(max(rms, 0.00001))
            
            // Normalize: dB range -55 to -20: level = clamp((dB + 55) / 35, 0, 1), then curve: level = pow(level, 0.6)
            let clamped = min(max((dB + 55.0) / 35.0, 0.0), 1.0)
            let rawLevel = pow(clamped, 0.6)
            
            let nowInstant = ContinuousClock.now
            var autoStopEventToEmit: VADStopEvent? = nil

            // Smoothing + VAD state machine under lock
            self.lock.lock()
            let oldLevel = self.smoothedLevel
            let smoothed: Float
            if rawLevel > oldLevel {
                smoothed = (0.7 * rawLevel) + (0.3 * oldLevel)
            } else {
                smoothed = (0.2 * rawLevel) + (0.8 * oldLevel)
            }
            self.smoothedLevel = smoothed
            let currentLevel = smoothed
            
            // Track min and max dB seen so far for calibration
            if dB < self.minDB { self.minDB = dB }
            if dB > self.maxDB { self.maxDB = dB }
            let currentMinDB = self.minDB
            let currentMaxDB = self.maxDB
            
            self.bufferCount += 1
            let count = self.bufferCount

            let elapsedMs = Self.milliseconds(from: self.recordingStartInstant, to: nowInstant)
            if !self.didEmitVADStop && elapsedMs >= Self.vadInitialIgnoreMs {
                let isSpeechFrame = dB >= Self.vadSpeechThresholdDB
                if isSpeechFrame {
                    self.consecutiveSpeechBuffers += 1
                    if self.candidateSpeechStartMs == nil {
                        self.candidateSpeechStartMs = elapsedMs
                    }
                    // Require at least 2 consecutive speech frames (~40ms) to confirm speech onset
                    if !self.speechDetected && self.consecutiveSpeechBuffers >= 2 {
                        self.speechDetected = true
                        self.speechStartMs = Int((self.candidateSpeechStartMs ?? elapsedMs).rounded())
                    }
                    if self.speechDetected {
                        // Extend speech activity with short hangover
                        self.lastSpeechActivityMs = elapsedMs + Self.vadHangoverMs
                    }
                } else {
                    self.consecutiveSpeechBuffers = 0
                    if !self.speechDetected {
                        self.candidateSpeechStartMs = nil
                    }
                }

                // Check VAD stop conditions:
                // (a) ~800 ms of silence after speech was detected (accounting for hangover)
                let silenceSinceLastVoiceMs = elapsedMs - (self.lastSpeechActivityMs - Self.vadHangoverMs)
                if self.speechDetected && elapsedMs > self.lastSpeechActivityMs && silenceSinceLastVoiceMs >= Self.vadSilenceAutoStopMs {
                    self.didEmitVADStop = true
                    let endMs = Int(elapsedMs.rounded())
                    let measuredSilenceMs = max(0, Int(silenceSinceLastVoiceMs.rounded()))
                    let event = VADStopEvent(
                        trigger: .silence,
                        speechDetected: true,
                        speechStartMs: self.speechStartMs,
                        endOfSpeechMs: endMs,
                        silenceMs: measuredSilenceMs,
                        endOfSpeechInstant: nowInstant
                    )
                    self.lastVADStopEvent = event
                    autoStopEventToEmit = event
                } else if !self.speechDetected && elapsedMs >= Self.vadNoSpeechTimeoutMs {
                    // (b) No speech detected within 6 s -> stop and show "Didn't catch that"
                    self.didEmitVADStop = true
                    let endMs = Int(elapsedMs.rounded())
                    let event = VADStopEvent(
                        trigger: .timeout,
                        speechDetected: false,
                        speechStartMs: -1,
                        endOfSpeechMs: endMs,
                        silenceMs: endMs,
                        endOfSpeechInstant: nowInstant
                    )
                    self.lastVADStopEvent = event
                    autoStopEventToEmit = event
                } else if elapsedMs >= Self.vadMaxRecordingMs {
                    // (c) Max recording 15 s
                    self.didEmitVADStop = true
                    let endMs = Int(elapsedMs.rounded())
                    let measuredSilenceMs = self.speechDetected ? max(0, Int(silenceSinceLastVoiceMs.rounded())) : endMs
                    let event = VADStopEvent(
                        trigger: .timeout,
                        speechDetected: self.speechDetected,
                        speechStartMs: self.speechStartMs,
                        endOfSpeechMs: endMs,
                        silenceMs: measuredSilenceMs,
                        endOfSpeechInstant: nowInstant
                    )
                    self.lastVADStopEvent = event
                    autoStopEventToEmit = event
                }
            }
            self.lock.unlock()
            let autoStopEvent = autoStopEventToEmit
            
            // DEBUG: Print RMS, dB, min/max dB, and level every ~10 buffers for calibration
            if count % 10 == 0 {
                print(String(format: "[AudioRecorder DEBUG] buffer #%d | RMS: %.5f | dB: %.2f (min: %.2f, max: %.2f) | Level: %.3f", count, rms, dB, currentMinDB, currentMaxDB, currentLevel))
            }
            
            // Dispatch level update (and optional VAD auto-stop) to MainActor
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.audioLevel = currentLevel
                self.onLevelChange?(currentLevel)
                if let event = autoStopEvent {
                    print("[VAD] speechStart=\(event.speechStartMs) endOfSpeech=\(event.endOfSpeechMs) silence_ms=\(event.silenceMs) trigger=\(event.trigger.rawValue)")
                    self.onVADAutoStop?(event)
                }
            }
            
            // 2. Resample to mono 16 kHz Float32 samples
            let sampleRateRatio = targetFormat.sampleRate / inputFormat.sampleRate
            let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio) + 512
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                return
            }
            
            var isConsumed = false
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if !isConsumed {
                    isConsumed = true
                    outStatus.pointee = .haveData
                    return buffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            
            if (status == .haveData || status == .inputRanDry), error == nil {
                if let convertedData = convertedBuffer.floatChannelData {
                    let count = Int(convertedBuffer.frameLength)
                    if count > 0 {
                        let samples = Array(UnsafeBufferPointer(start: convertedData[0], count: count))
                        self.lock.lock()
                        self.recordedSamples.append(contentsOf: samples)
                        self.lock.unlock()
                    }
                }
            }
        }
        hasInstalledTap = true
        
        do {
            try engine.start()
            self.audioEngine = engine
            self.isEngineActive = true
            Task { @MainActor [weak self] in
                self?.isRecording = true
            }
        } catch {
            if hasInstalledTap {
                inputNode.removeTap(onBus: 0)
                hasInstalledTap = false
            }
            #if os(iOS) || os(visionOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw AudioRecorderError.engineStartFailed(error)
        }
    }
    
    /// Tears down the audio engine and prepares AVAudioSession for speaker playback off the main thread.
    /// Runs exclusively on audioQueue.
    private func performStop() {
        guard isEngineActive || audioEngine != nil else { return }
        
        if let engine = audioEngine {
            if hasInstalledTap {
                engine.inputNode.removeTap(onBus: 0)
                hasInstalledTap = false
            }
            if engine.isRunning {
                engine.stop()
            }
            engine.reset()
            self.audioEngine = nil
        }
        
        #if os(iOS) || os(visionOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
            )
        } catch {
            print("[AudioRecorder DEBUG] AVAudioSession transition after stop failed: \(error)")
        }
        #endif
        
        self.isEngineActive = false
    }
    
    /// Stops recording and returns accumulated mono 16 kHz Float32 samples.
    /// If VAD had not already auto-stopped this session, logs `[VAD] ... trigger=manual`.
    /// Engine teardown and AVAudioSession deactivation execute asynchronously on audioQueue off the main thread.
    @discardableResult
    public func stop() -> [Float] {
        let nowInstant = ContinuousClock.now
        lock.lock()
        let samples = recordedSamples
        recordedSamples.removeAll()
        smoothedLevel = 0.0
        bufferCount = 0
        minDB = .greatestFiniteMagnitude
        maxDB = -.greatestFiniteMagnitude

        let alreadyLoggedVAD = didEmitVADStop
        if !alreadyLoggedVAD {
            didEmitVADStop = true
            let elapsedDouble = Self.milliseconds(from: recordingStartInstant, to: nowInstant)
            let elapsedMs = Int(elapsedDouble.rounded())
            let silenceSinceLastVoice = speechDetected
                ? max(0, Int((elapsedDouble - (lastSpeechActivityMs - Self.vadHangoverMs)).rounded()))
                : elapsedMs
            let event = VADStopEvent(
                trigger: .manual,
                speechDetected: speechDetected,
                speechStartMs: speechStartMs,
                endOfSpeechMs: elapsedMs,
                silenceMs: silenceSinceLastVoice,
                endOfSpeechInstant: nowInstant
            )
            lastVADStopEvent = event
            print("[VAD] speechStart=\(event.speechStartMs) endOfSpeech=\(event.endOfSpeechMs) silence_ms=\(event.silenceMs) trigger=\(event.trigger.rawValue)")
        }
        lock.unlock()
        
        audioQueue.async { [weak self] in
            self?.performStop()
        }
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            self.isRecording = false
            self.audioLevel = 0.0
            self.onLevelChange?(0.0)
        }
        
        return samples
    }

    private nonisolated static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let elapsed = end - start
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) * 1000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
    }
}
