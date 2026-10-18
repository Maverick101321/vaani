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

/// HEURISTIC: Local dictionary-based Roman-to-Devanagari transliterator and number/time normalizer for K2 / Strategy C.
/// Converts common Romanized Hindi words, Indian city/place names, common English assistant loanwords,
/// and time/number expressions (e.g., "5 PM" -> "शाम 5 बजे", "24 degrees" -> "24 डिग्री") into Devanagari.
nonisolated public enum HinglishTransliterator {
    /// HEURISTIC: Dictionary of common Romanized Hindi words, Indian cities/places, and English loanwords mapped to Devanagari.
    public static let commonHindiWords: [String: String] = [
        // Time, clock & calendar words
        "aaj": "आज",
        "kal": "कल",
        "parso": "परसों",
        "parson": "परसों",
        "narso": "नरसों",
        "subah": "सुबह",
        "savere": "सवेरे",
        "dopahar": "दोपहर",
        "shaam": "शाम",
        "raat": "रात",
        "aadhi": "आधी",
        "abhi": "अभी",
        "ab": "अब",
        "tab": "तब",
        "jab": "जब",
        "kab": "कब",
        "kabhi": "कभी",
        "baje": "बजे",
        "baja": "बजा",
        "baj": "बज",
        "ghanta": "घंटा",
        "ghante": "घंटे",
        "minat": "मिनट",
        "pal": "पल",
        "din": "दिन",
        "dino": "दिनों",
        "hafta": "हफ्ता",
        "hafte": "हफ्ते",
        "mahina": "महीना",
        "mahine": "महीने",
        "saal": "साल",
        "varsh": "वर्ष",
        "taareekh": "तारीख़",
        "tareekh": "तारीख़",
        "samay": "समय",
        "waqt": "वक़्त",
        "jaldi": "जल्दी",
        "der": "देर",
        "deeri": "देरी",
        "roz": "रोज़",
        "pratidin": "प्रतिदिन",
        "hamesha": "हमेशा",
        "turant": "तुरंत",
        "fauran": "फ़ौरन",

        // Days of the week
        "somwar": "सोमवार",
        "mangalwar": "मंगलवार",
        "budhwar": "बुधवार",
        "guruwar": "गुरुवार",
        "brihaspatiwar": "बृहस्पतिवार",
        "shukrawar": "शुक्रवार",
        "shaniwar": "शनिवार",
        "raviwar": "रविवार",
        "itwar": "इतवार",

        // Numbers 1-12 & fractional time qualifiers
        "ek": "एक",
        "do": "दो",
        "teen": "तीन",
        "chaar": "चार",
        "char": "चार",
        "paanch": "पाँच",
        "panch": "पाँच",
        "chhah": "छह",
        "cheh": "छह",
        "che": "छह",
        "saat": "सात",
        "aath": "आठ",
        "nau": "नौ",
        "das": "दस",
        "gyarah": "ग्यारह",
        "barah": "बारह",
        "sawa": "सवा",
        "sadhe": "साढ़े",
        "saadhe": "साढ़े",
        "paune": "पौने",
        "dedh": "डेढ़",
        "dhai": "ढाई",
        "aadha": "आधा",
        "pehla": "पहला",
        "pehli": "पहली",
        "doosra": "दूसरा",
        "doosri": "दूसरी",
        "teesra": "तीसरा",
        "aakhri": "आख़िरी",

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
        "is": "इस",
        "us": "उस",
        "in": "इन",
        "un": "उन",
        "iska": "इसका",
        "uska": "उसका",
        "inka": "इनका",
        "unka": "उनका",
        "apna": "अपना",
        "apni": "अपनी",
        "apne": "अपने",
        "khud": "ख़ुद",

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
        "aage": "आगे",
        "peeche": "पीछे",
        "paas": "पास",
        "door": "दूर",
        "aur": "और",
        "ya": "या",
        "lekin": "लेकिन",
        "magar": "मगर",
        "parantu": "परंतु",
        "kyunki": "क्योंकि",
        "isliye": "इसलिए",
        "toh": "तो",
        "phir": "फिर",
        "fir": "फिर",
        "bhi": "भी",
        "hi": "ही",
        "sirf": "सिर्फ़",
        "bas": "बस",
        "wala": "वाला",
        "wali": "वाली",
        "wale": "वाले",
        "bina": "बिना",
        "baare": "बारे",

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
        "kaunsa": "कौनसा",
        "kaunsi": "कौनसी",
        "kis": "किस",
        "kisi": "किसी",
        "kitna": "कितना",
        "kitni": "कितनी",
        "kitne": "कितने",
        "kidhar": "किधर",

        // Auxiliaries & common assistant verbs (reminder, alarm, schedule, search)
        "hai": "है",
        "hain": "हैं",
        "ho": "हो",
        "hoon": "हूँ",
        "hu": "हूँ",
        "tha": "था",
        "thi": "थी",
        "the": "थे",
        "hua": "हुआ",
        "hui": "हुई",
        "hoga": "होगा",
        "hogi": "होगी",
        "honge": "होंगे",
        "hone": "होने",
        "raha": "रहा",
        "rahi": "रही",
        "rahe": "रहे",
        "rahega": "रहेगा",
        "rahegi": "रहेगी",
        "rahenge": "रहेंगे",
        "gaya": "गया",
        "gayi": "गई",
        "gaye": "गए",
        "kar": "कर",
        "karo": "करो",
        "kariye": "करिए",
        "kijiye": "कीजिए",
        "karna": "करना",
        "karni": "करनी",
        "karne": "करने",
        "kiya": "किया",
        "kiye": "किए",
        "diya": "दिया",
        "diye": "दिए",
        "liya": "लिया",
        "dena": "देना",
        "dijiye": "दीजिए",
        "lena": "लेना",
        "lo": "लो",
        "batao": "बताओ",
        "bataiye": "बताइए",
        "batana": "बताना",
        "bata": "बता",
        "chahiye": "चाहिए",
        "sakta": "सकता",
        "sakti": "सकती",
        "sakte": "सकते",
        "jaana": "जाना",
        "jao": "जाओ",
        "aana": "आना",
        "aao": "आओ",
        "aaya": "आया",
        "aayi": "आई",
        "dekho": "देखो",
        "dekhna": "देखना",
        "dekhiye": "देखिए",
        "bolo": "बोलो",
        "bolna": "बोलना",
        "suno": "सुनो",
        "sunao": "सुनाओ",
        "padho": "पढ़ो",
        "likho": "लिखो",
        "bhejo": "भेजो",
        "dhundho": "ढूँढो",
        "khojo": "खोजो",
        "lagao": "लगाओ",
        "lagana": "लगाना",
        "laga": "लगा",
        "bajao": "बजाओ",
        "bajana": "बजाना",
        "roko": "रोको",
        "rokna": "रोकना",
        "band": "बंद",
        "shuru": "शुरू",
        "khatam": "ख़त्म",
        "badlo": "बदलो",
        "hatao": "हटाओ",
        "hatana": "हटाना",
        "jodo": "जोड़ो",
        "rakho": "रखो",
        "rakhna": "रखना",
        "milega": "मिलेगा",
        "milegi": "मिलेगी",
        "milna": "मिलना",
        "yaad": "याद",
        "dilana": "दिलाना",
        "dilao": "दिलाओ",
        "bhool": "भूल",
        "pata": "पता",
        "maloom": "मालूम",
        "samajh": "समझ",
        "madad": "मदद",
        "lagta": "लगता",
        "lagti": "लगती",

        // Weather, adjectives & everyday assistant nouns
        "mausam": "मौसम",
        "taapman": "तापमान",
        "dhoop": "धूप",
        "baarish": "बारिश",
        "barish": "बारिश",
        "barsaat": "बरसात",
        "hawa": "हवा",
        "toofan": "तूफ़ान",
        "kohra": "कोहरा",
        "thand": "ठंड",
        "sardi": "सर्दी",
        "thanda": "ठंडा",
        "thandi": "ठंडी",
        "garmi": "गर्मी",
        "garam": "गरम",
        "suhana": "सुहाना",
        "badal": "बादल",
        "badli": "बदली",
        "saaf": "साफ़",
        "halka": "हल्का",
        "halki": "हल्की",
        "tez": "तेज़",
        "dheere": "धीरे",
        "zyada": "ज़्यादा",
        "kam": "कम",
        "kaafi": "काफ़ी",
        "nahi": "नहीं",
        "nahin": "नहीं",
        "na": "ना",
        "mat": "मत",
        "haan": "हाँ",
        "ji": "जी",
        "bilkul": "बिल्कुल",
        "zaroor": "ज़रूर",
        "shayad": "शायद",
        "bahut": "बहुत",
        "bohot": "बहुत",
        "thoda": "थोड़ा",
        "thodi": "थोड़ी",
        "kuch": "कुछ",
        "kuchh": "कुछ",
        "sab": "सब",
        "sabhi": "सभी",
        "saara": "सारा",
        "saari": "सारी",
        "poora": "पूरा",
        "poori": "पूरी",
        "koi": "कोई",
        "har": "हर",
        "lagbhag": "लगभग",
        "kareeb": "क़रीब",
        "achha": "अच्छा",
        "accha": "अच्छा",
        "acchi": "अच्छी",
        "acche": "अच्छे",
        "badiya": "बढ़िया",
        "behtar": "बेहतर",
        "theek": "ठीक",
        "sahi": "सही",
        "galat": "ग़लत",
        "zaroori": "ज़रूरी",
        "khaas": "ख़ास",
        "aasan": "आसान",
        "mushkil": "मुश्किल",
        "taiyar": "तैयार",
        "khali": "ख़ाली",
        "vyast": "व्यस्त",
        "naya": "नया",
        "nayi": "नई",
        "purana": "पुराना",
        "agla": "अगला",
        "agli": "अगली",
        "agle": "अगले",
        "pichla": "पिछला",
        "pichli": "पिछली",
        "pichle": "पिछले",
        "kaam": "काम",
        "baat": "बात",
        "sawal": "सवाल",
        "jawab": "जवाब",
        "sandesh": "संदेश",
        "suchi": "सूची",
        "chhutti": "छुट्टी",
        "ghar": "घर",
        "daftar": "दफ़्तर",
        "raasta": "रास्ता",
        "jagah": "जगह",
        "shahar": "शहर",
        "khabar": "ख़बर",
        "paani": "पानी",
        "khana": "खाना",
        "chai": "चाय",
        "dawai": "दवाई",
        "namaste": "नमस्ते",
        "namaskar": "नमस्कार",
        "dhanyavaad": "धन्यवाद",
        "shukriya": "शुक्रिया",
        "kripya": "कृपया",

        // Indian cities, states & place names
        "bangalore": "बेंगलुरु",
        "bengaluru": "बेंगलुरु",
        "hyderabad": "हैदराबाद",
        "mumbai": "मुंबई",
        "bombay": "मुंबई",
        "delhi": "दिल्ली",
        "dilli": "दिल्ली",
        "chennai": "चेन्नई",
        "madras": "चेन्नई",
        "kolkata": "कोलकाता",
        "calcutta": "कोलकाता",
        "pune": "पुणे",
        "ahmedabad": "अहमदाबाद",
        "jaipur": "जयपुर",
        "kochi": "कोच्चि",
        "cochin": "कोच्चि",
        "goa": "गोवा",
        "lucknow": "लखनऊ",
        "chandigarh": "चंडीगढ़",
        "indore": "इंदौर",
        "bhopal": "भोपाल",
        "surat": "सूरत",
        "nagpur": "नागपुर",
        "patna": "पटना",
        "gurgaon": "गुरुग्राम",
        "gurugram": "गुरुग्राम",
        "noida": "नोएडा",
        "ghaziabad": "ग़ाज़ियाबाद",
        "faridabad": "फ़रीदाबाद",
        "varanasi": "वाराणसी",
        "banaras": "बनारस",
        "agra": "आगरा",
        "amritsar": "अमृतसर",
        "shimla": "शिमला",
        "manali": "मनाली",
        "dehradun": "देहरादून",
        "haridwar": "हरिद्वार",
        "rishikesh": "ऋषिकेश",
        "mysore": "मैसूरु",
        "mysuru": "मैसूरु",
        "mangalore": "मंगलुरु",
        "mangaluru": "मंगलुरु",
        "coimbatore": "कोयंबटूर",
        "madurai": "मदुरै",
        "thiruvananthapuram": "तिरुवनंतपुरम",
        "trivandrum": "तिरुवनंतपुरम",
        "visakhapatnam": "विशाखापत्तनम",
        "vizag": "वाइज़ाग",
        "vijayawada": "विजयवाड़ा",
        "guwahati": "गुवाहाटी",
        "bhubaneswar": "भुवनेश्वर",
        "ranchi": "राँची",
        "raipur": "रायपुर",
        "vadodara": "वडोदरा",
        "baroda": "वडोदरा",
        "rajkot": "राजकोट",
        "udaipur": "उदयपुर",
        "jodhpur": "जोधपुर",
        "kanpur": "कानपुर",
        "prayagraj": "प्रयागराज",
        "allahabad": "इलाहाबाद",
        "srinagar": "श्रीनगर",
        "jammu": "जम्मू",
        "leh": "लेह",
        "ladakh": "लद्दाख",
        "puducherry": "पुदुचेरी",
        "pondicherry": "पांडिचेरी",
        "ooty": "ऊटी",
        "darjeeling": "दार्जिलिंग",
        "gangtok": "गंगटोक",
        "shillong": "शिलांग",
        "india": "भारत",
        "bharat": "भारत",
        "karnataka": "कर्नाटक",
        "maharashtra": "महाराष्ट्र",
        "kerala": "केरल",
        "rajasthan": "राजस्थान",
        "gujarat": "गुजरात",
        "punjab": "पंजाब",

        // Common English loanwords spoken by the assistant
        "meeting": "मीटिंग",
        "meetings": "मीटिंग्स",
        "reminder": "रिमाइंडर",
        "reminders": "रिमाइंडर्स",
        "alarm": "अलार्म",
        "alarms": "अलार्म्स",
        "schedule": "शेड्यूल",
        "schedules": "शेड्यूल्स",
        "scheduled": "शेड्यूल्ड",
        "weather": "वेदर",
        "degree": "डिग्री",
        "degrees": "डिग्री",
        "temperature": "टेम्परेचर",
        "forecast": "फ़ोरकास्ट",
        "today": "आज",
        "tomorrow": "कल",
        "yesterday": "कल",
        "celsius": "सेल्सियस",
        "fahrenheit": "फ़ारेनहाइट",
        "set": "सेट",
        "next": "नेक्स्ट",
        "chance": "चांस",
        "timer": "टाइमर",
        "calendar": "कैलेंडर",
        "event": "इवेंट",
        "events": "इवेंट्स",
        "call": "कॉल",
        "calls": "कॉल्स",
        "message": "मैसेज",
        "messages": "मैसेजेस",
        "notification": "नोटिफिकेशन",
        "notifications": "नोटिफिकेशन्स",
        "update": "अपडेट",
        "cancel": "कैंसिल",
        "traffic": "ट्रैफ़िक",
        "office": "ऑफ़िस",
        "flight": "फ़्लाइट",
        "train": "ट्रेन",
        "hotel": "होटल",
        "time": "टाइम",
        "minute": "मिनट",
        "minutes": "मिनट",
        "second": "सेकंड",
        "seconds": "सेकंड",
        "hour": "घंटा",
        "hours": "घंटे",
        "morning": "सुबह",
        "afternoon": "दोपहर",
        "evening": "शाम",
        "night": "रात",
        "humidity": "ह्यूमिडिटी",
        "percent": "प्रतिशत",
        "percentage": "प्रतिशत",
        "ok": "ओके",
        "okay": "ओके",
        "please": "प्लीज़",
        "sorry": "सॉरी",
        "thank": "थैंक",
        "thanks": "थैंक्स"
    ]

    /// Converts numbers, temperatures, and clock times (e.g., "5 PM" -> "शाम 5 बजे", "24 degrees" -> "24 डिग्री")
    /// into speakable Hindi/Devanagari form before token-level transliteration.
    public static func normalizeSpeakableNumbersAndTimes(_ text: String) -> String {
        var result = text

        // 1. Multi-word place names (e.g., "New Delhi" -> "नई दिल्ली")
        if let regex = try? NSRegularExpression(pattern: "\\bnew\\s+delhi\\b", options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "नई दिल्ली"
            )
        }

        // 2. Clock times with AM / PM (e.g. "5 PM" -> "शाम 5 बजे", "7:30 AM" -> "सुबह 7 बजकर 30 मिनट")
        if let timeRegex = try? NSRegularExpression(
            pattern: "\\b(\\d{1,2})(?::(\\d{2}))?\\s*([AaPp]\\.?[Mm]\\.?)\\b",
            options: []
        ) {
            let matches = timeRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let hourRange = Range(match.range(at: 1), in: result),
                      let ampmRange = Range(match.range(at: 3), in: result),
                      let hour = Int(result[hourRange]) else {
                    continue
                }

                let minute: Int
                if match.range(at: 2).location != NSNotFound,
                   let minRange = Range(match.range(at: 2), in: result),
                   let parsedMin = Int(result[minRange]) {
                    minute = parsedMin
                } else {
                    minute = 0
                }

                let isPM = result[ampmRange].lowercased().hasPrefix("p")
                let periodWord: String
                if isPM {
                    if hour == 12 || (hour >= 1 && hour <= 3) {
                        periodWord = "दोपहर"
                    } else if hour >= 4 && hour <= 7 {
                        periodWord = "शाम"
                    } else {
                        periodWord = "रात"
                    }
                } else {
                    if hour == 12 || (hour >= 1 && hour <= 3) {
                        periodWord = "रात"
                    } else {
                        periodWord = "सुबह"
                    }
                }

                let prefixCheck = result[..<fullRange.lowerBound].trimmingCharacters(in: .whitespaces).lowercased()
                let hasLeadingPeriod = prefixCheck.hasSuffix("subah") || prefixCheck.hasSuffix("सुबह")
                    || prefixCheck.hasSuffix("dopahar") || prefixCheck.hasSuffix("दोपहर")
                    || prefixCheck.hasSuffix("shaam") || prefixCheck.hasSuffix("शाम")
                    || prefixCheck.hasSuffix("raat") || prefixCheck.hasSuffix("रात")

                let suffixCheck = result[fullRange.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
                let hasTrailingBaje = suffixCheck.hasPrefix("baje") || suffixCheck.hasPrefix("बजे")

                let effectivePrefix = hasLeadingPeriod ? "" : "\(periodWord) "
                let spokenTime: String
                if minute > 0 {
                    spokenTime = "\(effectivePrefix)\(hour) बजकर \(minute) मिनट"
                } else {
                    let bajeSuffix = hasTrailingBaje ? "" : " बजे"
                    spokenTime = "\(effectivePrefix)\(hour)\(bajeSuffix)"
                }

                result.replaceSubrange(fullRange, with: spokenTime)
            }
        }

        // 3. Colon clock times without AM/PM (e.g. "7:30" -> "7 बजकर 30 मिनट", "7:00" -> "7 बजे")
        if let colonTimeRegex = try? NSRegularExpression(pattern: "\\b(\\d{1,2}):(\\d{2})\\b", options: []) {
            let matches = colonTimeRegex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let hourRange = Range(match.range(at: 1), in: result),
                      let minRange = Range(match.range(at: 2), in: result),
                      let hour = Int(result[hourRange]),
                      let minute = Int(result[minRange]) else {
                    continue
                }
                let replacement = (minute > 0) ? "\(hour) बजकर \(minute) मिनट" : "\(hour) बजे"
                result.replaceSubrange(fullRange, with: replacement)
            }
        }

        // 4. Temperature and degree patterns (e.g. "24 degrees Celsius" -> "24 डिग्री सेल्सियस", "24 degrees" -> "24 डिग्री", "24°C" -> "24 डिग्री सेल्सियस")
        let unitPatterns: [(String, String)] = [
            ("(\\d+(?:\\.\\d+)?)\\s*°\\s*[Cc]\\b", "$1 डिग्री सेल्सियस"),
            ("(\\d+(?:\\.\\d+)?)\\s*°\\s*[Ff]\\b", "$1 डिग्री फ़ारेनहाइट"),
            ("(\\d+(?:\\.\\d+)?)\\s*degrees?\\s+celsius\\b", "$1 डिग्री सेल्सियस"),
            ("(\\d+(?:\\.\\d+)?)\\s*degrees?\\s+fahrenheit\\b", "$1 डिग्री फ़ारेनहाइट"),
            ("(\\d+(?:\\.\\d+)?)\\s*degrees?\\b", "$1 डिग्री"),
            ("(\\d+(?:\\.\\d+)?)\\s*°", "$1 डिग्री"),
            ("(\\d+(?:\\.\\d+)?)\\s*%", "$1 प्रतिशत")
        ]

        for (pattern, template) in unitPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: template
                )
            }
        }

        return result
    }

    /// HEURISTIC: Normalizes numbers/times and transliterates Romanized Hindi words, Indian cities/places,
    /// and common English assistant loanwords into Devanagari.
    public static func transliterate(_ text: String) -> String {
        let normalized = normalizeSpeakableNumbersAndTimes(text)
        let lines = normalized.components(separatedBy: .newlines)
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

    /// Fixed Apple voice used for comparison: Isha (Premium, en-IN).
    public static let ishaVoiceInfo = TTSVoiceInfo(
        id: "com.apple.voice.premium.en-IN.Isha",
        name: "Isha",
        language: "en-IN",
        quality: .premium
    )

    /// Returns only `Isha (Premium, en-IN)` for comparison.
    public nonisolated static func availableVoices() -> [TTSVoiceInfo] {
        if let installedIsha = findInstalledIshaVoice() {
            return [TTSVoiceInfo(voice: installedIsha)]
        }
        return [ishaVoiceInfo]
    }

    /// Returns `Isha (Premium, en-IN)` metadata.
    public nonisolated static func bestVoiceInfo(
        primaryLanguage: String,
        fallbackLanguage: String
    ) -> TTSVoiceInfo? {
        if let installedIsha = findInstalledIshaVoice() {
            return TTSVoiceInfo(voice: installedIsha)
        }
        return ishaVoiceInfo
    }

    fileprivate nonisolated static func selectBestAVVoice(
        primaryLanguage: String,
        fallbackLanguage: String,
        identifierOverride: String? = nil
    ) -> AVSpeechSynthesisVoice? {
        if let installedIsha = findInstalledIshaVoice() {
            return installedIsha
        }
        if let explicitIsha = AVSpeechSynthesisVoice(identifier: ishaVoiceInfo.id) {
            return explicitIsha
        }
        return AVSpeechSynthesisVoice(language: "en-IN")
            ?? AVSpeechSynthesisVoice(language: primaryLanguage)
            ?? AVSpeechSynthesisVoice(language: fallbackLanguage)
    }

    private nonisolated static func findInstalledIshaVoice() -> AVSpeechSynthesisVoice? {
        let ishaVoices = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            let lang = voice.language.lowercased().replacingOccurrences(of: "_", with: "-")
            return lang == "en-in" && voice.name.lowercased().contains("isha")
        }
        return ishaVoices.sorted { lhs, rhs in
            TTSVoiceInfo.QualityTier(avQuality: lhs.quality) > TTSVoiceInfo.QualityTier(avQuality: rhs.quality)
        }.first
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

        print(String(
            format: "[TTS DEBUG] engine=Apple speaker=%@ (%@, %@) strategy=%@ firstAudioMs=%.0f synthMs=%.0f rtf=0.00 text=%@",
            context.voiceIdentifier,
            context.voiceName,
            context.voiceLanguage,
            context.strategyLabel,
            firstAudioMs,
            firstAudioMs,
            context.spokenText.debugDescription
        ))

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
