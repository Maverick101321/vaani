import Foundation

// MARK: - Tool Schema & Call Types

/// JSON Schema property definition for an LLM tool parameter.
nonisolated public struct LLMToolParameterProperty: Sendable, Equatable {
    public let type: String
    public let description: String
    public let enumValues: [String]?

    public init(type: String = "string", description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }

    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "type": type,
            "description": description
        ]
        if let enumValues, !enumValues.isEmpty {
            dict["enum"] = enumValues
        }
        return dict
    }
}

/// JSON Schema definition for an LLM callable tool.
nonisolated public struct LLMToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    public let properties: [String: LLMToolParameterProperty]
    public let required: [String]

    public init(
        name: String,
        description: String,
        properties: [String: LLMToolParameterProperty] = [:],
        required: [String] = []
    ) {
        self.name = name
        self.description = description
        self.properties = properties
        self.required = required
    }

    /// Formats the tool schema for OpenAI / Groq `tools` payload.
    public func toOpenAIToolDictionary() -> [String: Any] {
        var propsDict: [String: Any] = [:]
        for (key, prop) in properties {
            propsDict[key] = prop.toDictionary()
        }
        let parameters: [String: Any] = [
            "type": "object",
            "properties": propsDict,
            "required": required
        ]
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": parameters
            ]
        ]
    }

    /// Formats the tool schema for Gemini `functionDeclarations` payload.
    public func toGeminiFunctionDeclaration() -> [String: Any] {
        var propsDict: [String: Any] = [:]
        for (key, prop) in properties {
            propsDict[key] = prop.toDictionary()
        }
        var decl: [String: Any] = [
            "name": name,
            "description": description
        ]
        if !properties.isEmpty {
            var parameters: [String: Any] = [
                "type": "OBJECT",
                "properties": propsDict
            ]
            if !required.isEmpty {
                parameters["required"] = required
            }
            decl["parameters"] = parameters
        }
        return decl
    }
}

/// Represents a tool/function call emitted by an LLM.
nonisolated public struct LLMToolCall: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Raw JSON object string of arguments (e.g. `{"city":"Bangalore","day":"tomorrow"}`).
    public let argumentsJSON: String
    /// Optional Gemini `thoughtSignature` preserved when echoing `functionCall` parts back in multi-turn tool loops.
    public let thoughtSignature: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        argumentsJSON: String,
        thoughtSignature: String? = nil
    ) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.thoughtSignature = thoughtSignature
    }

    /// Decodes `argumentsJSON` into a Swift dictionary.
    public func decodedArguments() -> [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// Helper to read a string argument with a fallback default.
    public func stringArgument(_ key: String, default fallback: String = "") -> String {
        let args = decodedArguments()
        if let str = args[key] as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallback : trimmed
        }
        if let num = args[key] as? NSNumber {
            return num.stringValue
        }
        return fallback
    }
}

// MARK: - ToolExecutor Protocol

/// Protocol abstracting tool schema definitions and execution for the voice agent loop.
nonisolated public protocol ToolExecutor: Sendable {
    /// Available tool definitions exposed to the LLM.
    var definitions: [LLMToolDefinition] { get }

    /// Executes a tool call and returns a JSON-encoded result string.
    func execute(call: LLMToolCall) async throws -> String
}

// MARK: - Default Schemas & Stub Tool Executor (Phase 4)

