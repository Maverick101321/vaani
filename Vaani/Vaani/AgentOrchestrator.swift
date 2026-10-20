import Foundation

/// Metrics and metadata returned by a complete `AgentOrchestrator` turn.
nonisolated public struct AgentTurnResult: Sendable, Equatable {
    public let reply: String
    public let firstTokenMs: Double
    public let totalMs: Double
    public let providerName: String
    public let modelName: String
    public let executedToolCalls: [LLMToolCall]
    public let executedToolOutputs: [String]

    public init(
        reply: String,
        firstTokenMs: Double,
        totalMs: Double,
        providerName: String,
        modelName: String,
        executedToolCalls: [LLMToolCall] = [],
        executedToolOutputs: [String] = []
    ) {
        self.reply = reply
        self.firstTokenMs = firstTokenMs
        self.totalMs = totalMs
        self.providerName = providerName
        self.modelName = modelName
        self.executedToolCalls = executedToolCalls
        self.executedToolOutputs = executedToolOutputs
    }
}

/// Actor managing the conversation history (last 6 turns) for `AgentOrchestrator`.
private actor ConversationHistoryStore {
    /// Maximum number of user+assistant conversation turns to retain (`6` turns = up to 12 user/assistant messages).
    private let maxTurns: Int
    private var turns: [(user: String, assistant: String)] = []
    private var lastLanguage: VoiceAgentViewModel.Language?

    init(maxTurns: Int = 6) {
        self.maxTurns = maxTurns
    }

    func recentMessages(for language: VoiceAgentViewModel.Language) -> [LLMChatMessage] {
        if let lastLanguage, lastLanguage != language {
            turns.removeAll()
        }
        lastLanguage = language
        var messages: [LLMChatMessage] = []
        messages.reserveCapacity(turns.count * 2)
        for turn in turns {
            messages.append(.user(turn.user))
            messages.append(.assistant(turn.assistant))
        }
        return messages
    }

    func appendTurn(user: String, assistant: String, language: VoiceAgentViewModel.Language) {
        if let lastLanguage, lastLanguage != language {
            turns.removeAll()
        }
        lastLanguage = language
        guard !user.isEmpty, !assistant.isEmpty else { return }
        turns.append((user: user, assistant: assistant))
        if turns.count > maxTurns {
            turns.removeFirst(turns.count - maxTurns)
        }
    }

    func clear() {
        turns.removeAll()
        lastLanguage = nil
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
        toolExecutor: ToolExecutor = VaaniToolExecutor(),
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

    /// Resets the conversation history (alias for `clearHistory()`).
    public nonisolated func reset() async {
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

        let transcriptPreview = String(trimmedInput.prefix(60)).replacingOccurrences(of: "\n", with: " ")
        print("[LANG] mode=\(language.rawValue) transcript=\(transcriptPreview)")

        let startClock = ContinuousClock.now
        let systemPrompt = VaaniSystemPrompt.build(language: language)
        let tools = toolExecutor.definitions

        let priorHistory = await historyStore.recentMessages(for: language)
        var messages = priorHistory
        messages.append(.user(trimmedInput))

        let firstTokenState = FirstTokenTracker(startClock: startClock, callback: onFirstToken)
        let sentenceBuffer = SentenceStreamBuffer(language: language, callback: onSentenceReady)
        let holdRoundZeroForToolCheck = Self.likelyRequiresTool(trimmedInput)

        var executedTools: [LLMToolCall] = []
        var executedToolOutputs: [String] = []
        var encounteredErrors: [String] = []
        var finalReply = ""
        var answeringProvider = ""
        var answeringModel = ""

        do {
            for round in 0...Self.maxToolRounds {
                try Task.checkCancellation()
                // Tool calls happen in round 0; once tools have executed, round 1+ synthesizes the spoken reply without resending tool schemas
                let activeTools = (round == 0 && round < Self.maxToolRounds) ? tools : []
                let isPostToolFinalRound = (round > 0)
                let roundStartClock = ContinuousClock.now
                let roundZeroBuffer = LockedTextBuffer()

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
                        let cleanDelta = Self.stripDevanagari(delta)
                        guard !cleanDelta.isEmpty else { return }
                        if isPostToolFinalRound || !holdRoundZeroForToolCheck {
                            onTextDelta?(cleanDelta)
                            sentenceBuffer.append(cleanDelta)
                        } else {
                            roundZeroBuffer.append(cleanDelta)
                        }
                    }
                )

                let roundElapsedMs = Self.milliseconds(since: roundStartClock)
                answeringProvider = streamResult.providerName
                answeringModel = streamResult.modelName

                if streamResult.toolCalls.isEmpty || round == Self.maxToolRounds {
                    let bufferedRoundZeroText = roundZeroBuffer.value
                    if !isPostToolFinalRound && holdRoundZeroForToolCheck && !bufferedRoundZeroText.isEmpty {
                        onTextDelta?(bufferedRoundZeroText)
                        sentenceBuffer.append(bufferedRoundZeroText)
                    }
                    finalReply = Self.sanitizeSpokenReply(streamResult.text)
                    break
                }

                // Tool-calling turn: discard any intermediate round-0 text so TTS speaks ONLY the final answer
                sentenceBuffer.resetUncommitted()

                (toolExecutor as? VaaniToolExecutor)?.currentTurnTranscriptHint = trimmedInput

                let toolExecStart = ContinuousClock.now
                var toolResultMessages: [LLMChatMessage] = []
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
                    executedToolOutputs.append(toolOutputJSON)
                    toolResultMessages.append(.toolResult(id: call.id, name: call.name, content: toolOutputJSON))
                }
                let toolExecMs = Self.milliseconds(since: toolExecStart)

                // Requirement 3 (Fast path for tool replies): for set_alarm, set_reminder, get_next_meeting,
                // get_schedule, and get_weather results with success status, build the spoken reply deterministically
                // from the tool result using templates in the active language and skip the second LLM request.
                if let fastReply = Self.fastPathToolReply(
                    executedTools: executedTools,
                    executedToolOutputs: executedToolOutputs,
                    userText: trimmedInput,
                    language: language,
                    turnSeed: priorHistory.count / 2,
                    now: Date()
                ) {
                    finalReply = Self.sanitizeSpokenReply(fastReply)
                    firstTokenState.recordIfNeeded()
                    onTextDelta?(finalReply)
                    sentenceBuffer.append(finalReply)
                    let toolNamesJoined = executedTools.map(\.name).joined(separator: ",")
                    let savedMs = Int(max(650.0, roundElapsedMs).rounded())
                    print("[FASTPATH] tool=\(toolNamesJoined) saved_ms=\(savedMs)")
                    break
                }

                // Fallback LLM path for errors or ambiguous tool results: send the second LLM request with a trimmed history
                // (system prompt + the user message + the tool call and result only).
                let trimmedHistoryMsgs = priorHistory.count
                let trimmedHistoryChars = priorHistory.reduce(0) { $0 + $1.content.count }
                messages = [
                    .user(trimmedInput),
                    .assistant("", toolCalls: streamResult.toolCalls)
                ] + toolResultMessages
                print("[TOOL SPEEDUP] round0_ms=\(Int(roundElapsedMs.rounded())) tool_ms=\(Int(toolExecMs.rounded())) trimmed_msgs=\(trimmedHistoryMsgs) trimmed_chars=\(trimmedHistoryChars)")
            }

            // Deterministic fallback: if a tool succeeded and the final reply is under 3 words or empty,
            // OR if set_alarm returned already_exists and the reply did not mention "already", generate from tool result.
            let isDuplicateAlarmMissingKeyword: Bool = {
                guard executedTools.last?.name == "set_alarm",
                      let lastOutput = executedToolOutputs.last,
                      lastOutput.contains("already_exists") else {
                    return false
                }
                let lower = finalReply.lowercased()
                return !lower.contains("already") && !lower.contains("pehle")
            }()

            if (!executedTools.isEmpty && Self.wordCount(of: finalReply) < 3) || isDuplicateAlarmMissingKeyword {
                if let fallback = Self.deterministicToolFallbackReply(
                    executedTools: executedTools,
                    executedToolOutputs: executedToolOutputs,
                    language: language
                ) {
                    finalReply = fallback
                    print("[REPLY FALLBACK] tool=\(executedTools.last?.name ?? "unknown") reply=\"\(finalReply)\"")
                }
            }

            // Deterministic guard: in English mode, if the reply still contains common Hinglish markers, re-ask once
            if language == .english && !finalReply.isEmpty && Self.containsHinglishMarkers(finalReply) {
                print("[LANG GUARD] rewrite triggered")
                let rewriteResult = try await streamWithProviderFallback(
                    messages: [.user(finalReply)],
                    systemPrompt: "Rewrite in plain English only. Keep under 25 words, no Hindi words, no Devanagari, and speak temperatures as '24 degrees'.",
                    tools: [],
                    encounteredErrors: &encounteredErrors,
                    onFirstToken: nil,
                    onTextDelta: nil
                )
                let rewritten = Self.sanitizeSpokenReply(rewriteResult.text)
                if !rewritten.isEmpty {
                    finalReply = rewritten
                    answeringProvider = rewriteResult.providerName
                    answeringModel = rewriteResult.modelName
                }
            }
        } catch {
            // If a tool already succeeded in an earlier round before the follow-up LLM call failed, use deterministic fallback
            if !executedTools.isEmpty,
               let fallback = Self.deterministicToolFallbackReply(
                   executedTools: executedTools,
                   executedToolOutputs: executedToolOutputs,
                   language: language
               ) {
                finalReply = fallback
                print("[REPLY FALLBACK] tool=\(executedTools.last?.name ?? "unknown") reply=\"\(finalReply)\" (recovered after follow-up error)")
            } else {
                let totalElapsedMs = Self.milliseconds(since: startClock)
                let toolNames = executedTools.isEmpty ? "none" : executedTools.map(\.name).joined(separator: ",")
                let errorSummary = encounteredErrors.isEmpty
                    ? LLMError.sanitizeErrorSnippet(error.localizedDescription, maxChars: 400)
                    : encounteredErrors.joined(separator: " | ")
                print("[LLM DEBUG] provider=none model=none ttfb=- total=\(Int(totalElapsedMs.rounded())) tools=\(toolNames) errors=\(errorSummary)")
                throw error
            }
        }

        if sentenceBuffer.emittedCount == 0 && !finalReply.isEmpty {
            sentenceBuffer.replaceBuffer(with: finalReply)
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
            await historyStore.appendTurn(user: trimmedInput, assistant: finalReply, language: language)
        }

        return AgentTurnResult(
            reply: finalReply,
            firstTokenMs: firstTokenMs,
            totalMs: totalElapsedMs,
            providerName: answeringProvider,
            modelName: answeringModel,
            executedToolCalls: executedTools,
            executedToolOutputs: executedToolOutputs
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

    /// Strips any Devanagari characters (`U+0900`–`U+097F`) from the given string.
    nonisolated static func stripDevanagari(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            if !(0x0900...0x097F).contains(scalar.value) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Returns `true` if the text contains common Hinglish markers (`hai`, `hain`, `kal`, `aaj`, `baje`, `subah`, `shaam`, `mein`, `ka`, `ke`, `ki`, `ho gaya`, `kar diya`, `karna`) as whole words.
    nonisolated static func containsHinglishMarkers(_ text: String) -> Bool {
        let pattern = #"(?i)\b(hai|hain|kal|aaj|baje|subah|shaam|mein|ka|ke|ki|ho\s+gaya|kar\s+diya|karna)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Strips any residual markdown formatting (`*`, `#`, `` ` ``), `<think>` blocks, Devanagari script (`U+0900`–`U+097F`), and degree symbols (`°C` -> `degrees`) so TTS speaks clean text.
    nonisolated static func sanitizeSpokenReply(_ raw: String) -> String {
        var cleaned = raw.replacingOccurrences(
            of: #"(?is)<think>.*?</think>"#,
            with: "",
            options: .regularExpression
        )
        cleaned = stripDevanagari(cleaned)
        cleaned = cleaned.replacingOccurrences(
            of: #"(?i)\s*°\s*[cf]\b"#,
            with: " degrees",
            options: .regularExpression
        )
        cleaned = cleaned
            .replacingOccurrences(of: "℃", with: " degrees")
            .replacingOccurrences(of: "℉", with: " degrees")
            .replacingOccurrences(of: "°", with: " degrees ")
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

    private nonisolated static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Returns `true` when the user prompt likely triggers one of Vaani's 5 tools, so round 0 buffers text until we know whether `tool_calls` were emitted.
    private nonisolated static func likelyRequiresTool(_ text: String) -> Bool {
        let pattern = #"(?i)\b(weather|temperature|temp|forecast|rain|mausam|baarish|barish|tapman|garmi|thandi|alarm|wake|utha|jagana|baje|remind|reminder|yaad|schedule|meeting|meetings|calendar|events|appointment|standup|sync)\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    /// Builds the spoken reply deterministically from successful tool results (`set_alarm`, `set_reminder`, `get_next_meeting`,
    /// `get_schedule`, `get_weather`) using 2–3 natural templates per tool in the active language so we can skip the second LLM round.
    /// Returns `nil` when any tool returned an error payload so the LLM fallback handles it.
    public nonisolated static func fastPathToolReply(
        executedTools: [LLMToolCall],
        executedToolOutputs: [String],
        userText: String = "",
        language: VoiceAgentViewModel.Language,
        turnSeed: Int = 0,
        now: Date = Date()
    ) -> String? {
        guard !executedTools.isEmpty,
              executedTools.count == executedToolOutputs.count else {
            return nil
        }

        var parsedPayloads: [(name: String, json: [String: Any])] = []
        for (call, output) in zip(executedTools, executedToolOutputs) {
            guard let data = output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil,
                  (json["status"] as? String) != "error" else {
                return nil
            }
            parsedPayloads.append((call.name, json))
        }

        // Combined schedule + next_meeting turn (e.g. "Aaj ka schedule kya hai, aur meri next meeting kab hai?")
        if parsedPayloads.count == 2 {
            let names = Set(parsedPayloads.map(\.name))
            if names == Set(["get_schedule", "get_next_meeting"]),
               let scheduleJSON = parsedPayloads.first(where: { $0.name == "get_schedule" })?.json,
               let nextJSON = parsedPayloads.first(where: { $0.name == "get_next_meeting" })?.json {
                return formatCombinedScheduleAndNextMeeting(
                    scheduleJSON: scheduleJSON,
                    nextJSON: nextJSON,
                    language: language,
                    turnSeed: turnSeed,
                    now: now
                )
            }
        }

        // Single-tool fast path (or last tool if multiple calls)
        guard let last = parsedPayloads.last else { return nil }
        let json = last.json
        let seed = abs(turnSeed + userText.count)

        switch last.name {
        case "set_alarm":
            let status = (json["status"] as? String) ?? ""
            let iso = json["time_iso"] as? String
            let spoken = (json["time_spoken"] as? String) ?? ""
            if status == "already_exists" {
                switch language {
                case .hinglish:
                    let phrase = friendlyHinglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                    let sentenceInitialPhrase = phrase.prefix(1).uppercased() + phrase.dropFirst()
                    let templates = [
                        "Alarm already set for \(phrase).",
                        "\(sentenceInitialPhrase) ka alarm pehle se already set hai.",
                        "Aapka alarm \(phrase) ke liye already set hai."
                    ]
                    return templates[seed % templates.count]
                case .english:
                    let phrase = friendlyEnglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                    let templates = [
                        "That alarm is already set for \(phrase).",
                        "You already have an alarm set for \(phrase).",
                        "An alarm for \(phrase) is already active."
                    ]
                    return templates[seed % templates.count]
                }
            }
            switch language {
            case .hinglish:
                let phrase = friendlyHinglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                let templates = [
                    "Alarm \(phrase) ke liye set ho gaya.",
                    "Aapka alarm \(phrase) ke liye set kar diya hai.",
                    "Done, \(phrase) ka alarm set ho gaya hai."
                ]
                return templates[seed % templates.count]
            case .english:
                let phrase = friendlyEnglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                let templates = [
                    "Alarm set for \(phrase).",
                    "Your alarm is set for \(phrase).",
                    "Done, I have set an alarm for \(phrase)."
                ]
                return templates[seed % templates.count]
            }

        case "set_reminder":
            let title = (json["title"] as? String) ?? "Reminder"
            let iso = (json["datetime_iso"] as? String) ?? (json["due_iso"] as? String)
            let spoken = (json["datetime_spoken"] as? String) ?? (json["due_spoken"] as? String)
            switch language {
            case .hinglish:
                if let spoken, !spoken.isEmpty {
                    let phrase = friendlyHinglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                    let templates = [
                        "Reminder \(title) \(phrase) ke liye set ho gaya.",
                        "Aapka \(title) reminder \(phrase) ke liye set kar diya hai.",
                        "Done, \(phrase) ke liye \(title) ka reminder set ho gaya."
                    ]
                    return templates[seed % templates.count]
                }
                return "Reminder \(title) set ho gaya."
            case .english:
                if let spoken, !spoken.isEmpty {
                    let phrase = friendlyEnglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                    let templates = [
                        "Reminder for \(title) set for \(phrase).",
                        "I have set your \(title) reminder for \(phrase).",
                        "Done, reminder for \(title) is scheduled for \(phrase)."
                    ]
                    return templates[seed % templates.count]
                }
                return "Reminder for \(title) has been set."
            }

        case "get_next_meeting":
            if let meeting = json["next_meeting"] as? [String: Any] {
                let title = (meeting["title"] as? String) ?? "Meeting"
                let iso = meeting["start"] as? String
                let spoken = (meeting["start_spoken"] as? String) ?? ""
                switch language {
                case .hinglish:
                    let phrase = friendlyHinglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                    let templates = [
                        "Aapki next meeting \(title) \(phrase) hai.",
                        "Agli meeting \(title) hai, jo \(phrase) hogi.",
                        "Aapki agli meeting \(phrase) \(title) hai."
                    ]
                    return templates[seed % templates.count]
                case .english:
                    let phrase = friendlyEnglishTimePhrase(fromISO: iso, spokenFallback: spoken, now: now)
                    let templates = [
                        "Your next meeting is \(title) \(phrase).",
                        "Up next is \(title), scheduled for \(phrase).",
                        "You have \(title) coming up \(phrase)."
                    ]
                    return templates[seed % templates.count]
                }
            }
            switch language {
            case .hinglish:
                let templates = [
                    "Aapki aage koi meeting scheduled nahi hai.",
                    "Aaj aage koi aur meeting nahi hai.",
                    "Abhi aapke schedule mein aage koi meeting nahi hai."
                ]
                return templates[seed % templates.count]
            case .english:
                let templates = [
                    "You have no upcoming meetings scheduled.",
                    "Your calendar is clear with no upcoming meetings.",
                    "There are no more meetings on your schedule."
                ]
                return templates[seed % templates.count]
            }

        case "get_schedule":
            let count = (json["meeting_count"] as? Int) ?? 0
            let meetings = (json["meetings"] as? [[String: Any]]) ?? []
            let dayDesc = (json["day"] as? String) ?? "today"
            let dayWordHi = dayDesc.lowercased().contains("tomorrow") ? "Kal" : "Aaj"
            if count == 0 || meetings.isEmpty {
                switch language {
                case .hinglish:
                    let templates = [
                        "\(dayWordHi) aapke schedule mein koi meeting nahi hai.",
                        "\(dayWordHi) koi meeting scheduled nahi hai.",
                        "\(dayWordHi) aapka calendar bilkul khali hai."
                    ]
                    return templates[seed % templates.count]
                case .english:
                    let templates = [
                        "You have no meetings scheduled for \(dayDesc).",
                        "Your schedule for \(dayDesc) is completely clear.",
                        "There are no meetings on your calendar for \(dayDesc)."
                    ]
                    return templates[seed % templates.count]
                }
            }
            switch language {
            case .hinglish:
                if let first = meetings.first,
                   let firstTitle = first["title"] as? String {
                    let firstISO = first["start"] as? String
                    let firstSpoken = (first["start_spoken"] as? String) ?? ""
                    let timeOnly = friendlyHinglishClockOnly(fromISO: firstISO, spokenFallback: firstSpoken)
                    let templates = [
                        "\(dayWordHi) aapki \(count) meetings hain, aur next \(firstTitle) \(timeOnly) hai.",
                        "\(dayWordHi) schedule mein \(count) meetings hain, pehli \(firstTitle) \(timeOnly) hai.",
                        "Aapki \(dayWordHi.lowercased()) \(count) meetings hain, jisme \(firstTitle) \(timeOnly) hai."
                    ]
                    return templates[seed % templates.count]
                }
                return "\(dayWordHi) aapki \(count) meetings hain."
            case .english:
                let firstTwo = meetings.prefix(2).compactMap { m -> String? in
                    guard let t = m["title"] as? String else { return nil }
                    let iso = m["start"] as? String
                    let spoken = (m["start_spoken"] as? String) ?? ""
                    let clock = friendlyEnglishClockOnly(fromISO: iso, spokenFallback: spoken)
                    return "\(t) at \(clock)"
                }.joined(separator: " and ")
                let templates = [
                    "You have \(count) \(count == 1 ? "meeting" : "meetings") \(dayDesc), starting with \(firstTwo).",
                    "For \(dayDesc), you have \(count) \(count == 1 ? "meeting" : "meetings"): \(firstTwo).",
                    "There \(count == 1 ? "is 1 meeting" : "are \(count) meetings") on your schedule \(dayDesc), including \(firstTwo)."
                ]
                return templates[seed % templates.count]
            }

        case "get_weather":
            let city = (json["city"] as? String) ?? "your city"
            let temp = extractLeadingInt(from: json["temperature"]) ?? (json["current_temp_c"] as? Int) ?? 25
            let condEn = ((json["condition"] as? String) ?? "clear").lowercased()
            let condHi = (json["condition_hinglish"] as? String) ?? condEn
            let high = extractLeadingInt(from: json["high"]) ?? (json["high_c"] as? Int) ?? temp
            let low = extractLeadingInt(from: json["low"]) ?? (json["low_c"] as? Int) ?? temp
            let rain = extractLeadingInt(from: json["rain_chance"]) ?? (json["rain_chance_percent"] as? Int) ?? 0
            switch language {
            case .hinglish:
                if rain >= 40 {
                    let templates = [
                        "\(city) mein \(condHi) hai, high \(high), low \(low) degrees, baarish \(rain) percent.",
                        "Aaj \(city) mein \(condHi), high \(high), low \(low) degrees, baarish \(rain) percent.",
                        "\(city) mein abhi \(condHi), high \(high), low \(low) degrees, rain \(rain) percent."
                    ]
                    return templates[seed % templates.count]
                } else {
                    let templates = [
                        "\(city) mein abhi \(condHi) hai, high \(high) aur low \(low) degrees.",
                        "Aaj \(city) mein \(condHi) hai, high \(high) aur low \(low) degrees.",
                        "\(city) mein mausam \(condHi) hai, high \(high) aur low \(low) degrees."
                    ]
                    return templates[seed % templates.count]
                }
            case .english:
                if rain >= 40 {
                    let templates = [
                        "In \(city), it is \(condEn) with a high of \(high), low of \(low), and \(rain) percent rain.",
                        "\(city) is \(condEn) today, high \(high) and low \(low) degrees, with \(rain) percent rain chance.",
                        "Today in \(city), expect \(condEn) skies, high \(high), low \(low) degrees, and \(rain) percent rain."
                    ]
                    return templates[seed % templates.count]
                } else {
                    let templates = [
                        "In \(city), it is \(condEn) today with a high of \(high) and low of \(low) degrees.",
                        "\(city) is \(condEn) today, with a high of \(high) degrees and low of \(low) degrees.",
                        "Today in \(city), it is \(condEn) with a high of \(high) and low of \(low) degrees."
                    ]
                    return templates[seed % templates.count]
                }
            }

        default:
            return nil
        }
    }

    private nonisolated static func formatCombinedScheduleAndNextMeeting(
        scheduleJSON: [String: Any],
        nextJSON: [String: Any],
        language: VoiceAgentViewModel.Language,
        turnSeed: Int,
        now: Date
    ) -> String? {
        let count = (scheduleJSON["meeting_count"] as? Int) ?? 0
        let meetings = (scheduleJSON["meetings"] as? [[String: Any]]) ?? []
        let nextMeetingDict = (nextJSON["next_meeting"] as? [String: Any]) ?? meetings.first

        switch language {
        case .hinglish:
            if count == 0 || meetings.isEmpty {
                return "Aaj aapke schedule mein koi meeting nahi hai."
            }
            if let next = nextMeetingDict,
               let title = next["title"] as? String {
                let iso = next["start"] as? String
                let spoken = (next["start_spoken"] as? String) ?? ""
                let clock = friendlyHinglishClockOnly(fromISO: iso, spokenFallback: spoken)
                let templates = [
                    "Aaj aapki \(count) meetings hain, aur next meeting \(title) \(clock) hai.",
                    "Aaj schedule mein \(count) meetings hain, agli meeting \(title) \(clock) hogi."
                ]
                return templates[abs(turnSeed) % templates.count]
            }
            return "Aaj aapke schedule mein \(count) meetings hain."
        case .english:
            if count == 0 || meetings.isEmpty {
                return "You have no meetings scheduled for today."
            }
            if let next = nextMeetingDict,
               let title = next["title"] as? String {
                let iso = next["start"] as? String
                let spoken = (next["start_spoken"] as? String) ?? ""
                let clock = friendlyEnglishClockOnly(fromISO: iso, spokenFallback: spoken)
                let templates = [
                    "You have \(count) meetings today, and your next meeting is \(title) at \(clock).",
                    "There are \(count) meetings on your schedule today, with \(title) up next at \(clock)."
                ]
                return templates[abs(turnSeed) % templates.count]
            }
            return "You have \(count) meetings scheduled for today."
        }
    }

    /// Generates a deterministic spoken confirmation/summary from the last successful tool result when the LLM reply is empty or truncated (< 3 words).
    public nonisolated static func deterministicToolFallbackReply(
        executedTools: [LLMToolCall],
        executedToolOutputs: [String],
        language: VoiceAgentViewModel.Language,
        now: Date = Date()
    ) -> String? {
        fastPathToolReply(
            executedTools: executedTools,
            executedToolOutputs: executedToolOutputs,
            language: language,
            turnSeed: 0,
            now: now
        )
    }

    private nonisolated static func extractLeadingInt(from anyValue: Any?) -> Int? {
        if let intVal = anyValue as? Int { return intVal }
        if let strVal = anyValue as? String,
           let match = strVal.range(of: #"-?\d+"#, options: .regularExpression) {
            return Int(strVal[match])
        }
        return nil
    }

    private nonisolated static func friendlyHinglishClockOnly(fromISO isoString: String?, spokenFallback: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let isoString, let date = formatter.date(from: isoString) {
            let calendar = Calendar.current
            let hour24 = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            let periodWord: String
            if hour24 >= 4 && hour24 < 12 {
                periodWord = "subah"
            } else if hour24 >= 12 && hour24 < 17 {
                periodWord = "dopahar"
            } else if hour24 >= 17 && hour24 < 21 {
                periodWord = "shaam"
            } else {
                periodWord = "raat"
            }
            let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
            let timeStr = (minute == 0) ? "\(hour12) baje" : String(format: "%d:%02d baje", hour12, minute)
            return "\(periodWord) \(timeStr)"
        }
        return spokenFallback.isEmpty ? "scheduled time" : spokenFallback
    }

    private nonisolated static func friendlyEnglishClockOnly(fromISO isoString: String?, spokenFallback: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let isoString, let date = formatter.date(from: isoString) {
            let calendar = Calendar.current
            let hour24 = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            let amPm = hour24 < 12 ? "AM" : "PM"
            let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
            return (minute == 0) ? "\(hour12) \(amPm)" : String(format: "%d:%02d %@", hour12, minute, amPm)
        }
        return spokenFallback.isEmpty ? "the scheduled time" : spokenFallback
    }

    private nonisolated static func friendlyHinglishTimePhrase(fromISO isoString: String?, spokenFallback: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        if let isoString, let date = formatter.date(from: isoString) {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: now)
            let dayWord: String
            if calendar.isDate(date, inSameDayAs: now) {
                dayWord = "aaj"
            } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
                      calendar.isDate(date, inSameDayAs: tomorrow) {
                dayWord = "kal"
            } else if let dayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday),
                      calendar.isDate(date, inSameDayAs: dayAfter) {
                dayWord = "parso"
            } else {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "EEEE"
                dayWord = df.string(from: date)
            }

            let hour24 = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            let periodWord: String
            if hour24 >= 4 && hour24 < 12 {
                periodWord = "subah"
            } else if hour24 >= 12 && hour24 < 17 {
                periodWord = "dopahar"
            } else if hour24 >= 17 && hour24 < 21 {
                periodWord = "shaam"
            } else {
                periodWord = "raat"
            }

            let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
            let timeStr = (minute == 0) ? "\(hour12) baje" : String(format: "%d:%02d baje", hour12, minute)
            return "\(dayWord) \(periodWord) \(timeStr)"
        }
        return spokenFallback.isEmpty ? "scheduled time" : spokenFallback
    }

    private nonisolated static func friendlyEnglishTimePhrase(fromISO isoString: String?, spokenFallback: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        if let isoString, let date = formatter.date(from: isoString) {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: now)
            let dayWord: String
            if calendar.isDate(date, inSameDayAs: now) {
                dayWord = "today"
            } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
                      calendar.isDate(date, inSameDayAs: tomorrow) {
                dayWord = "tomorrow"
            } else if let dayAfter = calendar.date(byAdding: .day, value: 2, to: startOfToday),
                      calendar.isDate(date, inSameDayAs: dayAfter) {
                dayWord = "the day after tomorrow"
            } else {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = "EEEE, MMMM d"
                dayWord = df.string(from: date)
            }

            let hour24 = calendar.component(.hour, from: date)
            let minute = calendar.component(.minute, from: date)
            let amPm = hour24 < 12 ? "AM" : "PM"
            let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
            let timeStr = (minute == 0) ? "\(hour12) \(amPm)" : String(format: "%d:%02d %@", hour12, minute, amPm)
            return "\(dayWord) at \(timeStr)"
        }
        return spokenFallback.isEmpty ? "the requested time" : spokenFallback
    }

    private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        let (seconds, attoseconds) = elapsed.components
        return Double(seconds) * 1000.0 + Double(attoseconds) / 1_000_000_000_000_000.0
    }
}

