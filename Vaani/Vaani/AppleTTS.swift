import Foundation
import AVFoundation

// MARK: - Hinglish TTS Strategy

/// Runtime-selectable strategies for synthesizing Hinglish speech on-device.
nonisolated public enum TTSStrategy: String, CaseIterable, Identifiable, Sendable {
    /// A) Roman Hinglish text spoken with the en-IN voice.
    case romanizedEnIN = "romanizedEnIN"
    /// B) Roman Hinglish text spoken with the hi-IN voice.
    case romanizedHiIN = "romanizedHiIN"
    /// C) Hindi words transliterated to Devanagari while English words stay in Latin, spoken with the hi-IN voice.
    case devanagariHiIN = "devanagariHiIN"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .romanizedEnIN:
            return "Romanized + en-IN"
        case .romanizedHiIN:
            return "Romanized + hi-IN"
        case .devanagariHiIN:
            return "Devanagari Mix + hi-IN"
        }
    }

    public var subtitle: String {
        switch self {
        case .romanizedEnIN:
            return "Roman Hinglish text with en-IN voice"
        case .romanizedHiIN:
            return "Roman Hinglish text with hi-IN voice"
        case .devanagariHiIN:
            return "Hindi in Devanagari + English in Latin with hi-IN voice"
        }
    }

    /// Primary and fallback BCP-47 language tags for this strategy.
    public var languagePreference: (primary: String, fallback: String) {
        switch self {
        case .romanizedEnIN:
            return ("en-IN", "en-US")
        case .romanizedHiIN, .devanagariHiIN:
            return ("hi-IN", "en-IN")
        }
    }
}

// MARK: - Voice & Synthesis Metrics Models

/// Sendable metadata representation of an installed `AVSpeechSynthesisVoice`.
nonisolated public struct TTSVoiceInfo: Identifiable, Equatable, Hashable, Sendable {
    public enum QualityTier: Int, Comparable, Sendable {
        case `default` = 1
        case enhanced = 2
        case premium = 3

        public var label: String {
            switch self {
            case .default: return "Default"
            case .enhanced: return "Enhanced"
            case .premium: return "Premium"
            }
        }

        public static func < (lhs: QualityTier, rhs: QualityTier) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public init(avQuality: AVSpeechSynthesisVoiceQuality) {
            switch avQuality {
            case .premium:
                self = .premium
            case .enhanced:
                self = .enhanced
            case .default:
                self = .default
            @unknown default:
                self = .default
            }
        }
    }

    public let id: String
    public let name: String
    public let language: String
    public let quality: QualityTier

    public init(id: String, name: String, language: String, quality: QualityTier) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }

    public init(voice: AVSpeechSynthesisVoice) {
        self.id = voice.identifier
        self.name = voice.name
        self.language = voice.language
        self.quality = QualityTier(avQuality: voice.quality)
    }

    public var displayLabel: String {
        "\(name) (\(language)) • \(quality.label)"
    }
}

/// Timing and diagnostic metrics for an on-device TTS utterance.
nonisolated public struct TTSSynthesisMetrics: Equatable, Sendable {
    /// Time in milliseconds from `speak` invocation until `speechSynthesizer(_:didStart:)` fires.
    public let firstAudioMs: Double
    /// Total duration in milliseconds from `speak` invocation until speech finishes or is cancelled.
    public let totalDurationMs: Double
    /// Chosen voice identifier.
    public let voiceIdentifier: String
    /// Chosen voice display name.
    public let voiceName: String
    /// Chosen voice language code.
    public let voiceLanguage: String
    /// Chosen voice quality label (`Premium`, `Enhanced`, `Default`).
    public let voiceQuality: String
    /// Strategy identifier used (`englishDefault`, `romanizedEnIN`, `romanizedHiIN`, `devanagariHiIN`).
    public let strategy: String
    /// Exact text spoken by the synthesizer (after any strategy transformation).
    public let spokenText: String

    public init(
        firstAudioMs: Double,
        totalDurationMs: Double,
        voiceIdentifier: String,
        voiceName: String,
        voiceLanguage: String,
        voiceQuality: String,
        strategy: String,
        spokenText: String
    ) {
        self.firstAudioMs = firstAudioMs
        self.totalDurationMs = totalDurationMs
        self.voiceIdentifier = voiceIdentifier
        self.voiceName = voiceName
        self.voiceLanguage = voiceLanguage
        self.voiceQuality = voiceQuality
        self.strategy = strategy
        self.spokenText = spokenText
    }
}