/// Stub `ToolExecutor` returning plausible deterministic fake data for Phase 4 (replaced by real EventKit/weather integrations in Phase 5).
nonisolated public struct StubToolExecutor: ToolExecutor, Sendable {
    public static let defaultDefinitions: [LLMToolDefinition] = [
        LLMToolDefinition(
            name: "get_weather",
            description: "Get the weather forecast and temperature in Celsius for a given city and day.",
            properties: [
                "city": LLMToolParameterProperty(
                    type: "string",
                    description: "City name, e.g. Bangalore, Mumbai, Delhi, Hyderabad."
                ),
                "day": LLMToolParameterProperty(
                    type: "string",
                    description: "Target day, e.g. today, tomorrow, or an ISO date."
                )
            ],
            required: ["city", "day"]
        ),
        LLMToolDefinition(
            name: "set_reminder",
            description: "Create a reminder with a title and scheduled ISO-8601 datetime.",
            properties: [
                "title": LLMToolParameterProperty(
                    type: "string",
                    description: "Title or subject of the reminder, e.g. meeting, call mom."
                ),
                "datetime_iso": LLMToolParameterProperty(
                    type: "string",
                    description: "ISO-8601 datetime or time string, e.g. 2026-10-19T17:00:00+05:30 or 17:00."
                )
            ],
            required: ["title", "datetime_iso"]
        ),
        LLMToolDefinition(
            name: "set_alarm",
            description: "Set an alarm for a specific ISO time or 24-hour time with an optional label.",
            properties: [
                "time_iso": LLMToolParameterProperty(
                    type: "string",
                    description: "Alarm time in ISO-8601 or HH:mm format, e.g. 07:00 or 2026-10-20T07:00:00+05:30."
                ),
                "label": LLMToolParameterProperty(
                    type: "string",
                    description: "Label for the alarm, e.g. Morning workout, Wake up."
                )
            ],
            required: ["time_iso", "label"]
        ),
        LLMToolDefinition(
            name: "get_schedule",
            description: "Get the user's calendar schedule and list of meetings for a given day.",
            properties: [
                "day": LLMToolParameterProperty(
                    type: "string",
                    description: "Day to inspect, e.g. today, tomorrow, or an ISO date."
                )
            ],
            required: ["day"]
        ),
        LLMToolDefinition(
            name: "get_next_meeting",
            description: "Get details about the user's next upcoming calendar meeting.",
            properties: [:],
            required: []
        )
    ]

    public var definitions: [LLMToolDefinition] {
        Self.defaultDefinitions
    }

    public init() {}

    public func execute(call: LLMToolCall) async throws -> String {
        switch call.name {
        case "get_weather":
            let city = call.stringArgument("city", default: "Bangalore")
            let day = call.stringArgument("day", default: "today")
            return encodeJSON(from: getWeatherStub(city: city, day: day))

        case "set_reminder":
            let title = call.stringArgument("title", default: "Meeting")
            let datetimeISO = call.stringArgument("datetime_iso", default: "5 PM")
            let spokenTime = formatSpokenTime(from: datetimeISO)
            return encodeJSON(from: [
                "status": "success",
                "action": "reminder_created",
                "title": title,
                "datetime_iso": datetimeISO,
                "spoken_time": spokenTime
            ])

        case "set_alarm":
            let timeISO = call.stringArgument("time_iso", default: "07:00")
            let label = call.stringArgument("label", default: "Alarm")
            let spokenTime = formatSpokenTime(from: timeISO)
            return encodeJSON(from: [
                "status": "success",
                "action": "alarm_set",
                "time_iso": timeISO,
                "spoken_time": spokenTime,
                "label": label
            ])

        case "get_schedule":
            let day = call.stringArgument("day", default: "today")
            return encodeJSON(from: getScheduleStub(day: day))

        case "get_next_meeting":
            return encodeJSON(from: [
                "status": "ok",
                "next_meeting": [
                    "title": "Design Review",
                    "time": "5 PM",
                    "spoken_time_hinglish": "shaam 5 baje",
                    "duration_minutes": 30,
                    "location": "Room 204"
                ]
            ])

        default:
            return encodeJSON(from: [
                "status": "error",
                "message": "Unknown tool '\(call.name)'"
            ])
        }
    }

    // MARK: - Plausible Fake Data Helpers

    private func getWeatherStub(city: String, day: String) -> [String: Any] {
        let lowerCity = city.lowercased()
        let lowerDay = day.lowercased()

        let tempC: Int
        let condition: String
        let conditionHinglish: String

        if lowerCity.contains("bangalore") || lowerCity.contains("bengaluru") {
            if lowerDay.contains("tomorrow") || lowerDay.contains("kal") {
                tempC = 24
                condition = "light rain and pleasant breeze"
                conditionHinglish = "halki baarish aur suhana mausam"
            } else {
                tempC = 25
                condition = "sunny and pleasant"
                conditionHinglish = "suhana aur dhoop wala mausam"
            }
        } else if lowerCity.contains("delhi") {
            tempC = 31
            condition = "warm and clear skies"
            conditionHinglish = "garam aur saaf aasman"
        } else if lowerCity.contains("mumbai") {
            tempC = 29
            condition = "humid with coastal breeze"
            conditionHinglish = "halki nami aur samundari hawa"
        } else if lowerCity.contains("hyderabad") {
            tempC = 28
            condition = "partly cloudy"
            conditionHinglish = "halke baadal"
        } else {
            tempC = 24
            condition = "pleasant with light clouds"
            conditionHinglish = "suhana mausam aur halke baadal"
        }

        return [
            "status": "ok",
            "city": city,
            "day": day,
            "temperature_celsius": tempC,
            "unit": "degrees Celsius",
            "condition": condition,
            "condition_hinglish": conditionHinglish
        ]
    }

    private func getScheduleStub(day: String) -> [String: Any] {
        let lowerDay = day.lowercased()
        if lowerDay.contains("tomorrow") || lowerDay.contains("kal") {
            return [
                "status": "ok",
                "day": day,
                "meeting_count": 2,
                "meetings": [
                    ["title": "Sprint Planning", "time": "10 AM", "spoken_time_hinglish": "subah 10 baje"],
                    ["title": "Client Sync", "time": "3 PM", "spoken_time_hinglish": "dopahar 3 baje"]
                ],
                "next_meeting": [
                    "title": "Sprint Planning",
                    "time": "10 AM",
                    "spoken_time_hinglish": "subah 10 baje"
                ]
            ]
        }

        return [
            "status": "ok",
            "day": day,
            "meeting_count": 3,
            "meetings": [
                ["title": "Team Standup", "time": "11 AM", "spoken_time_hinglish": "subah 11 baje"],
                ["title": "Product Sync", "time": "2 PM", "spoken_time_hinglish": "dopahar 2 baje"],
                ["title": "Design Review", "time": "5 PM", "spoken_time_hinglish": "shaam 5 baje"]
            ],
            "next_meeting": [
                "title": "Design Review",
                "time": "5 PM",
                "spoken_time_hinglish": "shaam 5 baje"
            ]
        ]
    }

    private func formatSpokenTime(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract HH:mm if ISO string like "2026-10-19T17:00:00+05:30" or "07:00"
        let pattern = #"(?:T|^|\s)(\d{1,2}):(\d{2})"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let hourRange = Range(match.range(at: 1), in: trimmed),
           let minRange = Range(match.range(at: 2), in: trimmed),
           let hour24 = Int(trimmed[hourRange]),
           let minute = Int(trimmed[minRange]) {
            let period = hour24 >= 12 ? "PM" : "AM"
            let hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24)
            if minute == 0 {
                return "\(hour12) \(period)"
            } else {
                return String(format: "%d:%02d %@", hour12, minute, period)
            }
        }
        return trimmed
    }

    private func encodeJSON(from dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"status":"ok"}"#
        }
        return str
    }
}
