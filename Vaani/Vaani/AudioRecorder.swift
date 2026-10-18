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

/// AVAudioEngine-based microphone capture service.
/// Records mono 16 kHz Float32 PCM samples and exposes real-time audio levels.
@Observable
nonisolated public final class AudioRecorder: @unchecked Sendable {
    // MARK: - Properties
    
    /// Live audio input level for metering, normalized between 0.0 and 1.0.
    public var audioLevel: Float = 0.0
    
    /// True while recording is active.
    public private(set) var isRecording: Bool = false
    
    /// Optional callback invoked on MainActor when the live audio level changes.
    @ObservationIgnored
    public var onLevelChange: (@MainActor @Sendable (Float) -> Void)?
    
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
        
        lock.lock()
        recordedSamples.removeAll()
        smoothedLevel = 0.0
        bufferCount = 0
        minDB = .greatestFiniteMagnitude
        maxDB = -.greatestFiniteMagnitude
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
            
            // Smoothing: fast attack (0.7 new + 0.3 old), slower release (0.2 new + 0.8 old)
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
            self.lock.unlock()
            
            // DEBUG: Print RMS, dB, min/max dB, and level every ~10 buffers for calibration
            if count % 10 == 0 {
                print(String(format: "[AudioRecorder DEBUG] buffer #%d | RMS: %.5f | dB: %.2f (min: %.2f, max: %.2f) | Level: %.3f", count, rms, dB, currentMinDB, currentMaxDB, currentLevel))
            }
            
            // Dispatch level update to MainActor so @Observable view model refreshes UI
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.audioLevel = currentLevel
                self.onLevelChange?(currentLevel)
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
    /// Engine teardown and AVAudioSession deactivation execute asynchronously on audioQueue off the main thread.
    @discardableResult
    public func stop() -> [Float] {
        lock.lock()
        let samples = recordedSamples
        recordedSamples.removeAll()
        smoothedLevel = 0.0
        bufferCount = 0
        minDB = .greatestFiniteMagnitude
        maxDB = -.greatestFiniteMagnitude
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
}
