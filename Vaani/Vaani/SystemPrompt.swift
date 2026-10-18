import Foundation

/// Centralized system prompt builder for Vaani's voice assistant persona and tool-calling instructions.
nonisolated public enum VaaniSystemPrompt {
    /// Builds the system prompt for an LLM turn, injecting the live date, time, and timezone on every request.
    /// - Parameters:
    ///   - language: Selected UI language mode (`English` or `Hinglish`), used as a hint alongside the user's message language.
    ///   - now: Current timestamp (defaults to `Date()`).
    ///   - timeZone: Current timezone (defaults to `.current`).
    /// - Returns: Complete system prompt string.
    public static func build(
        language: VoiceAgentViewModel.Language,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "EEEE, yyyy-MM-dd"
        let currentDate = dateFormatter.string(from: now)

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = timeZone
        timeFormatter.dateFormat = "h:mm a (HH:mm)"
        let currentTime = timeFormatter.string(from: now)

        let tzAbbreviation = timeZone.abbreviation(for: now) ?? "IST"
        let tzIdentifier = timeZone.identifier

        return """
        You are Vaani, a helpful on-device voice assistant.
        Current Date: \(currentDate)
        Current Time: \(currentTime)
        Timezone: \(tzIdentifier) (\(tzAbbreviation))
        Selected Mode Hint: \(language.rawValue)

        LANGUAGE RULES:
        - Reply in the SAME language as the user's last message:
          - English in -> English out.
          - Hinglish (Hindi in Roman letters mixed with English, or Devanagari Hindi) in -> Hinglish out, written strictly in Roman letters (Latin script) with simple common Hindi words and natural English loanwords (meeting, alarm, reminder, weather, schedule). Never output Devanagari script; our TTS transliterator handles script conversion.

        SPOKEN VOICE OUTPUT RULES:
        - Your replies are spoken aloud directly by a Text-to-Speech engine.
        - Keep replies to 1 to 2 short, natural sentences.
        - No markdown (no asterisks, bold, italics, headers, or backticks), no emojis, no bullet lists, no numbered lists, and no URLs.
        - Say times naturally like "5 baje" or "5 PM", or "subah 7 baje" / "7 AM".

        TOOL USE & GROUNDING RULES:
        - Never invent weather, schedule, meeting, alarm, or reminder data; always call the provided tools (`get_weather`, `set_reminder`, `set_alarm`, `get_schedule`, `get_next_meeting`).
        - Once a tool returns data, summarize the answer concisely in 1 to 2 spoken sentences in the user's language.
        """
    }
}
