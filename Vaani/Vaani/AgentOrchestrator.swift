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

/// Thread-safe tracker that remembers the first working fallback chain entry index for the current session.
nonisolated private final class SessionChainTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var workingIndex: Int?
    private var didRunSelfTest: Bool = false

    func preferredStartIndex(chainCount: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = workingIndex, idx >= 0, idx < chainCount else {
            return 0
        }
        return idx
    }

    func recordFirstWorkingIndex(_ index: Int) {
        lock.lock()
        if workingIndex == nil {
            workingIndex = index
        }
        lock.unlock()
    }

    func markSelfTestStartedIfNeeded() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didRunSelfTest {
            return false
        }
        didRunSelfTest = true
        return true
    }
}

/// Orchestrates the multi-turn voice agent loop:
/// - Maintains the last 6 conversation turns
/// - Streams across the ordered fallback chain (`openai/gpt-oss-120b` -> `openai/gpt-oss-20b` -> `gemini-3.5-flash-lite` -> `gemini-3.1-flash-lite`),
///   advancing on 404/400/401/403/429/5xx/timeout and remembering the first working entry for the session
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
    private let sessionTracker = SessionChainTracker()

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

    #if DEBUG
    /// Sends `"ping"` through each entry in `config.chain` at startup (DEBUG builds only) and logs status, ttfb, and total ms.
    public nonisolated func runStartupSelfTestIfNeeded() {
        guard customClientOverride == nil else { return }
        guard sessionTracker.markSelfTestStartedIfNeeded() else { return }

        let chain = config.chain.isEmpty ? LLMConfig.defaultChain : config.chain
        let groqClient = self.groqClient
        let geminiClient = self.geminiClient

        Task.detached(priority: .utility) {
            var firstWorkingIdx: Int?
            for (idx, entry) in chain.enumerated() {
                let start = ContinuousClock.now
                let ttfbTracker = FirstTokenTracker(startClock: start, callback: nil)
                do {
                    let result: LLMStreamResult
                    switch entry.provider {
                    case .groq:
                        result = try await groqClient.streamChat(
                            messages: [.user("ping")],
                            systemPrompt: "Reply with a single word: pong.",
                            tools: [],
                            modelOverride: entry.model,
                            onFirstToken: {
                                ttfbTracker.recordIfNeeded()
                            },
                            onTextDelta: { _ in
                                ttfbTracker.recordIfNeeded()
                            }
                        )
                    case .gemini:
                        result = try await geminiClient.streamChat(
                            messages: [.user("ping")],
                            systemPrompt: "Reply with a single word: pong.",
                            tools: [],
                            modelOverride: entry.model,
                            onFirstToken: {
                                ttfbTracker.recordIfNeeded()
                            },
                            onTextDelta: { _ in
                                ttfbTracker.recordIfNeeded()
                            }
                        )
                    }
                    let totalMs = Self.milliseconds(since: start)
                    let ttfbMs = ttfbTracker.firstTokenMs ?? totalMs
                    if firstWorkingIdx == nil {
                        firstWorkingIdx = idx
                    }
                    let cleanReply = LLMError.sanitizeErrorSnippet(result.text, maxChars: 60)
                    print("[LLM SELF-TEST] provider=\(entry.provider.rawValue.lowercased()) model=\(entry.model) status=OK ttfb=\(Int(ttfbMs.rounded()))ms total=\(Int(totalMs.rounded()))ms reply=\"\(cleanReply)\"")
                } catch {
                    let totalMs = Self.milliseconds(since: start)
                    let errDesc = LLMError.sanitizeErrorSnippet(error.localizedDescription, maxChars: 240)
                    print("[LLM SELF-TEST] provider=\(entry.provider.rawValue.lowercased()) model=\(entry.model) status=FAIL(\(errDesc)) ttfb=- total=\(Int(totalMs.rounded()))ms")
                }
            }
            if let firstWorkingIdx {
                self.sessionTracker.recordFirstWorkingIndex(firstWorkingIdx)
            }
        }
    }
    #endif

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
        var fallbackErrors: [String] = []
        return try await streamWithProviderFallback(
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            encounteredErrors: &fallbackErrors,
            onFirstToken: onFirstToken,
            onTextDelta: onTextDelta
        )
    }

    // MARK: - Full Agent Loop (History + Tool Calling + Streaming + Fallback)

    /// Runs a full user turn through the LLM with up to 3 tool-execution rounds and live delta streaming.
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
        var encounteredErrors: [String] = []
        var finalReply = ""
        var answeringProvider = ""
        var answeringModel = ""

        do {
            for round in 0...Self.maxToolRounds {
                try Task.checkCancellation()
                // On the final round after maxToolRounds tool executions, omit tools so the model must synthesize a spoken answer
                let activeTools = (round < Self.maxToolRounds) ? tools : []

                let streamResult = try await streamWithProviderFallback(
                    messages: messages,
                    systemPrompt: systemPrompt,
                    tools: activeTools,
                    encounteredErrors: &encounteredErrors,
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
        } catch {
            let totalElapsedMs = Self.milliseconds(since: startClock)
            let toolNames = executedTools.isEmpty ? "none" : executedTools.map(\.name).joined(separator: ",")
            let errorSummary = encounteredErrors.isEmpty
                ? LLMError.sanitizeErrorSnippet(error.localizedDescription, maxChars: 400)
                : encounteredErrors.joined(separator: " | ")
            print("[LLM DEBUG] provider=none model=none ttfb=- total=\(Int(totalElapsedMs.rounded())) tools=\(toolNames) errors=\(errorSummary)")
            throw error
        }

        sentenceBuffer.flushRemaining()

        let totalElapsedMs = Self.milliseconds(since: startClock)
        let firstTokenMs = firstTokenState.firstTokenMs ?? totalElapsedMs
        let toolNames = executedTools.isEmpty ? "none" : executedTools.map(\.name).joined(separator: ",")
        if encounteredErrors.isEmpty {
            print("[LLM DEBUG] provider=\(answeringProvider.lowercased()) model=\(answeringModel) ttfb=\(Int(firstTokenMs.rounded())) total=\(Int(totalElapsedMs.rounded())) tools=\(toolNames)")
        } else {
            print("[LLM DEBUG] provider=\(answeringProvider.lowercased()) model=\(answeringModel) ttfb=\(Int(firstTokenMs.rounded())) total=\(Int(totalElapsedMs.rounded())) tools=\(toolNames) fallback_errors=\(encounteredErrors.joined(separator: " | "))")
        }

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

    // MARK: - Ordered Cross-Provider Fallback Chain

    private nonisolated func streamWithProviderFallback(
        messages: [LLMChatMessage],
        systemPrompt: String,
        tools: [LLMToolDefinition],
        encounteredErrors: inout [String],
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

        let chain = config.chain.isEmpty ? LLMConfig.defaultChain : config.chain
        let startIdx = sessionTracker.preferredStartIndex(chainCount: chain.count)

        // Order indices starting from the session's remembered working entry, then wrapping to any remaining entries if needed
        var orderedIndices: [Int] = Array(startIdx..<chain.count)
        if startIdx > 0 {
            orderedIndices.append(contentsOf: 0..<startIdx)
        }

        var groqErrors: [String] = []
        var geminiErrors: [String] = []
        var allEntryErrors: [String] = []

        for (attemptOffset, chainIdx) in orderedIndices.enumerated() {
            try Task.checkCancellation()
            let entry = chain[chainIdx]

            // If we already recorded a missing/invalid key for this provider on an earlier model in this turn, skip straight to the next provider
            if entry.provider == .groq,
               groqErrors.contains(where: { $0.contains("Groq key missing") || $0.contains("Groq key invalid") }) {
                continue
            }
            if entry.provider == .gemini,
               geminiErrors.contains(where: { $0.contains("Gemini key missing") || $0.contains("Gemini key invalid") }) {
                continue
            }

            do {
                let result: LLMStreamResult
                switch entry.provider {
                case .groq:
                    result = try await groqClient.streamChat(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        modelOverride: entry.model,
                        onFirstToken: onFirstToken,
                        onTextDelta: onTextDelta
                    )
                case .gemini:
                    result = try await geminiClient.streamChat(
                        messages: messages,
                        systemPrompt: systemPrompt,
                        tools: tools,
                        modelOverride: entry.model,
                        onFirstToken: onFirstToken,
                        onTextDelta: onTextDelta
                    )
                }

                sessionTracker.recordFirstWorkingIndex(chainIdx)
                print("[LLM] Answered by \(result.providerName) (\(result.modelName))")
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch let llmError as LLMError {
                let formatted = llmError.localizedDescription
                allEntryErrors.append(formatted)
                encounteredErrors.append(formatted)
                switch entry.provider {
                case .groq:
                    groqErrors.append(formatted)
                case .gemini:
                    geminiErrors.append(formatted)
                }

                let hasNextEntry = (attemptOffset + 1) < orderedIndices.count
                if hasNextEntry && llmError.shouldFallbackToNextProvider {
                    let nextEntry = chain[orderedIndices[attemptOffset + 1]]
                    print("[LLM] \(entry.provider.rawValue) (\(entry.model)) failed (\(formatted)); advancing fallback chain to \(nextEntry.provider.rawValue) (\(nextEntry.model))")
                    continue
                }
                break
            } catch {
                let formatted = "\(entry.provider.rawValue) (\(entry.model)): \(LLMError.sanitizeErrorSnippet(error.localizedDescription, maxChars: 200))"
                allEntryErrors.append(formatted)
                encounteredErrors.append(formatted)
                switch entry.provider {
                case .groq:
                    groqErrors.append(formatted)
                case .gemini:
                    geminiErrors.append(formatted)
                }

                let hasNextEntry = (attemptOffset + 1) < orderedIndices.count
                if hasNextEntry {
                    let nextEntry = chain[orderedIndices[attemptOffset + 1]]
                    print("[LLM] \(entry.provider.rawValue) (\(entry.model)) failed (\(formatted)); advancing fallback chain to \(nextEntry.provider.rawValue) (\(nextEntry.model))")
                    continue
                }
                break
            }
        }

        let groqSummary = groqErrors.isEmpty ? nil : groqErrors.joined(separator: "; ")
        let geminiSummary = geminiErrors.isEmpty ? nil : geminiErrors.joined(separator: "; ")
        throw LLMError.chainFailed(
            groqError: groqSummary,
            geminiError: geminiSummary,
            details: allEntryErrors
        )
    }

    // MARK: - Helpers

    /// Strips any residual markdown formatting (`*`, `#`, `` ` ``) and `<think>` blocks so TTS speaks clean text.
    nonisolated static func sanitizeSpokenReply(_ raw: String) -> String {
        var cleaned = raw.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned
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