// MARK: - Heuristic Roman-to-Devanagari Transliterator (Strategy C)

/// HEURISTIC: Simple local dictionary-based Roman-to-Devanagari transliterator for common Hindi words.
/// Used exclusively for `TTSStrategy.devanagariHiIN` (Strategy C) so common Hindi words are rendered
/// in Devanagari while English words (e.g., "weather", "alarm", "schedule", "meeting", "degrees")
/// remain in Latin script.
nonisolated public enum HinglishTransliterator {
    /// HEURISTIC: Dictionary of ~130 common Romanized Hindi words mapped to Devanagari.
    /// English loanwords commonly used in Hinglish (alarm, weather, meeting, schedule, etc.) are
    /// intentionally excluded so they stay in Latin script.
    public static let commonHindiWords: [String: String] = [
        // Time & days
        "aaj": "आज",
        "kal": "कल",
        "parso": "परसों",
        "subah": "सुबह",
        "dopahar": "दोपहर",
        "shaam": "शाम",
        "raat": "रात",
        "abhi": "अभी",
        "ab": "अब",
        "tab": "तब",
        "kab": "कब",
        "baje": "बजे",
        "ghanta": "घंटा",
        "ghante": "घंटे",
        "din": "दिन",
        "hafta": "हफ्ता",
        "hafte": "हफ्ते",
        "mahina": "महीना",
        "saal": "साल",
        "samay": "समय",
        "waqt": "वक़्त",
        "jaldi": "जल्दी",
        "der": "देर",
        "roz": "रोज़",
        "hamesha": "हमेशा",

        // Pronouns & possessives
        "main": "मैं",
        "mai": "मैं",
        "mujhe": "मुझे",
        "mujhko": "मुझको",
        "mera": "मेरा",
        "meri": "मेरी",
        "mere": "मेरे",
        "hum": "हम",
        "humein": "हमें",
        "hume": "हमें",
        "hamara": "हमारा",
        "hamari": "हमारी",
        "hamare": "हमारे",
        "tum": "तुम",
        "tumhe": "तुम्हें",
        "tumhara": "तुम्हारा",
        "tumhari": "तुम्हारी",
        "aap": "आप",
        "aapka": "आपका",
        "aapki": "आपकी",
        "aapke": "आपके",
        "aapko": "आपको",
        "yeh": "यह",
        "ye": "ये",
        "woh": "वह",
        "wo": "वो",
        "inka": "इनका",
        "unka": "उनका",
        "apna": "अपना",
        "apni": "अपनी",
        "apne": "अपने",

        // Postpositions & connectors
        "ka": "का",
        "ki": "की",
        "ke": "के",
        "ko": "को",
        "mein": "में",
        "me": "में",
        "se": "से",
        "par": "पर",
        "pe": "पे",
        "तक": "तक",
        "tak": "तक",
        "liye": "लिए",
        "saath": "साथ",
        "sath": "साथ",
        "baad": "बाद",
        "pehle": "पहले",
        "andar": "अंदर",
        "bahar": "बाहर",
        "upar": "ऊपर",
        "neeche": "नीचे",
        "paas": "पास",
        "door": "दूर",
        "aur": "और",
        "ya": "या",
        "lekin": "लेकिन",
        "magar": "मगर",
        "toh": "तो",
        "bhi": "भी",
        "hi": "ही",
        "wala": "वाला",
        "wali": "वाली",
        "wale": "वाले",

        // Interrogatives
        "kya": "क्या",
        "kyun": "क्यों",
        "kyu": "क्यों",
        "kahan": "कहाँ",
        "kaha": "कहाँ",
        "kaisa": "कैसा",
        "kaisi": "कैसी",
        "kaise": "कैसे",
        "kaun": "कौन",
        "kitna": "कितना",
        "kitni": "कितनी",
        "kitne": "कितने",
        "kidhar": "किधर",

        // Auxiliaries & common verbs
        "hai": "है",
        "hain": "हैं",
        "ho": "हो",
        "hoon": "हूँ",
        "hu": "हूँ",
        "tha": "था",
        "thi": "थी",
        "hoga": "होगा",
        "hogi": "होगी",
        "honge": "होंगे",
        "hone": "होने",
        "raha": "रहा",
        "rahi": "रही",
        "rahe": "रहे",
        "rahega": "रहेगा",
        "rahegi": "रहेगी",
        "gaya": "गया",
        "gayi": "गई",
        "gaye": "गए",
        "kar": "कर",
        "karo": "करो",
        "karna": "करना",
        "karni": "करनी",
        "karne": "करने",
        "kiya": "किया",
        "kiye": "किए",
        "diya": "दिया",
        "liya": "लिया",
        "dena": "देना",
        "lena": "लेना",
        "batao": "बताओ",
        "bataiye": "बताइए",
        "batana": "बताना",
        "chahiye": "चाहिए",
        "sakta": "सकता",
        "sakti": "सकती",
        "sakte": "सकते",
        "jaana": "जाना",
        "aana": "आना",
        "dekho": "देखो",
        "bolo": "बोलो",
        "lagao": "लगाओ",
        "roko": "रोको",
        "rakho": "रखो",
        "rakhna": "रखना",
        "milega": "मिलेगा",

        // Weather, adjectives & everyday nouns
        "mausam": "मौसम",
        "dhoop": "धूप",
        "baarish": "बारिश",
        "barish": "बारिश",
        "hawa": "हवा",
        "thand": "ठंड",
        "thanda": "ठंडा",
        "thandi": "ठंडी",
        "garmi": "गर्मी",
        "garam": "गरम",
        "suhana": "सुहाना",
        "badal": "बादल",
        "halka": "हल्का",
        "halki": "हल्की",
        "tez": "तेज़",
        "zyada": "ज़्यादा",
        "kam": "कम",
        "nahi": "नहीं",
        "nahin": "नहीं",
        "mat": "मत",
        "haan": "हाँ",
        "ji": "जी",
        "bilkul": "बिल्कुल",
        "bahut": "बहुत",
        "bohot": "बहुत",
        "thoda": "थोड़ा",
        "thodi": "थोड़ी",
        "kuch": "कुछ",
        "sab": "सब",
        "sabhi": "सभी",
        "koi": "कोई",
        "har": "हर",
        "lagbhag": "लगभग",
        "kareeb": "क़रीब",
        "achha": "अच्छा",
        "accha": "अच्छा",
        "acchi": "अच्छी",
        "badiya": "बढ़िया",
        "theek": "ठीक",
        "sahi": "सही",
        "galat": "ग़लत",
        "naya": "नया",
        "nayi": "नई",
        "purana": "पुराना",
        "agla": "अगला",
        "agli": "अगली",
        "pichla": "पिछला",
        "kaam": "काम",
        "ghar": "घर",
        "raasta": "रास्ता",
        "jagah": "जगह",
        "khabar": "ख़बर",
        "paani": "पानी",
        "khana": "खाना",
        "chai": "चाय",
        "namaste": "नमस्ते",
        "dhanyavaad": "धन्यवाद",
        "shukriya": "शुक्रिया",
        "kripya": "कृपया"
    ]

    /// HEURISTIC: Transliterates known Romanized Hindi words into Devanagari while keeping
    /// English words, numbers, and punctuation intact.
    public static func transliterate(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        return lines.map { line in
            let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
            return tokens.map { tokenSubstring in
                let token = String(tokenSubstring)
                guard !token.isEmpty else { return token }

                // Separate leading and trailing punctuation
                var startIndex = token.startIndex
                var endIndex = token.endIndex

                while startIndex < endIndex, token[startIndex].isPunctuation || token[startIndex].isSymbol {
                    startIndex = token.index(after: startIndex)
                }
                while endIndex > startIndex {
                    let prevIndex = token.index(before: endIndex)
                    if token[prevIndex].isPunctuation || token[prevIndex].isSymbol {
                        endIndex = prevIndex
                    } else {
                        break
                    }
                }

                guard startIndex < endIndex else { return token }

                let leadingPunct = String(token[..<startIndex])
                let coreWord = String(token[startIndex..<endIndex])
                let trailingPunct = String(token[endIndex...])

                let lookupKey = coreWord.lowercased()
                if let devanagariWord = commonHindiWords[lookupKey] {
                    return leadingPunct + devanagariWord + trailingPunct
                }
                return token
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }
}

// MARK: - On-Device Apple TTS Service

/// On-device Text-To-Speech engine backed by `AVSpeechSynthesizer`.
/// Conforms to `TextToSpeech` with a `Sendable` facade wrapping `@MainActor`-confined synthesizer internals.
nonisolated public final class AppleTTS: TextToSpeech, @unchecked Sendable {
    private let lock = NSLock()
    private var _hinglishStrategy: TTSStrategy
    private var _voiceIdentifierOverride: String?
    private var _lastMetrics: TTSSynthesisMetrics?
    private var _onFirstAudio: (@MainActor @Sendable (Double) -> Void)?
    private var _onMetrics: (@MainActor @Sendable (TTSSynthesisMetrics) -> Void)?

    /// Dedicated serial queue for off-main-thread `AVAudioSession` configuration.
    private let sessionQueue: DispatchQueue

    /// Main-actor coordinator managing `AVSpeechSynthesizer` and its delegate lifecycle.
    private let coordinator = AppleTTSCoordinator()

    /// Selected strategy when speaking in Hinglish mode (defaults to `.romanizedHiIN`).
    public var hinglishStrategy: TTSStrategy {
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

    /// Optional explicit voice identifier override (used by TTS Lab; `nil` selects best voice automatically).
    public var voiceIdentifierOverride: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _voiceIdentifierOverride
        }
        set {
            lock.lock()
            _voiceIdentifierOverride = newValue
            lock.unlock()
        }
    }

    /// Metrics from the most recent utterance.
    public var lastMetrics: TTSSynthesisMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return _lastMetrics
    }

    /// Callback invoked on `MainActor` as soon as `didStart` fires with time-to-first-audio in ms.
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

    /// Callback invoked on `MainActor` when an utterance finishes with both `firstAudioMs` and `totalDurationMs`.
    public var onMetrics: (@MainActor @Sendable (TTSSynthesisMetrics) -> Void)? {
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
        hinglishStrategy: TTSStrategy = .romanizedHiIN,
        voiceIdentifierOverride: String? = nil,
        sessionQueue: DispatchQueue = AudioRecorder.sharedAudioSessionQueue
    ) {
        self._hinglishStrategy = hinglishStrategy
        self._voiceIdentifierOverride = voiceIdentifierOverride
        self.sessionQueue = sessionQueue
    }

    // MARK: - TextToSpeech Protocol

    public nonisolated func speak(text: String, language: VoiceAgentViewModel.Language) async throws {
        _ = try await speakWithMetrics(text: text, language: language)
    }

    public nonisolated func stop() {
        Task { @MainActor [coordinator] in
            coordinator.stopSpeaking()
        }
    }

    // MARK: - Extended Synthesis API

    /// Speaks the provided text and returns both time-to-first-audio (`firstAudioMs`) and total duration (`totalDurationMs`).
    @discardableResult
    public nonisolated func speakWithMetrics(
        text: String,
        language: VoiceAgentViewModel.Language,
        strategyOverride: TTSStrategy? = nil,
        voiceIdentifierOverride: String? = nil
    ) async throws -> TTSSynthesisMetrics {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let emptyMetrics = TTSSynthesisMetrics(
                firstAudioMs: 0,
                totalDurationMs: 0,
                voiceIdentifier: "none",
                voiceName: "None",
                voiceLanguage: "",
                voiceQuality: "Default",
                strategy: "empty",
                spokenText: ""
            )
            return emptyMetrics
        }

        try Task.checkCancellation()

        // 1. Configure AVAudioSession off the main thread for loud speaker output compatible with recording.
        try await configurePlaybackAudioSession()

        try Task.checkCancellation()

        let effectiveStrategy = strategyOverride ?? self.hinglishStrategy
        let effectiveVoiceOverride = voiceIdentifierOverride ?? self.voiceIdentifierOverride
        let firstAudioCallback = self.onFirstAudio
        let metricsCallback = self.onMetrics

        let spokenText: String
        let strategyLabel: String
        let languagePair: (primary: String, fallback: String)

        switch language {
        case .english:
            if let strategyOverride {
                // In TTS Lab, allow testing any strategy explicitly.
                strategyLabel = strategyOverride.rawValue
                languagePair = strategyOverride.languagePreference
                spokenText = (strategyOverride == .devanagariHiIN)
                    ? HinglishTransliterator.transliterate(trimmed)
                    : trimmed
            } else {
                strategyLabel = "englishDefault"
                languagePair = ("en-IN", "en-US")
                spokenText = trimmed
            }
        case .hinglish:
            strategyLabel = effectiveStrategy.rawValue
            languagePair = effectiveStrategy.languagePreference
            spokenText = (effectiveStrategy == .devanagariHiIN)
                ? HinglishTransliterator.transliterate(trimmed)
                : trimmed
        }

        let metrics = try await withTaskCancellationHandler {
            try await coordinator.speak(
                spokenText: spokenText,
                strategyLabel: strategyLabel,
                primaryLanguage: languagePair.primary,
                fallbackLanguage: languagePair.fallback,
                voiceIdentifierOverride: effectiveVoiceOverride,
                onFirstAudio: firstAudioCallback
            )
        } onCancel: { [coordinator] in
            Task { @MainActor in
                coordinator.stopSpeaking()
            }
        }

        storeLastMetrics(metrics)

        if let metricsCallback {
            await metricsCallback(metrics)
        }

        return metrics
    }

    private nonisolated func storeLastMetrics(_ metrics: TTSSynthesisMetrics) {
        lock.lock()
        _lastMetrics = metrics
        lock.unlock()
    }

    // MARK: - Voice Discovery Helpers

    /// Returns installed English (`en-IN` first, then `en-US`/`en-GB`) and Hindi (`hi-IN`) voices,
    /// hiding all other languages and sorting by quality (`Premium` > `Enhanced` > `Default`).
    public nonisolated static func availableVoices() -> [TTSVoiceInfo] {
        let filteredVoices = AVSpeechSynthesisVoice.speechVoices().compactMap { voice -> (TTSVoiceInfo, Int, Bool)? in
            guard let priority = languagePriority(voice.language) else { return nil }
            let isNovelty = voice.voiceTraits.contains(.isNoveltyVoice)
            return (TTSVoiceInfo(voice: voice), priority, isNovelty)
        }

        return filteredVoices.sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 < rhs.1
            }
            if lhs.0.quality != rhs.0.quality {
                return lhs.0.quality > rhs.0.quality
            }
            if lhs.2 != rhs.2 {
                return !lhs.2
            }
            if lhs.0.language != rhs.0.language {
                return lhs.0.language < rhs.0.language
            }
            return lhs.0.name < rhs.0.name
        }.map(\.0)
    }

    /// Selects the best installed voice for the given primary and fallback language codes,
    /// preferring `.premium` > `.enhanced` > `.default`.
    public nonisolated static func bestVoiceInfo(
        primaryLanguage: String,
        fallbackLanguage: String
    ) -> TTSVoiceInfo? {
        if let voice = selectBestAVVoice(primaryLanguage: primaryLanguage, fallbackLanguage: fallbackLanguage) {
            return TTSVoiceInfo(voice: voice)
        }
        return nil
    }

    fileprivate nonisolated static func selectBestAVVoice(
        primaryLanguage: String,
        fallbackLanguage: String,
        identifierOverride: String? = nil
    ) -> AVSpeechSynthesisVoice? {
        if let identifierOverride,
           !identifierOverride.isEmpty,
           let explicitVoice = AVSpeechSynthesisVoice(identifier: identifierOverride) {
            return explicitVoice
        }

        let installed = AVSpeechSynthesisVoice.speechVoices()

        if let bestPrimary = bestMatchingVoice(in: installed, forLanguage: primaryLanguage) {
            return bestPrimary
        }

        if let bestFallback = bestMatchingVoice(in: installed, forLanguage: fallbackLanguage) {
            return bestFallback
        }

        return AVSpeechSynthesisVoice(language: primaryLanguage)
            ?? AVSpeechSynthesisVoice(language: fallbackLanguage)
    }

    private nonisolated static func bestMatchingVoice(
        in voices: [AVSpeechSynthesisVoice],
        forLanguage languageCode: String
    ) -> AVSpeechSynthesisVoice? {
        let target = languageCode.lowercased()
        let matches = voices.filter { $0.language.lowercased() == target }
        guard !matches.isEmpty else { return nil }

        return matches.sorted { lhs, rhs in
            let lhsRank = TTSVoiceInfo.QualityTier(avQuality: lhs.quality)
            let rhsRank = TTSVoiceInfo.QualityTier(avQuality: rhs.quality)
            if lhsRank != rhsRank {
                return lhsRank > rhsRank
            }
            let lhsNovelty = lhs.voiceTraits.contains(.isNoveltyVoice)
            let rhsNovelty = rhs.voiceTraits.contains(.isNoveltyVoice)
            if lhsNovelty != rhsNovelty {
                return !lhsNovelty
            }
            return lhs.name < rhs.name
        }.first
    }

    /// Returns the sort priority for allowed languages (`en-IN` first, `hi-IN`, then `en-US`/`en-GB`/other `en-*`),
    /// or `nil` for all other languages so they are hidden.
    private nonisolated static func languagePriority(_ language: String) -> Int? {
        let normalized = language.lowercased().replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "en-in": return 0
        case "hi-in": return 1
        case "en-us": return 2
        case "en-gb": return 3
        default:
            if normalized.hasPrefix("hi") { return 1 }
            if normalized.hasPrefix("en") { return 4 }
            return nil
        }
    }

    // MARK: - Off-Main-Thread Audio Session Configuration

    private nonisolated func configurePlaybackAudioSession() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                #if os(iOS) || os(visionOS)
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    // Use .playAndRecord with .defaultToSpeaker and allowBluetooth variants so
                    // output plays loudly through the speaker and remains compatible with mic capture.
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

