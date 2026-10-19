import ActivityKit
import AlarmKit
import CoreLocation
import EventKit
import Foundation
import MapKit
import SwiftUI
import UserNotifications

// MARK: - Alarm Summary Model (Dev Inspection & UI)

/// Lightweight summary of a scheduled `AlarmKit` alarm for the Dev section list.
nonisolated public struct VaaniAlarmSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timeDescription: String
    public let stateDescription: String

    public init(id: UUID, timeDescription: String, stateDescription: String) {
        self.id = id
        self.timeDescription = timeDescription
        self.stateDescription = stateDescription
    }
}

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

// MARK: - Tool Schemas

nonisolated public enum VaaniToolDefinitions {
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
            required: []
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

}

// MARK: - Real Tool Executor (Phase 5)

/// Executes Vaani's device and network-backed tools. Permission failures are data, not thrown errors,
/// so the model can explain them briefly without interrupting the voice pipeline.
nonisolated public final class VaaniToolExecutor: ToolExecutor, @unchecked Sendable {
    public static let defaultDefinitions = VaaniToolDefinitions.defaultDefinitions

    /// Static alias map (case-insensitive, trimmed, punctuation stripped) applied before geocoding.
    public static let cityAliasMap: [String: String] = [
        // Roman script aliases -> Canonical English city names
        "bangalore": "Bengaluru",
        "bangaluru": "Bengaluru",
        "blr": "Bengaluru",
        "banglore": "Bengaluru",
        "bengaluru": "Bengaluru",
        "bombay": "Mumbai",
        "mumbai": "Mumbai",
        "hyd": "Hyderabad",
        "hyderabad": "Hyderabad",
        "madras": "Chennai",
        "chennai": "Chennai",
        "calcutta": "Kolkata",
        "kolkata": "Kolkata",
        "delhi": "New Delhi",
        "new delhi": "New Delhi",
        "ncr": "New Delhi",
        "gurgaon": "Gurugram",
        "gurugram": "Gurugram",
        "poona": "Pune",
        "pune": "Pune",
        "cochin": "Kochi",
        "kochi": "Kochi",
        "trivandrum": "Thiruvananthapuram",
        "thiruvananthapuram": "Thiruvananthapuram",
        "mysore": "Mysuru",
        "mysuru": "Mysuru",
        "vizag": "Visakhapatnam",
        "visakhapatnam": "Visakhapatnam",
        "ahmedabad": "Ahmedabad",
        "amdavad": "Ahmedabad",
        "jaipur": "Jaipur",
        "goa": "Goa",
        "panaji": "Goa",
        "panjim": "Goa",
        "lucknow": "Lucknow",
        "chandigarh": "Chandigarh",
        "indore": "Indore",
        "bhopal": "Bhopal",
        "nagpur": "Nagpur",
        "surat": "Surat",
        "noida": "Noida",

        // Devanagari script city names -> Canonical English city names
        "बेंगलुरु": "Bengaluru",
        "बंगलौर": "Bengaluru",
        "बैंगलोर": "Bengaluru",
        "मुंबई": "Mumbai",
        "मुम्बई": "Mumbai",
        "दिल्ली": "New Delhi",
        "नई दिल्ली": "New Delhi",
        "हैदराबाद": "Hyderabad",
        "चेन्नई": "Chennai",
        "कोलकाता": "Kolkata",
        "पुणे": "Pune",
        "अहमदाबाद": "Ahmedabad",
        "जयपुर": "Jaipur",
        "गोवा": "Goa",
        "लखनऊ": "Lucknow",
        "चंडीगढ़": "Chandigarh",
        "इंदौर": "Indore",
        "भोपाल": "Bhopal",
        "नागपुर": "Nagpur",
        "सूरत": "Surat",
        "नोएडा": "Noida",
        "गुरुग्राम": "Gurugram",
        "गुड़गांव": "Gurugram",
        "कोच्चि": "Kochi",
        "तिरुवनंतपुरम": "Thiruvananthapuram",
        "मैसूर": "Mysuru",
        "मैसूरु": "Mysuru",
        "विशाखापत्तनम": "Visakhapatnam"
    ]

    /// Hard-coded coordinates for ~22 major Indian cities so `get_weather` skips network geocoding completely.
    public static let indianCityCoordinates: [String: (latitude: Double, longitude: Double)] = [
        "Bengaluru": (12.9716, 77.5946),
        "Mumbai": (19.0760, 72.8777),
        "New Delhi": (28.6139, 77.2090),
        "Hyderabad": (17.3850, 78.4867),
        "Chennai": (13.0827, 80.2707),
        "Kolkata": (22.5726, 88.3639),
        "Pune": (18.5204, 73.8567),
        "Ahmedabad": (23.0225, 72.5714),
        "Jaipur": (26.9124, 75.7873),
        "Kochi": (9.9312, 76.2673),
        "Goa": (15.4909, 73.8278),
        "Lucknow": (26.8467, 80.9462),
        "Chandigarh": (30.7333, 76.7794),
        "Indore": (22.7196, 75.8577),
        "Bhopal": (23.2599, 77.4126),
        "Nagpur": (21.1458, 79.0882),
        "Surat": (21.1702, 72.8311),
        "Visakhapatnam": (17.6868, 83.2185),
        "Thiruvananthapuram": (8.5241, 76.9366),
        "Mysuru": (12.2958, 76.6394),
        "Gurugram": (28.4595, 77.0266),
        "Noida": (28.5355, 77.3910)
    ]

    public var definitions: [LLMToolDefinition] { Self.defaultDefinitions }

    public init() {}

    public func execute(call: LLMToolCall) async throws -> String {
        let started = ContinuousClock.now
        let result: String
        switch call.name {
        case "get_weather":
            let city = call.stringArgument("city")
            let day = call.stringArgument("day", default: "today")
            result = await weather(city: city, day: day)

        case "set_reminder":
            let title = call.stringArgument("title", default: "Meeting")
            result = await Self.createReminder(title: title, datetimeISO: call.stringArgument("datetime_iso"))

        case "set_alarm":
            let timeISO = call.stringArgument("time_iso")
            let label = call.stringArgument("label", default: "Alarm")
            result = await Self.createAlarm(timeISO: timeISO, label: label)

        case "get_schedule":
            let day = call.stringArgument("day", default: "today")
            result = await Self.schedule(day: day)

        case "get_next_meeting":
            result = await Self.nextMeeting()

        default:
            result = Self.json(["error": "unknown_tool", "name": call.name])
        }
        let ms = Self.milliseconds(started.duration(to: .now))
        let preview = result.prefix(120).replacingOccurrences(of: "\n", with: " ")
        print("[TOOL DEBUG] name=\(call.name) args=\(call.argumentsJSON) ms=\(String(format: "%.0f", ms)) result=\(preview)")
        return result
    }

    public func seedDemoEvents() async -> String {
        let started = ContinuousClock.now
        let result = await Self.seedDemoEventsOnMain()
        Self.log(name: "seed_demo_events", args: "{}", started: started, result: result)
        return result
    }

    public func clearDemoEvents() async -> String {
        let started = ContinuousClock.now
        let result = await Self.clearDemoEventsOnMain()
        Self.log(name: "clear_demo_events", args: "{}", started: started, result: result)
        return result
    }

    // MARK: - Dev Alarm Inspection & Controls

    @MainActor public func fetchScheduledAlarms() -> [VaaniAlarmSummary] {
        guard #available(iOS 26.0, *) else { return [] }
        do {
            let alarms = try AlarmManager.shared.alarms
            return alarms.map { alarm in
                VaaniAlarmSummary(
                    id: alarm.id,
                    timeDescription: Self.describeAlarmSchedule(alarm.schedule),
                    stateDescription: Self.describeAlarmState(alarm.state)
                )
            }
        } catch {
            print("[ALARM DEBUG] Failed to read AlarmManager.shared.alarms: \(error)")
            return []
        }
    }

    @MainActor public func cancelAllVaaniAlarms() async -> String {
        var cancelledAlarmKitCount = 0
        if #available(iOS 26.0, *) {
            if let alarms = try? AlarmManager.shared.alarms {
                for alarm in alarms {
                    do {
                        try AlarmManager.shared.cancel(id: alarm.id)
                        cancelledAlarmKitCount += 1
                    } catch {
                        print("[ALARM DEBUG] Failed to cancel AlarmKit alarm \(alarm.id): \(error)")
                    }
                }
            }
        }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let vaaniIDs = pending.map(\.identifier).filter { $0.hasPrefix("vaani-alarm-") }
        if !vaaniIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: vaaniIDs)
        }

        let result = Self.json([
            "status": "success",
            "cancelled_alarmkit": cancelledAlarmKitCount,
            "cancelled_notifications": vaaniIDs.count
        ])
        print("[ALARM DEBUG] cancelAllVaaniAlarms -> \(result)")
        return result
    }

    @MainActor public func scheduleTestAlarmInOneMinute() async -> String {
        let targetDate = Date().addingTimeInterval(60)
        let isoTarget = Self.localISO(targetDate)
        return await Self.createAlarm(timeISO: isoTarget, label: "Vaani Test Alarm")
    }

    // MARK: - Weather & Geocoding

    /// Normalizes a raw city string (trimmed, punctuation stripped, lowercased) and resolves aliases to canonical names.
    public static func resolveCanonicalCity(_ rawCity: String) -> String {
        var strippedScalars = String.UnicodeScalarView()
        let punctuationAndSymbols = CharacterSet.punctuationCharacters.union(.symbols)
        for scalar in rawCity.unicodeScalars {
            // Keep letters, digits, whitespace, and combining marks (such as Devanagari vowel matras)
            if punctuationAndSymbols.contains(scalar) {
                strippedScalars.append(" ")
            } else {
                strippedScalars.append(scalar)
            }
        }
        let cleaned = String(strippedScalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lookupKey = cleaned.lowercased()
        if let mapped = cityAliasMap[lookupKey] {
            return mapped
        }
        return cleaned.isEmpty ? rawCity.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    private func weather(city requestedCity: String, day: String) async -> String {
        let totalStart = ContinuousClock.now
        let rawCity: String
        if requestedCity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rawCity = await LocationCityResolver.resolveCity() ?? "Bengaluru"
        } else {
            rawCity = requestedCity
        }

        let resolvedCity = Self.resolveCanonicalCity(rawCity)
        let geocodeStart = ContinuousClock.now
        guard let geocoded = await geocode(rawCity: rawCity, resolvedCity: resolvedCity) else {
            let geocodeMs = Int(Self.milliseconds(geocodeStart.duration(to: .now)).rounded())
            let totalMs = Int(Self.milliseconds(totalStart.duration(to: .now)).rounded())
            print("[TOOL DEBUG] weather geocode=\(geocodeMs)ms forecast=0ms total=\(totalMs)ms city_not_found")
            return Self.json(["error": "city_not_found", "city": resolvedCity])
        }
        let geocodeMs = Int(Self.milliseconds(geocodeStart.duration(to: .now)).rounded())

        let targetDayStart = Self.dayRange(day).start
        let targetDateISO = Self.dayString(targetDayStart)
        let spokenTargetDay = Self.spokenDay(targetDayStart)
        print("[TOOL DEBUG] weather_day in=\(day) resolved=\(targetDateISO) spoken=\"\(spokenTargetDay)\"")

        let forecastStart = ContinuousClock.now
        guard let forecast = await fetchForecast(
            cityKey: geocoded.canonicalCity,
            latitude: geocoded.coordinate.latitude,
            longitude: geocoded.coordinate.longitude
        ),
              let index = forecast.daily.time.firstIndex(of: targetDateISO) else {
            let forecastMs = Int(Self.milliseconds(forecastStart.duration(to: .now)).rounded())
            let totalMs = Int(Self.milliseconds(totalStart.duration(to: .now)).rounded())
            print("[TOOL DEBUG] weather geocode=\(geocodeMs)ms forecast=\(forecastMs)ms total=\(totalMs)ms unavailable")
            return Self.json(["error": "weather_unavailable", "city": geocoded.canonicalCity, "day": spokenTargetDay])
        }
        let forecastMs = Int(Self.milliseconds(forecastStart.duration(to: .now)).rounded())
        let totalMs = Int(Self.milliseconds(totalStart.duration(to: .now)).rounded())
        print("[TOOL DEBUG] weather geocode=\(geocodeMs)ms forecast=\(forecastMs)ms total=\(totalMs)ms")

        let highDegrees = Int(forecast.daily.high[index].rounded())
        let lowDegrees = Int(forecast.daily.low[index].rounded())
        let rainChance = Int(forecast.daily.rainChance[index].rounded())
        let currentDegrees: Any
        if let currentTemp = forecast.current?.temperature {
            currentDegrees = "\(Int(currentTemp.rounded())) degrees"
        } else {
            currentDegrees = "\(highDegrees) degrees"
        }

        let wmoCode = forecast.daily.weatherCode[index]
        return Self.json([
            "city": geocoded.canonicalCity,
            "day": spokenTargetDay,
            "condition": Self.wmoDescription(wmoCode),
            "condition_hinglish": Self.wmoHinglishDescription(wmoCode),
            "temperature": currentDegrees,
            "high": "\(highDegrees) degrees",
            "low": "\(lowDegrees) degrees",
            "rain_chance": "\(rainChance) percent"
        ])
    }

    private func geocode(
        rawCity: String,
        resolvedCity: String
    ) async -> (canonicalCity: String, coordinate: CLLocationCoordinate2D)? {
        if let hardcoded = Self.indianCityCoordinates[resolvedCity] {
            print("[TOOL DEBUG] geocode in=\(rawCity) out=\(resolvedCity) lat=\(hardcoded.latitude) lon=\(hardcoded.longitude) source=hardcoded")
            return (resolvedCity, CLLocationCoordinate2D(latitude: hardcoded.latitude, longitude: hardcoded.longitude))
        }
        if let matchedEntry = Self.indianCityCoordinates.first(where: { $0.key.caseInsensitiveCompare(resolvedCity) == .orderedSame }) {
            print("[TOOL DEBUG] geocode in=\(rawCity) out=\(matchedEntry.key) lat=\(matchedEntry.value.latitude) lon=\(matchedEntry.value.longitude) source=hardcoded")
            return (matchedEntry.key, CLLocationCoordinate2D(latitude: matchedEntry.value.latitude, longitude: matchedEntry.value.longitude))
        }

        if let match = await queryOpenMeteoGeocode(query: resolvedCity) {
            let canonicalName = Self.cityAliasMap[resolvedCity.lowercased()] ?? match.name ?? resolvedCity
            print("[TOOL DEBUG] geocode in=\(rawCity) out=\(canonicalName) lat=\(match.latitude) lon=\(match.longitude) source=network")
            return (canonicalName, CLLocationCoordinate2D(latitude: match.latitude, longitude: match.longitude))
        }

        let retryQuery = "\(resolvedCity), India"
        if let retryMatch = await queryOpenMeteoGeocode(query: retryQuery) {
            let canonicalName = Self.cityAliasMap[resolvedCity.lowercased()] ?? retryMatch.name ?? resolvedCity
            print("[TOOL DEBUG] geocode in=\(rawCity) out=\(canonicalName) lat=\(retryMatch.latitude) lon=\(retryMatch.longitude) source=network")
            return (canonicalName, CLLocationCoordinate2D(latitude: retryMatch.latitude, longitude: retryMatch.longitude))
        }

        print("[TOOL DEBUG] geocode in=\(rawCity) out=\(resolvedCity) lat=none lon=none")
        return nil
    }

    private func queryOpenMeteoGeocode(query: String) async -> OpenMeteoGeocode.Result? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "language", value: "en")
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(OpenMeteoGeocode.self, from: data),
              let results = decoded.results,
              !results.isEmpty else {
            return nil
        }

        if let indianMatch = results.first(where: { $0.countryCode?.uppercased() == "IN" }) {
            return indianMatch
        }
        return results.first
    }

    private func fetchForecast(cityKey: String, latitude: Double, longitude: Double) async -> OpenMeteoForecast? {
        if let cached = ForecastCache.shared.get(for: cityKey) {
            print("[TOOL DEBUG] forecast city=\(cityKey) source=cache")
            return cached
        }
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "current", value: "temperature_2m"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7")
        ]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(OpenMeteoForecast.self, from: data) else { return nil }
        ForecastCache.shared.set(decoded, for: cityKey)
        print("[TOOL DEBUG] forecast city=\(cityKey) source=network")
        return decoded
    }

    // MARK: - EventKit and AlarmKit

    @MainActor private static func createReminder(title: String, datetimeISO: String) async -> String {
        guard let date = dateTime(datetimeISO) else { return json(["error": "invalid_datetime"]) }
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToReminders() else { return json(["error": "reminders_access_denied"]) }
            let reminder = EKReminder(eventStore: store)
            reminder.title = title
            reminder.calendar = store.defaultCalendarForNewReminders()
            reminder.dueDateComponents = Calendar.current.dateComponents(in: .current, from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
            try store.save(reminder, commit: true)
            return json([
                "status": "success",
                "action": "reminder_created",
                "title": title,
                "datetime_spoken": spokenDateTime(date),
                "datetime_iso": localISO(date)
            ])
        } catch {
            return json(["error": "reminders_access_denied"])
        }
    }

    @MainActor private static func createAlarm(timeISO: String, label: String) async -> String {
        guard let date = dateTime(timeISO) else {
            print("[ALARM DEBUG] createAlarm failed: invalid_datetime for input=\"\(timeISO)\"")
            return json(["error": "invalid_datetime", "input": timeISO])
        }
        guard date > Date() else {
            print("[ALARM DEBUG] createAlarm failed: alarm_time_in_past for resolved=\(localISO(date))")
            return json(["error": "alarm_time_in_past", "resolved_iso": localISO(date)])
        }

        let usageDescription = Bundle.main.object(forInfoDictionaryKey: "NSAlarmKitUsageDescription") as? String
        let resolvedISO = localISO(date)
        let resolvedSpoken = spokenDateTime(date)
        let alarmUUID = UUID()

        if #available(iOS 26.0, *) {
            let authBefore = AlarmManager.shared.authorizationState
            print("[ALARM DEBUG] id=\(alarmUUID) resolved=\(resolvedISO) spoken=\"\(resolvedSpoken)\" authBefore=\(authBefore) NSAlarmKitUsageDescription=\"\(usageDescription ?? "MISSING")\"")
            do {
                let authAfter = try await AlarmManager.shared.requestAuthorization()
                print("[ALARM DEBUG] id=\(alarmUUID) authAfter=\(authAfter)")
                guard authAfter == .authorized else {
                    return await notificationAlarm(date: date, label: label, reason: "alarmkit_denied(\(authAfter))")
                }

                let alertPresentation = AlarmPresentation.Alert(
                    title: LocalizedStringResource(stringLiteral: label)
                )
                let presentation = AlarmPresentation(alert: alertPresentation)
                let attributes = AlarmAttributes(
                    presentation: presentation,
                    metadata: VaaniAlarmMetadata(label: label),
                    tintColor: .accentColor
                )
                let configuration = AlarmManager.AlarmConfiguration.alarm(
                    schedule: .fixed(date),
                    attributes: attributes,
                    sound: .default
                )
                _ = try await AlarmManager.shared.schedule(id: alarmUUID, configuration: configuration)

                // Re-query AlarmManager.shared.alarms and confirm the UUID is present before returning success
                let scheduledAlarms = try AlarmManager.shared.alarms
                let isPresent = scheduledAlarms.contains(where: { $0.id == alarmUUID })
                print("[ALARM DEBUG] id=\(alarmUUID) verifiedInAlarms=\(isPresent) totalScheduled=\(scheduledAlarms.count)")

                guard isPresent else {
                    return await notificationAlarm(
                        date: date,
                        label: label,
                        reason: "alarmkit_uuid_not_found_after_schedule"
                    )
                }

                return json([
                    "status": "success",
                    "action": "alarm_set",
                    "engine": "AlarmKit",
                    "alarm_id": alarmUUID.uuidString,
                    "time_spoken": resolvedSpoken,
                    "time_iso": resolvedISO,
                    "label": label
                ])
            } catch {
                print("[ALARM DEBUG] id=\(alarmUUID) AlarmKit schedule error: \(error)")
                return await notificationAlarm(
                    date: date,
                    label: label,
                    reason: "alarmkit_failed(\(error.localizedDescription))"
                )
            }
        }
        return await notificationAlarm(date: date, label: label, reason: "alarmkit_unavailable")
    }

    @MainActor private static func notificationAlarm(date: Date, label: String, reason: String) async -> String {
        let center = UNUserNotificationCenter.current()
        let resolvedISO = localISO(date)
        let resolvedSpoken = spokenDateTime(date)
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                return json(["error": "alarm_access_denied", "fallback": "UNUserNotificationCenter", "reason": reason])
            }
            let content = UNMutableNotificationContent()
            content.title = label
            content.body = "Vaani alarm (\(resolvedSpoken))"
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNCalendarNotificationTrigger(
                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                repeats: false
            )
            let reqID = "vaani-alarm-\(UUID().uuidString)"
            try await center.add(UNNotificationRequest(identifier: reqID, content: content, trigger: trigger))
            print("[ALARM DEBUG] Fell back to UNUserNotificationCenter id=\(reqID) reason=\(reason) resolved=\(resolvedISO)")
            return json([
                "status": "success",
                "action": "alarm_set",
                "engine": "UNUserNotificationCenter",
                "fallback": "UNUserNotificationCenter",
                "reason": reason,
                "time_spoken": resolvedSpoken,
                "time_iso": resolvedISO,
                "label": label
            ])
        } catch {
            return json([
                "error": "alarm_notification_failed",
                "fallback": "UNUserNotificationCenter",
                "reason": reason
            ])
        }
    }

    @MainActor private static func schedule(day: String) async -> String {
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToEvents() else { return json(["error": "calendar_access_denied"]) }
            let range = dayRange(day)
            let targetCalendars: [EKCalendar]?
            if kDemoCalendarOnly {
                guard let demoCal = store.calendars(for: .event).first(where: { $0.title == "Vaani Demo" }) else {
                    return json([
                        "day": spokenDay(range.start),
                        "meeting_count": 0,
                        "meetings": []
                    ])
                }
                targetCalendars = [demoCal]
            } else {
                targetCalendars = nil
            }
            let events = store.events(
                matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: targetCalendars)
            ).sorted { $0.startDate < $1.startDate }
            let meetings: [[String: Any]] = events.map {
                [
                    "title": $0.title ?? "Untitled",
                    "start_spoken": spokenTime($0.startDate),
                    "start": localISO($0.startDate)
                ]
            }
            return json([
                "day": spokenDay(range.start),
                "meeting_count": events.count,
                "meetings": meetings
            ])
        } catch {
            return json(["error": "calendar_access_denied"])
        }
    }

    @MainActor private static func nextMeeting() async -> String {
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToEvents() else { return json(["error": "calendar_access_denied"]) }
            let now = Date()
            let end = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
            let targetCalendars: [EKCalendar]?
            if kDemoCalendarOnly {
                guard let demoCal = store.calendars(for: .event).first(where: { $0.title == "Vaani Demo" }) else {
                    return json(["next_meeting": "none"])
                }
                targetCalendars = [demoCal]
            } else {
                targetCalendars = nil
            }
            let next = store.events(
                matching: store.predicateForEvents(withStart: now, end: end, calendars: targetCalendars)
            ).filter { $0.startDate >= now }.min { $0.startDate < $1.startDate }
            guard let next else { return json(["next_meeting": "none"]) }
            return json([
                "next_meeting": [
                    "title": next.title ?? "Untitled",
                    "start_spoken": spokenDateTime(next.startDate),
                    "start": localISO(next.startDate)
                ]
            ])
        } catch {
            return json(["error": "calendar_access_denied"])
        }
    }

    @MainActor private static func seedDemoEventsOnMain() async -> String {
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToEvents() else { return json(["error": "calendar_access_denied"]) }
            guard let calendar = try demoCalendar(in: store) else { return json(["error": "demo_calendar_unavailable"]) }

            let now = Date()
            let sweepStart = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            let sweepEnd = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
            let existingEvents = store.events(matching: store.predicateForEvents(withStart: sweepStart, end: sweepEnd, calendars: [calendar]))
            for existing in existingEvents {
                try store.remove(existing, span: .thisEvent, commit: false)
            }

            let tomorrowStart = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(24 * 3600)
            let tomorrowTenAM = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrowStart) ?? tomorrowStart.addingTimeInterval(10 * 3600)

            let specs: [(title: String, start: Date)] = [
                ("Team Standup", now.addingTimeInterval(45 * 60)),
                ("Product Sync", now.addingTimeInterval(3 * 3600)),
                ("Design Review", tomorrowTenAM)
            ]

            var created = 0
            for spec in specs {
                let event = EKEvent(eventStore: store)
                event.title = spec.title
                event.startDate = spec.start
                event.endDate = spec.start.addingTimeInterval(30 * 60)
                event.calendar = calendar
                try store.save(event, span: .thisEvent, commit: false)
                created += 1
            }
            try store.commit()
            return json(["status": "success", "cleared": existingEvents.count, "created": created])
        } catch { return json(["error": "demo_events_failed"]) }
    }

    @MainActor private static func clearDemoEventsOnMain() async -> String {
        let store = EKEventStore()
        do {
            guard try await store.requestFullAccessToEvents() else { return json(["error": "calendar_access_denied"]) }
            guard let calendar = store.calendars(for: .event).first(where: { $0.title == "Vaani Demo" }) else { return json(["status": "success", "cleared": 0]) }
            let now = Date()
            let start = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? Calendar.current.startOfDay(for: now)
            let end = Calendar.current.date(byAdding: .day, value: 90, to: now) ?? now
            let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: [calendar]))
            for event in events { try store.remove(event, span: .thisEvent, commit: false) }
            if !events.isEmpty { try store.commit() }
            return json(["status": "success", "cleared": events.count])
        } catch { return json(["error": "demo_events_failed"]) }
    }

    @MainActor private static func demoCalendar(in store: EKEventStore) throws -> EKCalendar? {
        if let existing = store.calendars(for: .event).first(where: { $0.title == "Vaani Demo" }) { return existing }
        guard let source = store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local || $0.sourceType == .calDAV }) else { return nil }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Vaani Demo"
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }

    // MARK: - Date, Relative Time & Spoken Formatting

    /// Resolves ISO-8601 dates, 24-hour times, and relative Hinglish/English phrases (`"kal subah 7 baje"`, `"aaj shaam 6 baje"`, bare `"7"` rolling to next occurrence).
    public static func dateTime(_ text: String, now: Date = Date()) -> Date? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let calendar = Calendar.current

        // 1. Standard ISO-8601 with timezone offset (e.g. "2026-10-20T07:00:00+05:30")
        let iso = ISO8601DateFormatter()
        if let parsedISO = iso.date(from: raw) {
            let resolved = rollForwardIfSameTimePastToday(parsedISO, rawText: raw, now: now, calendar: calendar)
            print("[TOOL DEBUG] parse_time in=\"\(raw)\" resolved=\(localISO(resolved)) spoken=\"\(spokenDateTime(resolved))\"")
            return resolved
        }

        // 2. Local ISO-like date+time formats without offset
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd h:mm a"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: raw) {
                let resolved = rollForwardIfSameTimePastToday(parsed, rawText: raw, now: now, calendar: calendar)
                print("[TOOL DEBUG] parse_time in=\"\(raw)\" resolved=\(localISO(resolved)) spoken=\"\(spokenDateTime(resolved))\"")
                return resolved
            }
        }

        let lower = raw.lowercased()

        // 3. Relative offset in minutes ("in 1 min", "in 5 minutes")
        if let minMatch = lower.range(of: #"\bin\s+(\d+)\s*(?:min|mins|minute|minutes)\b"#, options: .regularExpression) {
            let digits = lower[minMatch].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let mins = Double(digits), mins > 0 {
                let resolved = now.addingTimeInterval(mins * 60.0)
                print("[TOOL DEBUG] parse_time in=\"\(raw)\" resolved=\(localISO(resolved)) spoken=\"\(spokenDateTime(resolved))\"")
                return resolved
            }
        }

        // 4. Relative day + time phrases ("kal subah 7 baje", "aaj shaam 6 baje", "7:00", "7 AM", "5 PM", bare "7")
        var dayOffset: Int? = nil
        if lower.range(of: #"\b(parso|parson|day\s+after\s+tomorrow)\b"#, options: .regularExpression) != nil || lower.contains("परसों") {
            dayOffset = 2
        } else if lower.range(of: #"\b(kal|tomorrow)\b"#, options: .regularExpression) != nil || lower.contains("कल") {
            dayOffset = 1
        } else if lower.range(of: #"\b(aaj|today)\b"#, options: .regularExpression) != nil || lower.contains("आज") {
            dayOffset = 0
        }

        enum MeridiemHint {
            case am
            case pm
            case night
            case none
        }

        let meridiem: MeridiemHint
        if lower.range(of: #"\b(subah|morning|am|a\.m\.)\b"#, options: .regularExpression) != nil || lower.contains("सुबह") {
            meridiem = .am
        } else if lower.range(of: #"\b(shaam|sham|evening|dopahar|afternoon|pm|p\.m\.)\b"#, options: .regularExpression) != nil || lower.contains("शाम") || lower.contains("दोपहर") {
            meridiem = .pm
        } else if lower.range(of: #"\b(raat|night)\b"#, options: .regularExpression) != nil || lower.contains("रात") {
            meridiem = .night
        } else {
            meridiem = .none
        }

        // Extract hour and optional minute (ignoring 4-digit years)
        guard let (rawHour, rawMinute) = extractHourAndMinute(from: lower) else {
            return nil
        }

        var hour = rawHour
        let minute = rawMinute

        switch meridiem {
        case .am:
            if hour == 12 { hour = 0 }
        case .pm:
            if hour < 12 { hour += 12 }
        case .night:
            if hour == 12 {
                hour = 0
            } else if hour >= 5 && hour < 12 {
                hour += 12
            }
        case .none:
            break
        }

        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }

        let todayStart = calendar.startOfDay(for: now)
        let baseDay = calendar.date(byAdding: .day, value: dayOffset ?? 0, to: todayStart) ?? todayStart
        guard var candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: baseDay) else {
            return nil
        }

        if candidate <= now {
            if dayOffset == nil {
                // Bare time ("7", "07:00", "7 AM") that has already passed today:
                // Always roll to the next occurrence (tomorrow at the same hour/minute)
                if let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate) {
                    candidate = tomorrow
                }
            } else if dayOffset == 0 {
                // Explicit "aaj" / "today": if meridiem was unspecified and hour < 12, try PM today first; otherwise roll to tomorrow
                if meridiem == .none && hour < 12,
                   let pmCandidate = calendar.date(bySettingHour: hour + 12, minute: minute, second: 0, of: baseDay),
                   pmCandidate > now {
                    candidate = pmCandidate
                } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: candidate) {
                    candidate = tomorrow
                }
            }
        }

        print("[TOOL DEBUG] parse_time in=\"\(raw)\" resolved=\(localISO(candidate)) spoken=\"\(spokenDateTime(candidate))\"")
        return candidate
    }

    private static func rollForwardIfSameTimePastToday(
        _ parsed: Date,
        rawText: String,
        now: Date,
        calendar: Calendar
    ) -> Date {
        guard parsed <= now else { return parsed }
        // If the LLM accidentally passed today's date with a past time (e.g. "2026-10-19T07:00:00+05:30" when it's 22:00 on Oct 19), roll forward 1 day
        if calendar.isDate(parsed, inSameDayAs: now),
           let nextDay = calendar.date(byAdding: .day, value: 1, to: parsed) {
            return nextDay
        }
        return parsed
    }

    private static func extractHourAndMinute(from text: String) -> (Int, Int)? {
        // Match HH:mm first
        if let colonRange = text.range(of: #"\b([01]?\d|2[0-3]):([0-5]\d)\b"#, options: .regularExpression) {
            let parts = text[colonRange].split(separator: ":")
            if parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                return (h, m)
            }
        }
        // Match bare 1-2 digit hour (e.g. "7", "7 baje", "7 am", "18")
        if let hourRange = text.range(of: #"\b([01]?\d|2[0-3])\b"#, options: .regularExpression) {
            if let h = Int(text[hourRange]) {
                return (h, 0)
            }
        }
        return nil
    }

    /// Resolves `"today"`, `"tomorrow"`, `"kal"`, `"aaj"`, `"parso"`, weekday names, and explicit dates into a calendar day range.
    public static func dayRange(_ day: String, now: Date = Date()) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let normalized = day
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let start: Date
        if normalized == "today" || normalized == "aaj" || normalized == "आज" || normalized.isEmpty {
            start = today
        } else if normalized == "tomorrow" || normalized == "kal" || normalized == "कल" {
            start = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        } else if normalized == "parso" || normalized == "parson" || normalized == "day after tomorrow" || normalized == "परसों" {
            start = calendar.date(byAdding: .day, value: 2, to: today) ?? today
        } else if let targetWeekday = weekdayNumber(for: normalized) {
            let currentWeekday = calendar.component(.weekday, from: today)
            let delta = (targetWeekday - currentWeekday + 7) % 7
            start = calendar.date(byAdding: .day, value: delta, to: today) ?? today
        } else if let parsed = dayOnly(day.trimmingCharacters(in: .whitespacesAndNewlines)) {
            start = calendar.startOfDay(for: parsed)
        } else {
            start = today
        }

        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        print("[TOOL DEBUG] resolve_day in=\"\(day)\" resolved=\(dayString(start)) spoken=\"\(spokenDay(start))\"")
        return (start, end)
    }

    private static func weekdayNumber(for token: String) -> Int? {
        let words = token.split(separator: " ").map(String.init)
        let map: [String: Int] = [
            "sunday": 1, "sun": 1, "ravivar": 1, "itvaar": 1,
            "monday": 2, "mon": 2, "somvar": 2,
            "tuesday": 3, "tue": 3, "tues": 3, "mangalvar": 3,
            "wednesday": 4, "wed": 4, "budhvar": 4,
            "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "guruvar": 5, "brihaspativar": 5,
            "friday": 6, "fri": 6, "shukravar": 6,
            "saturday": 7, "sat": 7, "shanivar": 7
        ]
        for word in words {
            if let num = map[word] {
                return num
            }
        }
        return nil
    }

    private static func weatherDate(for day: String) -> String { dayString(dayRange(day).start) }

    private static func dayOnly(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd", "MMMM d, yyyy", "MMM d, yyyy", "MMMM d", "MMM d", "d MMMM", "d MMM"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: string) {
                if !format.contains("yyyy") {
                    var comps = Calendar.current.dateComponents([.month, .day], from: parsed)
                    comps.year = Calendar.current.component(.year, from: Date())
                    return Calendar.current.date(from: comps)
                }
                return parsed
            }
        }
        return nil
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func spokenDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: date)
    }

    public static func spokenTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    public static func spokenDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEEE, MMMM d 'at' h:mm a"
        return formatter.string(from: date)
    }

    public static func localISO(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    @available(iOS 26.0, *)
    private static func describeAlarmSchedule(_ schedule: Alarm.Schedule?) -> String {
        guard let schedule else { return "Unscheduled" }
        switch schedule {
        case .fixed(let date):
            return spokenDateTime(date)
        case .relative(let relative):
            return String(format: "%02d:%02d", relative.time.hour, relative.time.minute)
        @unknown default:
            return "Scheduled"
        }
    }

    @available(iOS 26.0, *)
    private static func describeAlarmState(_ state: Alarm.State) -> String {
        switch state {
        case .scheduled: return "scheduled"
        case .countdown: return "countdown"
        case .paused: return "paused"
        case .alerting: return "alerting"
        @unknown default: return "unknown"
        }
    }

    private static func wmoDescription(_ code: Int) -> String {
        switch code {
        case 0: return "clear sky"; case 1: return "mainly clear"; case 2: return "partly cloudy"; case 3: return "overcast"
        case 45, 48: return "foggy"; case 51, 53, 55: return "drizzle"; case 56, 57: return "freezing drizzle"
        case 61, 63, 65: return "rain"; case 66, 67: return "freezing rain"; case 71, 73, 75, 77: return "snow"
        case 80, 81, 82: return "rain showers"; case 85, 86: return "snow showers"; case 95: return "thunderstorm"
        case 96, 99: return "thunderstorm with hail"; default: return "unknown conditions"
        }
    }

    private static func wmoHinglishDescription(_ code: Int) -> String {
        switch code {
        case 0, 1: return "aasman saaf hai"
        case 2, 3: return "badal chhaye hain"
        case 45, 48: return "kohra hai"
        case 51, 53, 55, 56, 57: return "halki baarish ho rahi hai"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "baarish hogi"
        case 71, 73, 75, 77, 85, 86: return "baraf padegi"
        case 95, 96, 99: return "aandhi-toofan"
        default: return "mausam saaf hai"
        }
    }

    private static func log(name: String, args: String, started: ContinuousClock.Instant, result: String) {
        let ms = milliseconds(started.duration(to: .now))
        print("[TOOL DEBUG] name=\(name) args=\(args) ms=\(String(format: "%.0f", ms)) result=\(result.prefix(120))")
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"error":"encoding_failed"}"#
        }
        return str
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1_000_000_000_000_000
    }
}

