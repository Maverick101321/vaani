import Foundation

/// Metrics and metadata returned by a complete `AgentOrchestrator` turn.
nonisolated public struct AgentTurnResult: Sendable, Equatable {
    public let reply: String
    public let firstTokenMs: Double
    public let totalMs: Double
    public let providerName: String
    public let modelName: String
    public let executedToolCalls: [LLMToolCall]

    public init(
        reply: String,
        firstTokenMs: Double,
        totalMs: Double,
        providerName: String,
        modelName: String,
        executedToolCalls: [LLMToolCall] = []
    ) {
        self.reply = reply
        self.firstTokenMs = firstTokenMs
        self.totalMs = totalMs
        self.providerName = providerName
        self.modelName = modelName
        self.executedToolCalls = executedToolCalls
    }
}

/// Actor managing the conversation history (last 6 turns) for `AgentOrchestrator`.
private actor ConversationHistoryStore {
    /// Maximum number of user+assistant conversation turns to retain (`6` turns = up to 12 user/assistant messages).
    private let maxTurns: Int
    private var turns: [(user: String, assistant: String)] = []

    init(maxTurns: Int = 6) {
        self.maxTurns = maxTurns
    }

    func recentMessages() -> [LLMChatMessage] {
        var messages: [LLMChatMessage] = []
        messages.reserveCapacity(turns.count * 2)
        for turn in turns {
            messages.append(.user(turn.user))
            messages.append(.assistant(turn.assistant))
        }
        return messages
    }

    func appendTurn(user: String, assistant: String) {
        guard !user.isEmpty, !assistant.isEmpty else { return }
        turns.append((user: user, assistant: assistant))
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    func clear() {
        turns.removeAll()
    }
}

/// Orchestrates the multi-turn voice agent loop:
/// - Maintains the last 6 conversation turns
/// - Streams from `[Groq, Gemini]` with automatic provider fallback on 404/model-not-found/429/5xx/8s timeout
/// - Executes up to 3 rounds of tool calls via `ToolExecutor`
nonisolated public final class AgentOrchestrator: LLMClient, Sendable {
    public static let maxHistoryTurns: Int = 6
    public static let maxToolRounds: Int = 3

    public let config: LLMConfig
    public let toolExecutor: ToolExecutor
    private let groqClient: GroqClient
    private let geminiClient: GeminiClient
    private let customClientOverride: LLMClient?
    private let historyStore: ConversationHistoryStore

    public nonisolated init(
        config: LLMConfig = LLMConfig(),
        toolExecutor: ToolExecutor = StubToolExecutor(),
        groqClient: GroqClient? = nil,
        geminiClient: GeminiClient? = nil,
        customClientOverride: LLMClient? = nil
    ) {
        self.config = config
        self.toolExecutor = toolExecutor
        self.groqClient = groqClient ?? GroqClient(config: config)
        self.geminiClient = geminiClient ?? GeminiClient(config: config)
        self.customClientOverride = customClientOverride
        self.historyStore = ConversationHistoryStore(maxTurns: Self.maxHistoryTurns)
    }

    /// Clears the in-memory 6-turn conversation history.
    public nonisolated func clearHistory() async {
        await historyStore.clear()
    }

    // MARK: - LLMClient Conformance

    public nonisolated func generateResponse(prompt: String, language: VoiceAgentViewModel.Language) async throws -> String {
        let result = try await runTurn(
            userText: prompt,
            language: language,
            onFirstToken: nil,
            onTextDelta: nil,
            onSentenceReady: nil
        )
        return result.reply
    }

    public nonisolated func streamChat(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        onFirstToken: (@Sendable () -> Void)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil
    ) async throws -> LLMStreamResult {
        try await streamWithProviderFallback(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            onFirstToken: onFirstToken,
            onTextDelta: onTextDelta
        )
    }

    // MARK: - Full Agent Loop (History + Tool Calling + Streaming + Fallback)

    /// Runs a full user turn through the LLM with up to 3 tool-execution rounds and live delta streaming.
    /// - Parameters:
    ///   - userText: Transcribed or typed user message.
    ///   - language: Selected UI language mode (`English` or `Hinglish`).
    ///   - onFirstToken: Called when the first LLM token arrives (records `llmFirstTokenMs`).
    ///   - onTextDelta: Called with each streamed text delta so the UI response card updates live.
    ///   - onSentenceReady: Phase 6 hook called whenever a complete spoken sentence is ready during streaming.
    /// - Returns: `AgentTurnResult` containing the final reply, latency metrics, answering provider, and executed tool calls.
    public nonisolated func runTurn(
        userText: String,
        language: VoiceAgentViewModel.Language,
        onFirstToken: (@Sendable (Double) -> Void)? = nil,
        onTextDelta: (@Sendable (String) -> Void)? = nil,
        onSentenceReady: (@Sendable (String) -> Void)? = nil
    ) async throws -> AgentTurnResult {
        let trimmedInput = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return AgentTurnResult(
                reply: "",
                firstTokenMs: 0,
                totalMs: 0,
                providerName: "None",
                modelName: "none"
            )
        }

        let startClock = ContinuousClock.now
        let systemPrompt = VaaniSystemPrompt.build(language: language)
        let tools = toolExecutor.definitions

        var messages = await historyStore.recentMessages()
        messages.append(.user(trimmedInput))

        let firstTokenState = FirstTokenTracker(startClock: startClock, callback: onFirstToken)
        let sentenceBuffer = SentenceStreamBuffer(callback: onSentenceReady)

        var executedTools: [LLMToolCall] = []
        var finalReply = ""
        var answeringProvider = ""
        var answeringModel = ""

        for round in 0...Self.maxToolRounds {
            try Task.checkCancellation()
            // On the final round after maxToolRounds tool executions, omit tools so the model must synthesize a spoken answer
            let activeTools = (round < Self.maxToolRounds) ? tools : []

            let streamResult = try await streamWithProviderFallback(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: activeTools,
                onFirstToken: {
                    firstTokenState.recordIfNeeded()
                },
                onTextDelta: { delta in
                    firstTokenState.recordIfNeeded()
                    onTextDelta?(delta)
                    sentenceBuffer.append(delta)
                }
            )

            answeringProvider = streamResult.providerName
            answeringModel = streamResult.modelName

            if streamResult.toolCalls.isEmpty || round == Self.maxToolRounds {
                finalReply = Self.sanitizeSpokenReply(streamResult.text)
                break
            }

            // Record assistant tool-call message
            messages.append(.assistant(streamResult.text, toolCalls: streamResult.toolCalls))

            // Execute each requested tool call and append tool results
            for call in streamResult.toolCalls {
                try Task.checkCancellation()
                executedTools.append(call)
                let toolOutputJSON: String
                do {
                    toolOutputJSON = try await toolExecutor.execute(call: call)
                    print("[AgentOrchestrator] Executed tool '\(call.name)' args=\(call.argumentsJSON) -> \(toolOutputJSON)")
                } catch {
                    print("[AgentOrchestrator] Tool '\(call.name)' failed: \(error)")
                    toolOutputJSON = #"{"status":"error","message":"Tool execution failed"}"#
                }
                messages.append(.toolResult(id: call.id, name: call.name, content: toolOutputJSON))
            }
        }

        sentenceBuffer.flushRemaining()

        let totalElapsedMs = Self.milliseconds(since: startClock)
        let firstTokenMs = firstTokenState.firstTokenMs ?? totalElapsedMs
        let toolNames = executedTools.isEmpty ? "none" : executedTools.map(\.name).joined(separator: ",")
        print("[LLM DEBUG] provider=\(answeringProvider.lowercased()) ttfb=\(Int(firstTokenMs.rounded())) total=\(Int(totalElapsedMs.rounded())) tools=\(toolNames)")

        if !finalReply.isEmpty {
            await historyStore.appendTurn(user: trimmedInput, assistant: finalReply)
        }

        return AgentTurnResult(
            reply: finalReply,
            firstTokenMs: firstTokenMs,
            totalMs: totalElapsedMs,
            providerName: answeringProvider,
            modelName: answeringModel,
            executedToolCalls: executedTools
        )
    }

    // MARK: - Provider Fallback Logic

    private nonisolated func streamWithProviderFallback(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        onFirstToken: (@Sendable () -> Void)?,
        onTextDelta: (@Sendable (String) -> Void)?
    ) async throws -> LLMStreamResult {
        if let customClientOverride {
            let result = try await customClientOverride.streamChat(
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                onFirstToken: onFirstToken,
                onTextDelta: onTextDelta
            )
            print("[LLM] Answered by \(result.providerName) (\(result.modelName))")
            return result
        }

        let groqKeyPresent = !Secrets.groqKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let geminiKeyPresent = !Secrets.geminiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !groqKeyPresent && !geminiKeyPresent {
            throw LLMError.missingAllAPIKeys
        }

        var lastError: Error?
        let providers = config.providerOrder.isEmpty ? LLMConfig.defaultProviderOrder : config.providerOrder

        for (index, provider) in providers.enumerated() {
            try Task.checkCancellation()
            let client: LLMClient = (provider == .groq) ? groqClient : geminiClient
            let modelName = config.modelName(for: provider)

            do {
                let result = try await client.streamChat(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: tools,
                    onFirstToken: onFirstToken,
                    onTextDelta: onTextDelta
                )
                print("[LLM] Answered by \(result.providerName) (\(result.modelName))")
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let llmError as LLMError {
                lastError = llmError
                let hasNextProvider = (index + 1) < providers.count
                if hasNextProvider && llmError.shouldFallbackToNextProvider {
                    let nextProvider = providers[index + 1]
                    print("[LLM] \(provider.rawValue) (\(modelName)) failed (\(llmError.localizedDescription)); falling back to \(nextProvider.rawValue) (\(config.modelName(for: nextProvider)))")
                    continue
                }
                throw llmError
            } catch {
                lastError = error
                let hasNextProvider = (index + 1) < providers.count
                if hasNextProvider {
                    let nextProvider = providers[index + 1]
                    print("[LLM] \(provider.rawValue) (\(modelName)) failed (\(error.localizedDescription)); falling back to \(nextProvider.rawValue) (\(config.modelName(for: nextProvider)))")
                    continue
                }
                throw error
            }
        }

        throw lastError ?? LLMError.missingAllAPIKeys
    }

    // MARK: - Helpers

    /// Strips any residual markdown formatting (`*`, `#`, `` ` ``) so TTS speaks clean text.
    nonisolated static func sanitizeSpokenReply(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*[-*•]\s+"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) * 1000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
    }
}

// MARK: - Thread-Safe First-Token & Sentence Streaming Hooks

nonisolated private final class FirstTokenTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let startClock: ContinuousClock.Instant
    private let callback: (@Sendable (Double) -> Void)?
    private var recordedMs: Double?

    init(startClock: ContinuousClock.Instant, callback: (@Sendable (Double) -> Void)?) {
        self.startClock = startClock
        self.callback = callback
    }

    var firstTokenMs: Double? {
        lock.lock()
        defer { lock.unlock() }
        return recordedMs
    }

    func recordIfNeeded() {
        let msToReport: Double?
        lock.lock()
        if recordedMs == nil {
            let elapsed = ContinuousClock.now - startClock
            let (seconds, attoseconds) = elapsed.components
            let ms = Double(seconds) * 1000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
            recordedMs = ms
            msToReport = ms
        } else {
            msToReport = nil
        }
        lock.unlock()

        if let msToReport {
            callback?(msToReport)
        }
    }
}

