import Foundation

// MARK: - LLM Configuration (Single Place)

/// Supported cloud LLM providers.
nonisolated public enum LLMProvider: String, CaseIterable, Sendable, Identifiable {
    case groq = "Groq"
    case gemini = "Gemini"

    public var id: String { rawValue }
}

/// Centralized configuration for LLM providers, model names, generation parameters, and fallback timeouts.
nonisolated public struct LLMConfig: Sendable, Equatable {
    /// Editable default Groq model name.
    public static let defaultGroqModel: String = "llama-3.3-70b-versatile"
    /// Editable default Gemini model name.
    public static let defaultGeminiModel: String = "gemini-2.5-flash"
    /// Default provider fallback order: Groq first, then Gemini.
    public static let defaultProviderOrder: [LLMProvider] = [.groq, .gemini]

    public var providerOrder: [LLMProvider]
    public var groqModel: String
    public var geminiModel: String
    public var temperature: Double
    public var maxTokens: Int
    public var timeoutSeconds: TimeInterval

    public init(
        providerOrder: [LLMProvider] = LLMConfig.defaultProviderOrder,
        groqModel: String = LLMConfig.defaultGroqModel,
        geminiModel: String = LLMConfig.defaultGeminiModel,
        temperature: Double = 0.3,
        maxTokens: Int = 150,
        timeoutSeconds: TimeInterval = 8.0
    ) {
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

/// Structured errors for LLM requests and provider fallback decisions.
nonisolated public enum LLMError: LocalizedError, Sendable, Equatable {
    case missingAPIKey(provider: LLMProvider)
    case missingAllAPIKeys
    case timeout(provider: LLMProvider, seconds: TimeInterval)
    case httpError(provider: LLMProvider, statusCode: Int, message: String)
    case invalidResponse(provider: LLMProvider, details: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            let keyName = (provider == .groq) ? "Secrets.groqKey" : "Secrets.geminiKey"
            return "\(provider.rawValue) API key is empty. Please set `\(keyName)` in Vaani/Secrets.swift."
        case .missingAllAPIKeys:
            return "API keys are missing in Vaani/Secrets.swift. Please add your `Secrets.groqKey` and/or `Secrets.geminiKey` (see Secrets.example.swift)."
        case .timeout(let provider, let seconds):
            return "\(provider.rawValue) request timed out after \(Int(seconds))s."
        case .httpError(let provider, let statusCode, let message):
            let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanMessage.isEmpty {
                return "\(provider.rawValue) HTTP \(statusCode) error."
            }
            return "\(provider.rawValue) HTTP \(statusCode): \(cleanMessage)"
        case .invalidResponse(let provider, let details):
            return "\(provider.rawValue) invalid response: \(details)"
        }
    }

    /// Determines whether `AgentOrchestrator` should automatically fall back to the next provider in `LLMConfig.providerOrder`.
    /// Falls back on: 404 / model-not-found, 429 (rate limit), 5xx (server error), 8s timeout, or missing single provider key.
    public var shouldFallbackToNextProvider: Bool {
        switch self {
        case .missingAPIKey:
            return true
        case .missingAllAPIKeys:
            return false
        case .timeout:
            return true
        case .httpError(_, let statusCode, let message):
            if statusCode == 404 || statusCode == 429 || (500...599).contains(statusCode) {
                return true
            }
            let lower = message.lowercased()
            if lower.contains("model_not_found")
                || lower.contains("model not found")
                || lower.contains("does not exist")
                || lower.contains("not found")
                || lower.contains("rate limit")
                || lower.contains("quota")
                || lower.contains("overloaded") {
                return true
            }
            return false
        case .invalidResponse:
            return true
        }
    }
}

// MARK: - Timeout Helper

/// Runs an async operation with a strict timeout in seconds, throwing `LLMError.timeout` if exceeded.
nonisolated func withLLMTimeout<T: Sendable>(
    provider: LLMProvider,
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw LLMError.timeout(provider: provider, seconds: seconds)
        }
        guard let first = try await group.next() else {
            throw LLMError.timeout(provider: provider, seconds: seconds)
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
        let rawKey = apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            throw LLMError.missingAPIKey(provider: .groq)
        }

        let modelName = config.groqModel
        let timeoutSec = config.timeoutSeconds
        let request = try buildURLRequest(
            apiKey: rawKey,
            modelName: modelName,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools
        )

        return try await withLLMTimeout(provider: .groq, seconds: timeoutSec) { [session] in
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw LLMError.timeout(provider: .groq, seconds: timeoutSec)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse(provider: .groq, details: "Non-HTTP response")
            }

            if !(200...299).contains(httpResponse.statusCode) {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line + "\n"
                    if errorBody.count > 4096 { break }
                }

                // Handle Groq Llama 3.3 occasional `<function=name>{...}</function>` tool_use_failed 400 error
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

                let parsedMsg = Self.extractErrorMessage(from: errorBody)
                throw LLMError.httpError(
                    provider: .groq,
                    statusCode: httpResponse.statusCode,
                    message: parsedMsg
                )
            }

            var accumulatedText = ""
            var didEmitFirstToken = false

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
                    throw LLMError.httpError(provider: .groq, statusCode: 500, message: errorMessage)
                }

                guard let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let delta = firstChoice["delta"] as? [String: Any] else {
                    continue
                }

                if let contentDelta = delta["content"] as? String, !contentDelta.isEmpty {
                    if !didEmitFirstToken {
                        didEmitFirstToken = true
                        onFirstToken?()
                    }
                    accumulatedText += contentDelta
                    onTextDelta?(contentDelta)
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

            return LLMStreamResult(
                text: accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines),
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
            "max_tokens": config.maxTokens,
            "stream": true
        ]

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

    private nonisolated static func extractErrorMessage(from rawBody: String) -> String {
        if let data = rawBody.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return message
        }
        return String(rawBody.prefix(240))
    }

    /// Parses Groq's `failed_generation` XML-style function call if Llama-3.3 outputs `<function=name>{"arg":...}</function>`.
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
        let rawKey = apiKeyProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawKey.isEmpty else {
            throw LLMError.missingAPIKey(provider: .gemini)
        }

        let modelName = config.geminiModel
        let timeoutSec = config.timeoutSeconds
        let request = try buildURLRequest(
            apiKey: rawKey,
            modelName: modelName,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools
        )

        return try await withLLMTimeout(provider: .gemini, seconds: timeoutSec) { [session] in
            let (bytes, response): (URLSession.AsyncBytes, URLResponse)
            do {
                (bytes, response) = try await session.bytes(for: request)
            } catch let urlError as URLError where urlError.code == .timedOut {
                throw LLMError.timeout(provider: .gemini, seconds: timeoutSec)
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw LLMError.invalidResponse(provider: .gemini, details: "Non-HTTP response")
            }

            if !(200...299).contains(httpResponse.statusCode) {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line + "\n"
                    if errorBody.count > 4096 { break }
                }
                let parsedMsg = Self.extractErrorMessage(from: errorBody)
                throw LLMError.httpError(
                    provider: .gemini,
                    statusCode: httpResponse.statusCode,
                    message: parsedMsg
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
                    throw LLMError.httpError(provider: .gemini, statusCode: code, message: errorMessage)
                }

                guard let candidates = json["candidates"] as? [[String: Any]],
                      let firstCandidate = candidates.first,
                      let content = firstCandidate["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    continue
                }

                for part in parts {
                    // Skip internal thinking parts if any are emitted
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

                        collectedToolCalls.append(
                            LLMToolCall(
                                id: "gemini_call_\(collectedToolCalls.count)_\(UUID().uuidString.prefix(8))",
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
        tools: [LLMToolDefinition]
    ) throws -> URLRequest {
        let encodedModel = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelName
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):streamGenerateContent?alt=sse") else {
            throw LLMError.invalidResponse(provider: .gemini, details: "Invalid Gemini endpoint URL")
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
        // Disable thinking budget on Gemini 2.5 Flash for ultra-low voice assistant TTFT and to preserve maxOutputTokens
        if modelName.lowercased().contains("2.5") {
            generationConfig["thinkingConfig"] = [
                "thinkingBudget": 0
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

    private nonisolated static func extractErrorMessage(from rawBody: String) -> String {
        if let data = rawBody.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObj = json["error"] as? [String: Any],
           let message = errorObj["message"] as? String {
            return message
        }
        return String(rawBody.prefix(240))
    }
}