@available(iOS 26.0, *)
nonisolated private struct VaaniAlarmMetadata: AlarmMetadata { let label: String }

nonisolated private struct OpenMeteoGeocode: Decodable {
    nonisolated struct Result: Decodable {
        let name: String?
        let latitude: Double
        let longitude: Double
        let countryCode: String?

        enum CodingKeys: String, CodingKey {
            case name
            case latitude
            case longitude
            case countryCode = "country_code"
        }
    }
    let results: [Result]?
}

nonisolated private struct OpenMeteoForecast: Decodable, Sendable {
    nonisolated struct Daily: Decodable, Sendable {
        let time: [String]
        let weatherCode: [Int]
        let high: [Double]
        let low: [Double]
        let rainChance: [Double]
        enum CodingKeys: String, CodingKey { case time; case weatherCode = "weather_code"; case high = "temperature_2m_max"; case low = "temperature_2m_min"; case rainChance = "precipitation_probability_max" }
    }
    nonisolated struct Current: Decodable, Sendable { let temperature: Double; enum CodingKeys: String, CodingKey { case temperature = "temperature_2m" } }
    let timezoneCity: String?
    let current: Current?
    let daily: Daily
    enum CodingKeys: String, CodingKey { case timezoneCity = "timezone"; case current; case daily }
}