/// Buffers streamed LLM text deltas and emits complete sentences to `onSentenceReady` (Phase 6 sentence-level TTS streaming hook).
nonisolated private final class SentenceStreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: String = ""
    private let callback: (@Sendable (String) -> Void)?

    init(callback: (@Sendable (String) -> Void)?) {
        self.callback = callback
    }

    func append(_ delta: String) {
        guard let callback else { return }
        var readySentences: [String] = []

        lock.lock()
        buffer += delta
        while let boundaryIndex = Self.firstSentenceBoundary(in: buffer) {
            let sentence = String(buffer[...boundaryIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: boundaryIndex)...])
            if !sentence.isEmpty {
                readySentences.append(sentence)
            }
        }
        lock.unlock()

        for sentence in readySentences {
            callback(AgentOrchestrator.sanitizeSpokenReply(sentence))
        }
    }

    func flushRemaining() {
        guard let callback else { return }
        let remainder: String
        lock.lock()
        remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        lock.unlock()

        if !remainder.isEmpty {
            callback(AgentOrchestrator.sanitizeSpokenReply(remainder))
        }
    }

    private static func firstSentenceBoundary(in text: String) -> String.Index? {
        let terminators: Set<Character> = [".", "!", "?", "।"]
        for idx in text.indices {
            if terminators.contains(text[idx]) {
                let nextIdx = text.index(after: idx)
                if nextIdx == text.endIndex || text[nextIdx].isWhitespace {
                    return idx
                }
            }
        }
        return nil
    }
}
