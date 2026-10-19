import Foundation

// MARK: - LLM Configuration (Single Place)

/// Supported cloud LLM providers.
nonisolated public enum LLMProvider: String, CaseIterable, Sendable, Identifiable {
    case groq = "Groq"
    case gemini = "Gemini"

    public var id: String { rawValue }
}

/// Single entry in the ordered cross-provider LLM fallback chain.
nonisolated public struct LLMChainEntry: Sendable, Equatable, Identifiable {
    public let provider: LLMProvider
    public let model: String

    public var id: String { "\(provider.rawValue):\(model)" }

    public init(provider: LLMProvider, model: String) {
        self.provider = provider
        self.model = model
    }
}

/// Centralized configuration for LLM providers, ordered model fallback chain, generation parameters, and timeouts.
nonisolated public struct LLMConfig: Sendable, Equatable {
    /// Editable primary Groq model name.
    public static let defaultGroqModel: String = "openai/gpt-oss-120b"
    /// Editable secondary Groq fallback model name.
    public static let defaultGroqFallbackModel: String = "openai/gpt-oss-20b"
    /// Editable primary Gemini model name.
    public static let defaultGeminiModel: String = "gemini-3.5-flash-lite"
    /// Editable secondary Gemini fallback model name.
    public static let defaultGeminiFallbackModel: String = "gemini-3.1-flash-lite"

    /// Default ordered fallback chain across providers:
    /// Groq `openai/gpt-oss-120b` -> Groq `openai/gpt-oss-20b` -> Gemini `gemini-3.5-flash-lite` -> Gemini `gemini-3.1-flash-lite`.
    public static let defaultChain: [LLMChainEntry] = [
        LLMChainEntry(provider: .groq, model: defaultGroqModel),
        LLMChainEntry(provider: .groq, model: defaultGroqFallbackModel),
        LLMChainEntry(provider: .gemini, model: defaultGeminiModel),
        LLMChainEntry(provider: .gemini, model: defaultGeminiFallbackModel)
    ]

    /// Default provider fallback order: Groq first, then Gemini.
    public static let defaultProviderOrder: [LLMProvider] = [.groq, .gemini]

    public var chain: [LLMChainEntry]
    public var providerOrder: [LLMProvider]
    public var groqModel: String
    public var geminiModel: String
    public var temperature: Double
    public var maxTokens: Int
    public var timeoutSeconds: TimeInterval

    public init(
        chain: [LLMChainEntry] = LLMConfig.defaultChain,
        providerOrder: [LLMProvider] = LLMConfig.defaultProviderOrder,
        groqModel: String = LLMConfig.defaultGroqModel,
        geminiModel: String = LLMConfig.defaultGeminiModel,
        temperature: Double = 0.3,
        maxTokens: Int = 512,
        timeoutSeconds: TimeInterval = 8.0
    ) {
        self.chain = chain
        self.providerOrder = providerOrder
        self.groqModel = groqModel
        self.geminiModel = geminiModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
    }

    public func modelName(for provider: LLMProvider) -> String {
        switch provider {
        case .groq:
            return groqModel
        case .gemini:
            return geminiModel
        }
    }
}

// MARK: - LLM Errors