nonisolated private final class ForecastCache: @unchecked Sendable {
    static let shared = ForecastCache()
    private let lock = NSLock()
    private var entries: [String: (forecast: OpenMeteoForecast, expiresAt: Date)] = [:]
    private let ttlSeconds: TimeInterval = 600 // 10 minutes

    func get(for city: String, now: Date = Date()) -> OpenMeteoForecast? {
        let key = city.lowercased()
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        if entry.expiresAt > now {
            return entry.forecast
        }
        entries.removeValue(forKey: key)
        return nil
    }

    func set(_ forecast: OpenMeteoForecast, for city: String, now: Date = Date()) {
        let key = city.lowercased()
        lock.lock()
        defer { lock.unlock() }
        entries[key] = (forecast, now.addingTimeInterval(ttlSeconds))
    }
}

@MainActor private final class LocationCityResolver: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    static func resolveCity() async -> String? {
        let resolver = LocationCityResolver()
        guard let location = await resolver.requestLocation() else { return nil }
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = (try? await request.mapItems)?.first else { return nil }
        return item.addressRepresentations?.cityName
    }

    private func requestLocation() async -> CLLocation? {
        guard CLLocationManager.locationServicesEnabled() else { return nil }
        manager.delegate = self
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { return nil }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            if status == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: manager.requestLocation()
        case .denied, .restricted: finish(nil)
        default: break
        }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) { finish(locations.last) }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { finish(nil) }
    private func finish(_ location: CLLocation?) { continuation?.resume(returning: location); continuation = nil }
}