// MARK: - Thread-Safe First-Token & Sentence/Clause Streaming Hooks

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

/// Minimal locked buffer used by a provider's `@Sendable` stream callback.
nonisolated private final class LockedTextBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Buffers streamed LLM text deltas and emits complete sentences or clauses (`3–4` words for Chunk 1, `>= 4` words at commas/clauses afterwards) to `onSentenceReady`.
nonisolated internal final class SentenceStreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: String = ""
    private var emittedChunksCount: Int = 0
    private let language: VoiceAgentViewModel.Language
    private let callback: (@Sendable (String) -> Void)?

    init(language: VoiceAgentViewModel.Language, callback: (@Sendable (String) -> Void)?) {
        self.language = language
        self.callback = callback
    }

    static func splitText(_ text: String, language: VoiceAgentViewModel.Language) -> [String] {
        var readyChunks: [String] = []
        var buffer = text
        var emittedChunksCount = 0
        while let boundaryIndex = Self.firstClauseOrSentenceBoundary(
            in: buffer,
            allowEndOfBuffer: true,
            isFirstChunk: (emittedChunksCount == 0)
        ) {
            let candidate = String(buffer[...boundaryIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: boundaryIndex)...])
            let sanitized = AgentOrchestrator.sanitizeSpokenReply(candidate)
            if !sanitized.isEmpty {
                emittedChunksCount += 1
                readyChunks.append(sanitized)
            }
        }
        let remainder = AgentOrchestrator.sanitizeSpokenReply(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        if !remainder.isEmpty {
            readyChunks.append(remainder)
        }
        return readyChunks
    }

    var emittedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return emittedChunksCount
    }

    func resetUncommitted() {
        lock.lock()
        buffer = ""
        lock.unlock()
    }

    func replaceBuffer(with text: String) {
        lock.lock()
        buffer = text
        lock.unlock()
    }

    func append(_ delta: String) {
        guard let callback else { return }
        var readyChunks: [String] = []

        lock.lock()
        buffer += delta
        while let boundaryIndex = Self.firstClauseOrSentenceBoundary(
            in: buffer,
            allowEndOfBuffer: false,
            isFirstChunk: (emittedChunksCount == 0)
        ) {
            let candidate = String(buffer[...boundaryIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            // In English mode, if the candidate contains Hinglish markers, hold back so the end-of-turn language guard can rewrite it cleanly
            if language == .english && AgentOrchestrator.containsHinglishMarkers(candidate) {
                break
            }
            buffer = String(buffer[buffer.index(after: boundaryIndex)...])
            let sanitized = AgentOrchestrator.sanitizeSpokenReply(candidate)
            if !sanitized.isEmpty {
                emittedChunksCount += 1
                readyChunks.append(sanitized)
            }
        }
        lock.unlock()

        for chunk in readyChunks {
            callback(chunk)
        }
    }

    func flushRemaining() {
        guard let callback else { return }
        var readyChunks: [String] = []

        lock.lock()
        while let boundaryIndex = Self.firstClauseOrSentenceBoundary(
            in: buffer,
            allowEndOfBuffer: true,
            isFirstChunk: (emittedChunksCount == 0)
        ) {
            let candidate = String(buffer[...boundaryIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[buffer.index(after: boundaryIndex)...])
            let sanitized = AgentOrchestrator.sanitizeSpokenReply(candidate)
            if !sanitized.isEmpty {
                emittedChunksCount += 1
                readyChunks.append(sanitized)
            }
        }
        let remainder = AgentOrchestrator.sanitizeSpokenReply(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        buffer = ""
        if !remainder.isEmpty {
            emittedChunksCount += 1
            readyChunks.append(remainder)
        }
        lock.unlock()

        for chunk in readyChunks {
            callback(chunk)
        }
    }

    /// Splits streamed text at:
    /// 1. Sentence ends (`.`, `!`, `?`, `।`, `\n`) when followed by whitespace (ignoring decimal dots like `28.5`), or
    /// 2. Commas/clause punctuation (`,`, `;`, `:`, `—`, `–`) followed by whitespace once the chunk has `>= 2` words (first chunk) or `>= 4` words (later chunks), or
    /// 3. For the FIRST chunk (`isFirstChunk == true`), after `3–4` words if no punctuation boundary has occurred yet once `>= 5` words are in the buffer, avoiding splits right before Hindi postpositions.
    private static func firstClauseOrSentenceBoundary(
        in text: String,
        allowEndOfBuffer: Bool = false,
        isFirstChunk: Bool = false
    ) -> String.Index? {
        let sentenceTerminators: Set<Character> = [".", "!", "?", "।", "\n"]
        let clauseDelimiters: Set<Character> = [",", ";", ":", "—", "–"]
        let minClauseWords = isFirstChunk ? 2 : 4

        var wordEndIndices: [String.Index] = []
        var wordsLower: [String] = []
        var currentWordStart: String.Index?

        for idx in text.indices {
            let ch = text[idx]
            if ch.isWhitespace || ch.isNewline {
                if let start = currentWordStart {
                    let prevIdx = text.index(before: idx)
                    wordEndIndices.append(prevIdx)
                    let rawWord = String(text[start...prevIdx]).trimmingCharacters(in: .punctuationCharacters)
                    wordsLower.append(rawWord.lowercased())
                    currentWordStart = nil
                }
            } else if currentWordStart == nil {
                currentWordStart = idx
            }

            let nextIdx = text.index(after: idx)
            let isFollowedBySpace = (nextIdx < text.endIndex && text[nextIdx].isWhitespace) || (allowEndOfBuffer && nextIdx == text.endIndex)
            guard isFollowedBySpace else { continue }

            if sentenceTerminators.contains(ch) {
                if ch == "." {
                    // Ignore decimal points such as "28.5"
                    if idx > text.startIndex {
                        let prevIdx = text.index(before: idx)
                        if text[prevIdx].isNumber, nextIdx < text.endIndex, text[nextIdx].isNumber {
                            continue
                        }
                    }
                }
                let prefixWords = text[...idx].split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                if prefixWords >= 1 {
                    return idx
                }
            } else if clauseDelimiters.contains(ch) {
                if ch == ":" && idx > text.startIndex {
                    let prevIdx = text.index(before: idx)
                    if text[prevIdx].isNumber {
                        continue
                    }
                }
                let prefixWords = text[...idx].split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
                if prefixWords >= minClauseWords {
                    return idx
                }
            }
        }

        if isFirstChunk && wordEndIndices.count >= 5 {
            let hindiPostpositions: Set<String> = [
                "mein", "par", "ko", "se", "ke", "ka", "ki", "ne", "tak", "bhi", "hi", "baje", "liye"
            ]
            let danglingWords: Set<String> = [
                "the", "a", "an", "in", "on", "at", "to", "of", "for", "with", "by", "from", "aur", "and", "is", "are"
            ]
            var targetWordCount = 3
            if wordsLower.count > targetWordCount, hindiPostpositions.contains(wordsLower[targetWordCount]) {
                targetWordCount = 4
            }
            if targetWordCount == 3, danglingWords.contains(wordsLower[2]) {
                targetWordCount = 4
            }
            let clamped = min(targetWordCount, wordEndIndices.count)
            return wordEndIndices[clamped - 1]
        }

        return nil
    }
}