/// Structured errors for LLM requests and cross-provider fallback decisions.
nonisolated public enum LLMError: LocalizedError, Sendable, Equatable {
    case missingAPIKey(provider: LLMProvider)
    case missingAllAPIKeys
    case timeout(provider: LLMProvider, model: String = "", seconds: TimeInterval)
    case httpError(provider: LLMProvider, model: String = "", statusCode: Int, message: String)
    case invalidResponse(provider: LLMProvider, model: String = "", details: String)
    case chainFailed(groqError: String?, geminiError: String?, details: [String])

    /// Redacts any accidental API key appearance and collapses whitespace to at most `maxChars` characters.
    public static func sanitizeErrorSnippet(_ raw: String, maxChars: Int = 200) -> String {
        var cleaned = raw
        let groqKey = Secrets.groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !groqKey.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: groqKey, with: "[REDACTED]")
        }
        let geminiKey = Secrets.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !geminiKey.isEmpty {
            cleaned = cleaned.replacingOccurrences(of: geminiKey, with: "[REDACTED]")
        }
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > maxChars {
            return String(cleaned.prefix(maxChars))
        }
        return cleaned
    }

    public var provider: LLMProvider? {
        switch self {
        case .missingAPIKey(let provider),
             .timeout(let provider, _, _),
             .httpError(let provider, _, _, _),
             .invalidResponse(let provider, _, _):
            return provider
        case .missingAllAPIKeys, .chainFailed:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "\(provider.rawValue) key missing"
        case .missingAllAPIKeys:
            return "Groq key missing | Gemini key missing"
        case .timeout(let provider, let model, let seconds):
            let modelTag = model.isEmpty ? "" : " (\(model))"
            return "\(provider.rawValue)\(modelTag) HTTP timeout (\(Int(seconds))s)"
        case .httpError(let provider, let model, let statusCode, let message):
            let snippet = Self.sanitizeErrorSnippet(message, maxChars: 200)
            let modelTag = model.isEmpty ? "" : " (\(model))"
            if statusCode == 401 {
                if snippet.isEmpty {
                    return "\(provider.rawValue) key invalid (HTTP 401)"
                }
                return "\(provider.rawValue) key invalid (HTTP 401: \(snippet))"
            }
            if snippet.isEmpty {
                return "\(provider.rawValue)\(modelTag) HTTP \(statusCode)"
            }
            return "\(provider.rawValue)\(modelTag) HTTP \(statusCode): \(snippet)"
        case .invalidResponse(let provider, let model, let details):
            let snippet = Self.sanitizeErrorSnippet(details, maxChars: 200)
            let modelTag = model.isEmpty ? "" : " (\(model))"
            return "\(provider.rawValue)\(modelTag) invalid response: \(snippet)"
        case .chainFailed(let groqError, let geminiError, let details):
            var parts: [String] = []
            if let groqError, !groqError.isEmpty {
                parts.append(groqError)
            }
            if let geminiError, !geminiError.isEmpty {
                parts.append(geminiError)
            }
            if !parts.isEmpty {
                return parts.joined(separator: " | ")
            }
            return details.joined(separator: " | ")
        }
    }

    /// Determines whether `AgentOrchestrator` should advance to the next entry in the fallback chain.
    /// Advances on: 404, 400, 401, 403, 429, 5xx, timeout, missing key, or invalid response.
    public var shouldFallbackToNextProvider: Bool {
        switch self {
        case .missingAPIKey:
            return true
        case .missingAllAPIKeys:
            return false
        case .timeout:
            return true
        case .httpError(_, _, let statusCode, _):
            if statusCode == 400
                || statusCode == 401
                || statusCode == 403
                || statusCode == 404
                || statusCode == 429
                || (500...599).contains(statusCode) {
                return true
            }
            return true
        case .invalidResponse:
            return true
        case .chainFailed:
            return false
        }
    }
}

// MARK: - Timeout Helper

/// Runs an async operation with a strict timeout in seconds, throwing `LLMError.timeout` if exceeded.
nonisolated func withLLMTimeout<T: Sendable>(
    provider: LLMProvider,
    model: String = "",
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LLMError.timeout(provider: provider, model: model, seconds: seconds)
        }
        guard let first = try await group.next() else {
            throw LLMError.timeout(provider: provider, model: model, seconds: seconds)
        }
        group.cancelAll()
        return first
    }
}

// MARK: - GroqClient (OpenAI-Compatible SSE Streaming)