// MARK: - Main-Actor Synthesizer Coordinator

@MainActor
private final class AppleTTSCoordinator: NSObject, AVSpeechSynthesizerDelegate {
    private var synthesizerInstance: AVSpeechSynthesizer?

    private struct ActiveUtteranceContext {
        let utteranceID: ObjectIdentifier
        let startTime: ContinuousClock.Instant
        let voiceIdentifier: String
        let voiceName: String
        let voiceLanguage: String
        let voiceQuality: String
        let strategyLabel: String
        let spokenText: String
        let onFirstAudio: (@MainActor @Sendable (Double) -> Void)?
        var firstAudioMs: Double?
        let continuation: CheckedContinuation<TTSSynthesisMetrics, Error>
    }

    private var activeContext: ActiveUtteranceContext?

    override nonisolated init() {
        super.init()
    }

    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let existing = synthesizerInstance {
            return existing
        }
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        #if os(iOS) || os(visionOS)
        synth.usesApplicationAudioSession = true
        #endif
        synthesizerInstance = synth
        return synth
    }

    func speak(
        spokenText: String,
        strategyLabel: String,
        primaryLanguage: String,
        fallbackLanguage: String,
        voiceIdentifierOverride: String?,
        onFirstAudio: (@MainActor @Sendable (Double) -> Void)?
    ) async throws -> TTSSynthesisMetrics {
        let synthesizer = ensureSynthesizer()

        // Stop any existing speech before starting a new utterance
        if activeContext != nil || synthesizer.isSpeaking {
            stopSpeaking()
        }

        let chosenVoice = AppleTTS.selectBestAVVoice(
            primaryLanguage: primaryLanguage,
            fallbackLanguage: fallbackLanguage,
            identifierOverride: voiceIdentifierOverride
        )

        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = chosenVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        let voiceId = chosenVoice?.identifier ?? "system-default"
        let voiceName = chosenVoice?.name ?? "System Default"
        let voiceLang = chosenVoice?.language ?? primaryLanguage
        let qualityLabel = chosenVoice.map { TTSVoiceInfo.QualityTier(avQuality: $0.quality).label } ?? "Default"
        let utteranceID = ObjectIdentifier(utterance)

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TTSSynthesisMetrics, Error>) in
            let start = ContinuousClock.now
            self.activeContext = ActiveUtteranceContext(
                utteranceID: utteranceID,
                startTime: start,
                voiceIdentifier: voiceId,
                voiceName: voiceName,
                voiceLanguage: voiceLang,
                voiceQuality: qualityLabel,
                strategyLabel: strategyLabel,
                spokenText: spokenText,
                onFirstAudio: onFirstAudio,
                firstAudioMs: nil,
                continuation: continuation
            )

            synthesizer.speak(utterance)
        }
    }

    func stopSpeaking() {
        if let synthesizer = synthesizerInstance, (synthesizer.isSpeaking || synthesizer.isPaused) {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if let context = activeContext {
            activeContext = nil
            let elapsedMs = (ContinuousClock.now - context.startTime).milliseconds
            let firstAudio = context.firstAudioMs ?? elapsedMs
            let metrics = TTSSynthesisMetrics(
                firstAudioMs: firstAudio,
                totalDurationMs: elapsedMs,
                voiceIdentifier: context.voiceIdentifier,
                voiceName: context.voiceName,
                voiceLanguage: context.voiceLanguage,
                voiceQuality: context.voiceQuality,
                strategy: context.strategyLabel,
                spokenText: context.spokenText
            )
            context.continuation.resume(returning: metrics)
        }
    }

    private func handleDidStart(utteranceID: ObjectIdentifier) {
        guard var context = activeContext, context.utteranceID == utteranceID else { return }
        guard context.firstAudioMs == nil else { return }

        let firstAudioMs = (ContinuousClock.now - context.startTime).milliseconds
        context.firstAudioMs = firstAudioMs
        activeContext = context

        // DEBUG: Log chosen voice identifier and quality, strategy, text actually spoken, and time-to-first-audio.
        print(String(
            format: "[AppleTTS DEBUG] voice=%@ (%@, %@) quality=%@ strategy=%@ firstAudioMs=%.0f text=%@",
            context.voiceIdentifier,
            context.voiceName,
            context.voiceLanguage,
            context.voiceQuality,
            context.strategyLabel,
            firstAudioMs,
            context.spokenText.debugDescription
        ))

        context.onFirstAudio?(firstAudioMs)
    }

    private func handleDidFinishOrCancel(utteranceID: ObjectIdentifier) {
        guard let context = activeContext, context.utteranceID == utteranceID else { return }
        activeContext = nil

        let totalMs = (ContinuousClock.now - context.startTime).milliseconds
        let firstAudioMs = context.firstAudioMs ?? totalMs

        if context.firstAudioMs == nil {
            // DEBUG: Fallback log if completion occurred before a separate didStart event.
            print(String(
                format: "[AppleTTS DEBUG] voice=%@ (%@, %@) quality=%@ strategy=%@ firstAudioMs=%.0f text=%@",
                context.voiceIdentifier,
                context.voiceName,
                context.voiceLanguage,
                context.voiceQuality,
                context.strategyLabel,
                firstAudioMs,
                context.spokenText.debugDescription
            ))
            context.onFirstAudio?(firstAudioMs)
        }

        let metrics = TTSSynthesisMetrics(
            firstAudioMs: firstAudioMs,
            totalDurationMs: totalMs,
            voiceIdentifier: context.voiceIdentifier,
            voiceName: context.voiceName,
            voiceLanguage: context.voiceLanguage,
            voiceQuality: context.voiceQuality,
            strategy: context.strategyLabel,
            spokenText: context.spokenText
        )
        context.continuation.resume(returning: metrics)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleDidStart(utteranceID: utteranceID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleDidFinishOrCancel(utteranceID: utteranceID)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            self?.handleDidFinishOrCancel(utteranceID: utteranceID)
        }
    }
}

private extension Duration {
    nonisolated var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
    }
}