/// OpenAI-compatible streaming client for Groq (`https://api.groq.com/openai/v1/chat/completions`).
nonisolated public final class GroqClient: LLMClient, Sendable {
    public static let endpointURL = URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    public let config: LLMConfig
    private let apiKeyProvider: @Sendable () -> String
    private let session: URLSession

    public nonisolated init(
        config: LLMConfig = LLMConfig(),
        apiKeyProvider: @escaping @Sendable () -> String = { Secrets.groqKey }
    ) {
        self.config = config
        self.apiKeyProvider = apiKeyProvider

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeoutSeconds
        sessionConfig.timeoutIntervalForResource = config.timeoutSeconds
        self.session = URLSession(configuration: sessionConfig)
    }

    public nonisolated func generateResponse(prompt: String, language: VoiceAgentViewModel.Language) async throws -> String {
        let systemPrompt = VaaniSystemPrompt.build(language: language)
        let result = try await streamChat(
            messages: [.user(prompt)],
            systemPrompt: systemPrompt,
            tools: [],
            modelOverride: nil,
            onFirstToken: nil,
            onTextDelta: nil
        )
        return result.text
    }

    public nonisolated func streamChat(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        onFirstToken: (@Sendable () -> Void)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMStreamResult {
        try await streamChat(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            modelOverride: nil,
            onFirstToken: onFirstToken,
            onTextDelta: onTextDelta
        )
    }

    public nonisolated func streamChat(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        modelOverride: String?,
        onFirstToken: (@Sendable () -> Void)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMStreamResult {
        let rawKey = apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            throw LLMError.missingAPIKey(provider: .groq)
        }

        let modelName = modelOverride ?? config.groqModel
        let timeoutSec = config.timeoutSeconds
        let request = try buildURLRequest(
            apiKey: rawKey,
            modelName: modelName,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools
        )

        return try await withLLMTimeout(provider: .groq, model: modelName, seconds: timeoutSec) { [session] in
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw LLMError.timeout(provider: .groq, model: modelName, seconds: timeoutSec)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse(provider: .groq, model: modelName, details: "Non-HTTP response")
            }

            if !(200...299).contains(httpResponse.statusCode) {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line + "\n"
                    if errorBody.count > 4096 { break }
                }

                // Handle Groq `<function=name>{...}</function>` tool_use_failed 400 error if it occurs
                if httpResponse.statusCode == 400,
                   let recoveredCall = Self.recoverGroqFailedToolGeneration(from: errorBody) {
                    onFirstToken?()
                    return LLMStreamResult(
                        text: "",
                        toolCalls: [recoveredCall],
                        providerName: LLMProvider.groq.rawValue,
                        modelName: modelName
                    )
                }

                let errorSnippet = Self.errorBodySnippet(errorBody)
                throw LLMError.httpError(
                    provider: .groq,
                    model: modelName,
                    statusCode: httpResponse.statusCode,
                    message: errorSnippet
                )
            }

            var accumulatedText = ""
            var didEmitFirstToken = false
            var insideThinkTag = false

            struct PartialToolCall {
                var id: String = ""
                var name: String = ""
                var arguments: String = ""
            }
            var toolCallsByIndex: [Int: PartialToolCall] = [:]

            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("data:") else { continue }

                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    break
                }
                guard let payloadData = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                    continue
                }

                if let errorObj = json["error"] as? [String: Any],
                   let errorMessage = errorObj["message"] as? String {
                    let status = (errorObj["code"] as? Int) ?? 500
                    throw LLMError.httpError(provider: .groq, model: modelName, statusCode: status, message: errorMessage)
                }

                guard let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let delta = firstChoice["delta"] as? [String: Any] else {
                    continue
                }

                // NOTE: `delta["reasoning"]` is intentionally ignored so reasoning tokens never reach UI or TTS.
                if let contentDelta = delta["content"] as? String, !contentDelta.isEmpty {
                    let filteredDelta = Self.stripThinkTags(from: contentDelta, insideThinkTag: &insideThinkTag)
                    if !filteredDelta.isEmpty {
                        if !didEmitFirstToken {
                            didEmitFirstToken = true
                            onFirstToken?()
                        }
                        accumulatedText += filteredDelta
                        onTextDelta?(filteredDelta)
                    }
                }

                if let rawToolCalls = delta["tool_calls"] as? [[String: Any]] {
                    for tc in rawToolCalls {
                        if !didEmitFirstToken {
                            didEmitFirstToken = true
                            onFirstToken?()
                        }
                        let index = (tc["index"] as? Int) ?? 0
                        var current = toolCallsByIndex[index] ?? PartialToolCall()
                        if let id = tc["id"] as? String, !id.isEmpty {
                            current.id = id
                        }
                        if let fn = tc["function"] as? [String: Any] {
                            if let nameChunk = fn["name"] as? String, !nameChunk.isEmpty {
                                current.name += nameChunk
                            }
                            if let argsChunk = fn["arguments"] as? String, !argsChunk.isEmpty {
                                current.arguments += argsChunk
                            }
                        }
                        toolCallsByIndex[index] = current
                    }
                }
            }

            let finalizedToolCalls: [LLMToolCall] = toolCallsByIndex.keys.sorted().compactMap { idx in
                guard let partial = toolCallsByIndex[idx], !partial.name.isEmpty else { return nil }
                let callID = partial.id.isEmpty ? "call_\(idx)_\(UUID().uuidString.prefix(8))" : partial.id
                let argsJSON = partial.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "{}"
                    : partial.arguments
                return LLMToolCall(id: callID, name: partial.name, argumentsJSON: argsJSON)
            }

            let cleanedText = Self.stripCompletedThinkBlocks(from: accumulatedText)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return LLMStreamResult(
                text: cleanedText,
                toolCalls: finalizedToolCalls,
                providerName: LLMProvider.groq.rawValue,
                modelName: modelName
            )
        }
    }

    private nonisolated func buildURLRequest(
        apiKey: String,
        modelName: String,
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition]
    ) throws -> URLRequest {
        var openAIMessages: [[String: Any]] = [
            [
                "role": "system",
                "content": systemPrompt
            ]
        ]

        for msg in messages {
            switch msg.role {
            case .system:
                openAIMessages.append([
                    "role": "system",
                    "content": msg.content
                ])
            case .user:
                openAIMessages.append([
                    "role": "user",
                    "content": msg.content
                ])
            case .assistant:
                var assistantDict: [String: Any] = [
                    "role": "assistant"
                ]
                if !msg.content.isEmpty || msg.toolCalls.isEmpty {
                    assistantDict["content"] = msg.content
                }
                if !msg.toolCalls.isEmpty {
                    let tcArray: [[String: Any]] = msg.toolCalls.map { tc in
                        [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.argumentsJSON
                            ]
                        ]
                    }
                    assistantDict["tool_calls"] = tcArray
                }
                openAIMessages.append(assistantDict)
            case .tool:
                openAIMessages.append([
                    "role": "tool",
                    "tool_call_id": msg.toolCallId ?? "call_0",
                    "name": msg.toolName ?? "tool",
                    "content": msg.content
                ])
            }
        }

        var body: [String: Any] = [
            "model": modelName,
            "messages": openAIMessages,
            "temperature": config.temperature,
            "max_completion_tokens": config.maxTokens,
            "stream": true
        ]

        // Groq gpt-oss models are reasoning models: set reasoning_effort to "low" and exclude reasoning from output
        if modelName.lowercased().contains("gpt-oss") {
            body["reasoning_effort"] = "low"
            body["include_reasoning"] = false
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { $0.toOpenAIToolDictionary() }
            body["tool_choice"] = "auto"
        }

        var request = URLRequest(url: Self.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Strips any `<think>...</think>` blocks if a reasoning model emits inline think tags.
    private nonisolated static func stripThinkTags(from chunk: String, insideThinkTag: inout Bool) -> String {
        var remaining = chunk
        var output = ""
        while !remaining.isEmpty {
            if insideThinkTag {
                if let endRange = remaining.range(of: "</think>", options: .caseInsensitive) {
                    insideThinkTag = false
                    remaining = String(remaining[endRange.upperBound...])
                } else {
                    return output
                }
            } else {
                if let startRange = remaining.range(of: "<think>", options: .caseInsensitive) {
                    output += String(remaining[..<startRange.lowerBound])
                    insideThinkTag = true
                    remaining = String(remaining[startRange.upperBound...])
                } else {
                    output += remaining
                    break
                }
            }
        }
        return output
    }

    private nonisolated static func stripCompletedThinkBlocks(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
    }

    /// Preserves the first 200 redacted characters of the provider's actual error body.
    private nonisolated static func errorBodySnippet(_ rawBody: String) -> String {
        LLMError.sanitizeErrorSnippet(rawBody, maxChars: 200)
    }

    /// Parses Groq's `failed_generation` XML-style function call if a model outputs `<function=name>{"arg":...}</function>`.
    private nonisolated static func recoverGroqFailedToolGeneration(from rawBody: String) -> LLMToolCall? {
        guard let data = rawBody.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errorObj = json["error"] as? [String: Any],
              let failedGen = errorObj["failed_generation"] as? String else {
            return nil
        }

        let pattern = #"<function=([a-zA-Z0-9_]+)[>=\s]*(\{.*?\})\s*</function>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: failedGen, range: NSRange(failedGen.startIndex..., in: failedGen)),
              let nameRange = Range(match.range(at: 1), in: failedGen),
              let argsRange = Range(match.range(at: 2), in: failedGen) else {
            return nil
        }

        let fnName = String(failedGen[nameRange])
        let fnArgs = String(failedGen[argsRange])
        return LLMToolCall(
            id: "call_recovered_\(UUID().uuidString.prefix(8))",
            name: fnName,
            argumentsJSON: fnArgs
        )
    }
}

// MARK: - GeminiClient (Google Generative Language API SSE Streaming)

/// Streaming client for Google Gemini (`https://generativelanguage.googleapis.com/v1beta/models/<model>:streamGenerateContent?alt=sse`).
nonisolated public final class GeminiClient: LLMClient, Sendable {
    public let config: LLMConfig
    private let apiKeyProvider: @Sendable () -> String
    private let session: URLSession

    public nonisolated init(
        config: LLMConfig = LLMConfig(),
        apiKeyProvider: @escaping @Sendable () -> String = { Secrets.geminiKey }
    ) {
        self.config = config
        self.apiKeyProvider = apiKeyProvider

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeoutSeconds
        sessionConfig.timeoutIntervalForResource = config.timeoutSeconds
        self.session = URLSession(configuration: sessionConfig)
    }

    public nonisolated func generateResponse(prompt: String, language: VoiceAgentViewModel.Language) async throws -> String {
        let systemPrompt = VaaniSystemPrompt.build(language: language)
        let result = try await streamChat(
            messages: [.user(prompt)],
            systemPrompt: systemPrompt,
            tools: [],
            modelOverride: nil,
            onFirstToken: nil,
            onTextDelta: nil
        )
        return result.text
    }

    public nonisolated func streamChat(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        onFirstToken: (@Sendable () -> Void)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMStreamResult {
        try await streamChat(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            modelOverride: nil,
            onFirstToken: onFirstToken,
            onTextDelta: onTextDelta
        )
    }

    public nonisolated func streamChat(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        modelOverride: String?,
        onFirstToken: (@Sendable () -> Void)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMStreamResult {
        let rawKey = apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            throw LLMError.missingAPIKey(provider: .gemini)
        }

        let modelName = modelOverride ?? config.geminiModel
        let timeoutSec = config.timeoutSeconds

        do {
            return try await performStreamRequest(
                apiKey: rawKey,
                modelName: modelName,
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                includeThinkingConfig: true,
                timeoutSec: timeoutSec,
                onFirstToken: onFirstToken,
                onTextDelta: onTextDelta
            )
        } catch let LLMError.httpError(_, _, statusCode, _) where statusCode == 400 {
            // If Gemini 3.x returns 400 for the thinkingConfig parameter, retry once without thinkingConfig
            print("[GeminiClient] HTTP 400 with thinkingConfig on \(modelName); retrying once without thinkingConfig")
            return try await performStreamRequest(
                apiKey: rawKey,
                modelName: modelName,
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                includeThinkingConfig: false,
                timeoutSec: timeoutSec,
                onFirstToken: onFirstToken,
                onTextDelta: onTextDelta
            )
        }
    }

    private nonisolated func performStreamRequest(
        apiKey: String,
        modelName: String,
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        includeThinkingConfig: Bool,
        timeoutSec: TimeInterval,
        onFirstToken: (@Sendable () -> Void)?,
        onTextDelta: (@Sendable (String) -> Void)?
    ) async throws -> LLMStreamResult {
        let request = try buildURLRequest(
            apiKey: apiKey,
            modelName: modelName,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            includeThinkingConfig: includeThinkingConfig
        )

        return try await withLLMTimeout(provider: .gemini, model: modelName, seconds: timeoutSec) { [session] in
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw LLMError.timeout(provider: .gemini, model: modelName, seconds: timeoutSec)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse(provider: .gemini, model: modelName, details: "Non-HTTP response")
            }

            if !(200...299).contains(httpResponse.statusCode) {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line + "\n"
                    if errorBody.count > 4096 { break }
                }
                let errorSnippet = Self.errorBodySnippet(errorBody)
                throw LLMError.httpError(
                    provider: .gemini,
                    model: modelName,
                    statusCode: httpResponse.statusCode,
                    message: errorSnippet
                )
            }

            var accumulatedText = ""
            var collectedToolCalls: [LLMToolCall] = []
            var didEmitFirstToken = false

            for try await rawLine in bytes.lines {
                try Task.checkCancellation()
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("data:") else { continue }

                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" || payload.isEmpty {
                    continue
                }
                guard let payloadData = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                    continue
                }

                if let errorObj = json["error"] as? [String: Any],
                   let errorMessage = errorObj["message"] as? String {
                    let code = (errorObj["code"] as? Int) ?? 500
                    throw LLMError.httpError(
                        provider: .gemini,
                        model: modelName,
                        statusCode: code,
                        message: LLMError.sanitizeErrorSnippet(errorMessage, maxChars: 200)
                    )
                }

                guard let candidates = json["candidates"] as? [[String: Any]],
                      let firstCandidate = candidates.first,
                      let content = firstCandidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    continue
                }

                for part in parts {
                    // Skip internal thinking parts so thoughts never reach UI or TTS
                    if (part["thought"] as? Bool) == true {
                        continue
                    }

                    if let textDelta = part["text"] as? String, !textDelta.isEmpty {
                        if !didEmitFirstToken {
                            didEmitFirstToken = true
                            onFirstToken?()
                        }
                        accumulatedText += textDelta
                        onTextDelta?(textDelta)
                    }

                    if let fnCall = part["functionCall"] as? [String: Any],
                       let fnName = fnCall["name"] as? String,
                       !fnName.isEmpty {
                        if !didEmitFirstToken {
                            didEmitFirstToken = true
                            onFirstToken?()
                        }
                        let argsDict = (fnCall["args"] as? [String: Any]) ?? [:]
                        let argsData = (try? JSONSerialization.data(withJSONObject: argsDict)) ?? Data("{}".utf8)
                        let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                        let thoughtSig = part["thoughtSignature"] as? String

                        let providerCallID = (fnCall["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let callID = (providerCallID?.isEmpty == false)
                            ? providerCallID!
                            : "gemini_call_\(collectedToolCalls.count)_\(UUID().uuidString.prefix(8))"
                        collectedToolCalls.append(
                            LLMToolCall(
                                id: callID,
                                name: fnName,
                                argumentsJSON: argsJSON,
                                thoughtSignature: thoughtSig
                            )
                        )
                    }
                }
            }

            return LLMStreamResult(
                text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
                toolCalls: collectedToolCalls,
                providerName: LLMProvider.gemini.rawValue,
                modelName: modelName
            )
        }
    }

    private nonisolated func buildURLRequest(
        apiKey: String,
        modelName: String,
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        includeThinkingConfig: Bool
    ) throws -> URLRequest {
        let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelName
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse") else {
            throw LLMError.invalidResponse(provider: .gemini, model: modelName, details: "Invalid Gemini endpoint URL")
        }

        var contents: [[String: Any]] = []
        for msg in messages {
            switch msg.role {
            case .system:
                continue
            case .user:
                contents.append([
                    "role": "user",
                    "parts": [
                        ["text": msg.content]
                    ]
                ])
            case .assistant:
                var parts: [[String: Any]] = []
                if !msg.content.isEmpty {
                    parts.append(["text": msg.content])
                }
                for tc in msg.toolCalls {
                    var fnCallPart: [String: Any] = [
                        "functionCall": [
                            "id": tc.id,
                            "name": tc.name,
                            "args": tc.decodedArguments()
                        ]
                    ]
                    if let sig = tc.thoughtSignature, !sig.isEmpty {
                        fnCallPart["thoughtSignature"] = sig
                    }
                    parts.append(fnCallPart)
                }
                if !parts.isEmpty {
                    contents.append([
                        "role": "model",
                        "parts": parts
                    ])
                }
            case .tool:
                let responseObj: [String: Any]
                if let data = msg.content.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    responseObj = parsed
                } else {
                    responseObj = ["result": msg.content]
                }

                let fnResponsePart: [String: Any] = [
                    "functionResponse": [
                        "id": msg.toolCallId ?? "",
                        "name": msg.toolName ?? "tool",
                        "response": responseObj
                    ]
                ]

                // Merge consecutive tool responses into a single "user" turn if the previous turn was also a functionResponse
                if let lastIndex = contents.indices.last,
                   (contents[lastIndex]["role"] as? String) == "user",
                   let existingParts = contents[lastIndex]["parts"] as? [[String: Any]],
                   existingParts.first?["functionResponse"] != nil {
                    var updatedParts = existingParts
                    updatedParts.append(fnResponsePart)
                    contents[lastIndex]["parts"] = updatedParts
                } else {
                    contents.append([
                        "role": "user",
                        "parts": [fnResponsePart]
                    ])
                }
            }
        }

        var generationConfig: [String: Any] = [
            "temperature": config.temperature,
            "maxOutputTokens": config.maxTokens
        ]
        // Gemini 3.x models always reason: do not send thinkingBudget: 0. Flash-Lite's lowest level is MINIMAL.
        if includeThinkingConfig {
            generationConfig["thinkingConfig"] = [
                "thinkingLevel": "MINIMAL"
            ]
        }

        var body: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": contents,
            "generationConfig": generationConfig
        ]

        if !tools.isEmpty {
            body["tools"] = [
                [
                    "functionDeclarations": tools.map { $0.toGeminiFunctionDeclaration() }
                ]
            ]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Pass key in header so it never appears in URL logs
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Preserves the first 200 redacted characters of the provider's actual error body.
    private nonisolated static func errorBodySnippet(_ rawBody: String) -> String {
        LLMError.sanitizeErrorSnippet(rawBody, maxChars: 200)
    }
}
