import SwiftUI

/// Single toggle for developer TTS comparison controls (`TTS Lab`).
/// Defaults to `false` so only the language toggle and mic appear on the main screen.
nonisolated public let kDevTools: Bool = true

/// When `true`, `get_schedule` and `get_next_meeting` read ONLY the `"Vaani Demo"` calendar so personal events are never read aloud.
nonisolated public let kDemoCalendarOnly: Bool = true

struct ContentView: View {
    @State private var viewModel = VoiceAgentViewModel()
    @State private var isShowingTTSLab = false
    @State private var isDevSectionExpanded = false
    @State private var devPromptText: String = ""
    @FocusState private var isDevPromptFocused: Bool
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // MARK: - Header & Language Toggle
                    headerSection
                    
                    // MARK: - Current State Indicator
                    stateBadge

                    modelStatusBadges

                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }

                    if kDevTools {
                        devControlsSection
                    }
                    
                    // MARK: - Cards (Transcript & Response)
                    cardsSection
                    
                    // MARK: - Latency Readout
                    latencySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomControlsDock
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Vaani")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if kDevTools {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isShowingTTSLab = true
                        } label: {
                            Label("TTS Lab", systemImage: "speaker.wave.2.bubble.left.fill")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingTTSLab) {
                TTSLabView(viewModel: viewModel)
            }
        }
        .task {
            viewModel.prepareSpeechToText()
        }
    }
    
    // MARK: - Header & Language
    
    private var headerSection: some View {
        HStack {
            Label("Voice Agent", systemImage: "waveform.circle.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Spacer()
            
            Picker("Language", selection: $viewModel.language) {
                ForEach(VoiceAgentViewModel.Language.allCases) { lang in
                    Text(lang.rawValue).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 175)
        }
    }
    
    // MARK: - State Badge
    
    private var stateBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
                .scaleEffect(viewModel.state == .listening ? 1.25 : 1.0)
                .animation(
                    viewModel.state == .listening
                        ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true)
                        : .default,
                    value: viewModel.state
                )
            
            Text(viewModel.state.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(stateColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(stateColor.opacity(0.12), in: Capsule())
    }
    
    private var stateColor: Color {
        switch viewModel.state {
        case .idle:
            return .secondary
        case .listening:
            return .red
        case .transcribing:
            return .blue
        case .thinking:
            return .purple
        case .speaking:
            return .green
        }
    }

    private var modelStatusBadges: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if !viewModel.isSTTReady {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }

                Text(viewModel.sttLoadingState.displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(viewModel.isSTTReady ? .green : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())

            HStack(spacing: 8) {
                switch viewModel.kokoroLoadingState {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                case .ready:
                    Image(systemName: "waveform.badge.checkmark")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                }

                Text(viewModel.kokoroLoadingState.displayName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(viewModel.isKokoroReady ? .green : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        }
    }

    // MARK: - Collapsible Dev Section (`kDevTools` only)

    private var effectiveDevEngineBinding: Binding<TTSEngine> {
        Binding(
            get: {
                if viewModel.devTTSOverrideEnabled {
                    return viewModel.ttsEngine
                }
                return viewModel.language == .english ? .apple : .kokoro
            },
            set: { newEngine in
                viewModel.devTTSOverrideEnabled = true
                viewModel.ttsEngine = newEngine
            }
        )
    }

    private var effectiveDevKokoroStrategyBinding: Binding<KokoroStrategy> {
        Binding(
            get: {
                if viewModel.devTTSOverrideEnabled {
                    return viewModel.kokoroStrategy
                }
                return .k2DevanagariMixHi
            },
            set: { newStrategy in
                viewModel.devTTSOverrideEnabled = true
                viewModel.kokoroStrategy = newStrategy
            }
        )
    }

    private var devControlsSection: some View {
        DisclosureGroup(isExpanded: $isDevSectionExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current TTS: \(viewModel.currentTTSEngineDescription)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(viewModel.devTTSOverrideEnabled ? .orange : .primary)
                        Text("Locked default: En → Apple Isha • Hinglish → Kokoro hf_beta (K2)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Reset override") {
                        viewModel.resetDevTTSOverride()
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!viewModel.devTTSOverrideEnabled)
                }

                HStack {
                    Text("Engine")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("TTS Engine", selection: effectiveDevEngineBinding) {
                        ForEach(TTSEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                }

                if effectiveDevEngineBinding.wrappedValue == .kokoro {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kokoro Strategy")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Picker("Kokoro Strategy", selection: effectiveDevKokoroStrategyBinding) {
                            ForEach(KokoroStrategy.allCases) { strategy in
                                Text(strategy.shortName).tag(strategy)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                HStack {
                    if let provider = viewModel.lastAnsweringProvider {
                        Label("LLM: \(provider)", systemImage: "bolt.horizontal.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.purple)
                    } else {
                        Text("LLM: Groq → Gemini fallback")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text("K2 Misses: \(viewModel.k2MissCount)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(viewModel.k2MissCount > 0 ? .orange : .secondary)

                    Button {
                        isShowingTTSLab = true
                    } label: {
                        Label("Open TTS Lab", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Divider()

                HStack(spacing: 8) {
                    Button("Seed demo events") {
                        viewModel.seedDemoEvents()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Clear demo events", role: .destructive) {
                        viewModel.clearDemoEvents()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }

                if let status = viewModel.demoEventsStatus {
                    Text(status)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Divider()

                // MARK: - Dev Alarms Subsection
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Alarms (AlarmKit)", systemImage: "alarm.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Spacer()

                        Button {
                            viewModel.refreshAlarms()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                    }

                    if viewModel.scheduledAlarms.isEmpty {
                        Text("No active AlarmKit alarms scheduled.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(viewModel.scheduledAlarms) { alarm in
                            HStack(spacing: 6) {
                                Text(String(alarm.id.uuidString.prefix(8)))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("•")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(alarm.timeDescription)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                Spacer()
                                Text(alarm.stateDescription)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Test alarm in 1 min") {
                            viewModel.testAlarmInOneMinute()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Cancel all Vaani alarms", role: .destructive) {
                            viewModel.cancelAllVaaniAlarms()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()
                    }

                    if let alarmStatus = viewModel.alarmStatusMessage {
                        Text(alarmStatus)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Dev")
                    .font(.subheadline.weight(.semibold))
                if viewModel.devTTSOverrideEnabled {
                    Text("Override")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let provider = viewModel.lastAnsweringProvider {
                    Text(provider)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.purple)
                }
            }
        }
        .onChange(of: isDevSectionExpanded) { _, expanded in
            if expanded {
                viewModel.refreshAlarms()
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Dev Tools Text Prompt Input (`kDevTools` only, pinned above Mic)

    private var devTextPromptSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField("Ask Vaani in English or Hinglish...", text: $devPromptText)
                .textFieldStyle(.plain)
                .focused($isDevPromptFocused)
                .submitLabel(.send)
                .onSubmit {
                    submitDevPrompt()
                }

            if isDevPromptFocused {
                Button("Done") {
                    isDevPromptFocused = false
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }

            Button {
                submitDevPrompt()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        devPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary.opacity(0.4)
                            : Color.accentColor
                    )
            }
            .disabled(devPromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func submitDevPrompt() {
        let trimmed = devPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        devPromptText = ""
        isDevPromptFocused = false
        viewModel.sendTextPrompt(trimmed)
    }
    
    // MARK: - Cards
    
    private var cardsSection: some View {
        VStack(spacing: 16) {
            // Transcript Card
            cardView(
                title: "Transcript",
                icon: "quote.opening",
                content: viewModel.transcript,
                placeholder: "Tap the mic and speak...",
                accentColor: .blue
            )
            
            // Response Card
            cardView(
                title: "Vaani's Response",
                icon: "sparkles",
                content: viewModel.response,
                placeholder: "Agent response will appear here...",
                accentColor: .purple
            )

            // Non-dev Alarm Confirmation Card (below response card)
            if let alarmNote = viewModel.lastScheduledAlarmNote {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "alarm.waves.left.and.right.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)

                    Text(alarmNote)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                )
            }
        }
    }
    
    private func cardView(
        title: String,
        icon: String,
        content: String,
        placeholder: String,
        accentColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(accentColor)
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            
            if content.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .italic()
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            } else {
                Text(content)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 8, y: 3)
    }
    
    // MARK: - Latency Readout
    
    private var latencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Latency Breakdown")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
                if viewModel.latency.ttsSynthMs > 0 && viewModel.latency.ttsRTF > 0 {
                    Text(String(
                        format: "Synth: %.0f ms • RTF: %.2f • Play: %.0f ms",
                        viewModel.latency.ttsSynthMs,
                        viewModel.latency.ttsRTF,
                        viewModel.latency.ttsTotalDurationMs
                    ))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else if viewModel.latency.ttsTotalDurationMs > 0 {
                    Text(String(format: "TTS Play: %.0f ms", viewModel.latency.ttsTotalDurationMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack(spacing: 8) {
                latencyMetricPill(label: "STT", ms: viewModel.latency.sttMs)
                latencyMetricPill(label: "LLM 1st", ms: viewModel.latency.llmFirstTokenMs)
                latencyMetricPill(label: "LLM", ms: viewModel.latency.llmTotalMs)
                latencyMetricPill(label: "TTS 1st", ms: viewModel.latency.ttsMs)
                latencyMetricPill(label: "Total", ms: viewModel.latency.totalMs, isHighlighted: true)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    
    private func latencyMetricPill(label: String, ms: Double, isHighlighted: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            
            Text(ms > 0 ? String(format: "%.0f ms", ms) : "--")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(isHighlighted ? Color.primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            isHighlighted
                ? Color.accentColor.opacity(0.12)
                : Color(uiColor: .tertiarySystemGroupedBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    
    // MARK: - Pinned Bottom Dock (Dev Text Input + Audio Visualizer + Mic Button)
    
    private var bottomControlsDock: some View {
        VStack(spacing: 10) {
            if kDevTools {
                devTextPromptSection
            }

            if !isDevPromptFocused {
                controlsSection
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 12) {
            // Animated level meter while listening
            if viewModel.state == .listening {
                audioLevelMeter
                    .frame(height: 44)
            }
            
            // Large Mic Button
            micButton
        }
    }
    
    private var audioLevelMeter: some View {
        HStack(spacing: 5) {
            ForEach(0..<9, id: \.self) { index in
                let height = barHeight(for: index)
                RoundedRectangle(cornerRadius: 3)
                    .fill(
                        LinearGradient(
                            colors: viewModel.state == .listening ? [.red, .orange] : [.secondary.opacity(0.3)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 6, height: height)
            }
        }
        .frame(height: 64)
        .animation(.easeInOut(duration: 0.1), value: viewModel.audioLevel)
        .opacity(viewModel.state == .listening ? 1.0 : 0.3)
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        guard viewModel.state == .listening else { return 6.0 }
        let center = 4.0
        let distanceFromCenter = abs(Double(index) - center)
        let falloff = max(0.45, 1.0 - (distanceFromCenter * 0.14))
        let level = Double(viewModel.audioLevel)
        let minHeight: CGFloat = 6.0
        let maxHeight: CGFloat = 60.0
        let dynamicHeight = minHeight + CGFloat(level * falloff) * (maxHeight - minHeight)
        return min(maxHeight, max(minHeight, dynamicHeight))
    }
    
    private var micButton: some View {
        Button {
            viewModel.toggleListening()
        } label: {
            ZStack {
                // Pulsing ring while listening
                if viewModel.state == .listening {
                    Circle()
                        .stroke(Color.red.opacity(0.35), lineWidth: 4)
                        .frame(width: 104, height: 104)
                        .scaleEffect(1.0 + CGFloat(viewModel.audioLevel) * 0.35)
                        .animation(.easeOut(duration: 0.1), value: viewModel.audioLevel)
                }
                
                Circle()
                    .fill(micButtonColor)
                    .frame(width: 84, height: 84)
                    .shadow(color: micButtonColor.opacity(0.4), radius: 12, y: 6)
                
                Image(systemName: micButtonIcon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isSTTReady && viewModel.state != .listening)
        .opacity(!viewModel.isSTTReady && viewModel.state != .listening ? 0.45 : 1.0)
        .accessibilityLabel(viewModel.state == .listening ? "Stop listening" : "Start listening")
    }
    
    private var micButtonColor: Color {
        switch viewModel.state {
        case .listening:
            return .red
        case .transcribing, .thinking, .speaking:
            return .orange
        case .idle:
            return .blue
        }
    }
    
    private var micButtonIcon: String {
        switch viewModel.state {
        case .listening:
            return "stop.fill"
        case .transcribing:
            return "waveform"
        case .thinking:
            return "ellipsis"
        case .speaking:
            return "speaker.wave.2.fill"
        case .idle:
            return "mic.fill"
        }
    }
    
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - TTS Comparison Lab Screen

struct TTSLabView: View {
    @Bindable var viewModel: VoiceAgentViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var customText: String = "Aaj mausam bilkul suhana hai, lagbhag 24 degrees."
    @State private var selectedKokoroSpeakerID: Int = KokoroSpeaker.defaultHindiSpeakerID
    @State private var isPlaying: Bool = false
    @State private var firstAudioMs: Double?
    @State private var synthMs: Double?
    @State private var rtfValue: Double?
    @State private var totalDurationMs: Double?
    @State private var lastSpokenVoiceLabel: String?
    @State private var lastSpokenText: String?
    @State private var playTask: Task<Void, Never>?

    private static let assignmentSentences: [String] = [
        "What is the weather forecast for Bangalore tomorrow?",
        "Can you set a reminder for my meeting at 5 PM?",
        "Mujhe kal subah 7 baje ka alarm set karna hai.",
        "Aaj ka schedule kya hai, aur meri next meeting kab hai?"
    ]

    private static let hinglishReplies: [String] = [
        "Aaj mausam bilkul suhana hai, lagbhag 24 degrees.",
        "Aapka alarm kal subah 7 baje ke liye set ho gaya hai.",
        "Kal Bangalore mein halka baarish hone ka chance hai, temperature 24 degrees rahega.",
        "Aaj aapke schedule mein 3 meetings hain, aur next meeting shaam 5 baje hai."
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 1. Engine & Strategy Picker
                    engineAndStrategyCard

                    // 2. Speaker / Voice & Speed Picker
                    voiceAndSpeedCard

                    // 3. Text Input & Transliteration Preview
                    textInputCard

                    // 4. Play Button & Latency / RTF Readout
                    playbackAndMetricsCard

                    // 5. Preset Sentence Buttons (8 presets)
                    presetsSection
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("TTS Comparison Lab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        stopPlayback()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            selectedKokoroSpeakerID = (viewModel.kokoroStrategy == .k3RomanizedEnUS)
                ? viewModel.kokoroEnglishSpeakerID
                : viewModel.kokoroHindiSpeakerID
        }
        .onChange(of: viewModel.kokoroStrategy) { _, newStrategy in
            switch newStrategy {
            case .k1RomanizedHi, .k2DevanagariMixHi:
                selectedKokoroSpeakerID = viewModel.kokoroHindiSpeakerID
            case .k3RomanizedEnUS:
                selectedKokoroSpeakerID = viewModel.kokoroEnglishSpeakerID
            }
        }
        .onDisappear {
            stopPlayback()
        }
    }

    // MARK: - Sections

    private var engineAndStrategyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("TTS Engine", systemImage: "cpu.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if viewModel.ttsEngine == .kokoro {
                    Text(viewModel.kokoroLoadingState.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(viewModel.isKokoroReady ? .green : .orange)
                }
            }

            Picker("Engine", selection: $viewModel.ttsEngine) {
                ForEach(TTSEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.segmented)

            Divider()

            Label("Hinglish Strategy", systemImage: "character.bubble.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if viewModel.ttsEngine == .kokoro {
                Picker("Kokoro Strategy", selection: $viewModel.kokoroStrategy) {
                    ForEach(KokoroStrategy.allCases) { strategy in
                        Text(strategy.shortName).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.kokoroStrategy.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Apple Strategy", selection: $viewModel.ttsStrategy) {
                    ForEach(TTSStrategy.allCases) { strategy in
                        Text(strategy.displayName).tag(strategy)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.ttsStrategy.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var voiceAndSpeedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.ttsEngine == .kokoro {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Kokoro Voice", systemImage: "person.wave.2.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Spacer()

                        Text("\(KokoroSpeaker.curatedSpeakers.count) voices")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Text("Kokoro-82M v1.0 (int8), runs fully on-device")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Select Kokoro Speaker", selection: $selectedKokoroSpeakerID) {
                    ForEach(KokoroSpeaker.curatedSpeakers) { speaker in
                        Text(speaker.displayLabel).tag(speaker.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: selectedKokoroSpeakerID) { _, newID in
                    let speaker = KokoroSpeaker.speaker(forID: newID)
                    if speaker.isHindi {
                        viewModel.kokoroHindiSpeakerID = newID
                    } else if speaker.isEnglish {
                        viewModel.kokoroEnglishSpeakerID = newID
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Speech Speed", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Spacer()

                        Text(String(format: "%.2fx", viewModel.kokoroSpeed))
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(.blue)

                        if abs(viewModel.kokoroSpeed - 1.0) > 0.01 {
                            Button("Reset") {
                                viewModel.kokoroSpeed = 1.0
                            }
                            .font(.caption2)
                        }
                    }

                    Slider(value: $viewModel.kokoroSpeed, in: 0.8...1.3, step: 0.05)

                    HStack {
                        Text("0.8x (Slower)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("1.0x")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text("1.3x (Faster)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                HStack {
                    Label("Apple Voice", systemImage: "person.wave.2.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Spacer()
                }

                HStack {
                    Text(AppleTTS.ishaVoiceInfo.displayLabel)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var isDevanagariPreviewActive: Bool {
        if viewModel.ttsEngine == .kokoro {
            return viewModel.kokoroStrategy == .k2DevanagariMixHi
        } else {
            return viewModel.ttsStrategy == .devanagariHiIN
        }
    }

    private var textInputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Utterance Text", systemImage: "text.bubble.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                if !customText.isEmpty {
                    Button("Clear") {
                        customText = ""
                    }
                    .font(.caption)
                }
            }

            TextField("Enter English or Hinglish text to synthesize...", text: $customText, axis: .vertical)
                .lineLimit(3...6)
                .padding(12)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            if isDevanagariPreviewActive && !customText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Devanagari Mix Preview (\(HinglishTransliterator.commonHindiWords.count) Hindi words dict):")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(HinglishTransliterator.transliterate(customText, logMisses: false))
                        .font(.footnote)
                        .foregroundStyle(.blue)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var playbackAndMetricsCard: some View {
        VStack(spacing: 14) {
            Button {
                if isPlaying {
                    stopPlayback()
                } else {
                    playCurrentText()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                        .font(.headline)
                    Text(isPlaying ? "Stop Playback" : "Play Utterance")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(isPlaying ? Color.red : Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isPlaying)

            HStack(spacing: 10) {
                metricBox(
                    title: "First Audio",
                    value: firstAudioMs.map { String(format: "%.0f ms", $0) } ?? "--",
                    highlighted: true
                )

                metricBox(
                    title: "Synth Time",
                    value: synthMs.map { String(format: "%.0f ms", $0) } ?? "--",
                    highlighted: false
                )

                metricBox(
                    title: "RTF",
                    value: rtfValue.map { String(format: "%.2f", $0) } ?? "--",
                    highlighted: false
                )
            }

            if let totalMs = totalDurationMs {
                HStack {
                    Text(String(format: "Total Playback Duration: %.0f ms", totalMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let voiceLabel = lastSpokenVoiceLabel {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Voice: \(voiceLabel)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let spoken = lastSpokenText {
                        Text("Sent to model: \"\(spoken)\"")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func metricBox(title: String, value: String, highlighted: Bool) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
                .foregroundStyle(highlighted ? Color.blue : Color.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            highlighted
                ? Color.blue.opacity(0.1)
                : Color(uiColor: .tertiarySystemGroupedBackground)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            presetGroup(
                title: "Assignment Example Sentences",
                icon: "doc.text.fill",
                sentences: Self.assignmentSentences
            )

            presetGroup(
                title: "Hinglish Agent Replies",
                icon: "bubble.left.and.bubble.right.fill",
                sentences: Self.hinglishReplies
            )
        }
    }

    private func presetGroup(title: String, icon: String, sentences: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            ForEach(sentences, id: \.self) { sentence in
                Button {
                    customText = sentence
                    playCurrentText()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.body)
                        Text(sentence)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Playback Actions

    private func playCurrentText() {
        playTask?.cancel()
        viewModel.reset()

        let textToSpeak = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSpeak.isEmpty else { return }

        let activeEngine = viewModel.ttsEngine
        let chosenKokoroStrategy = viewModel.kokoroStrategy
        let chosenKokoroSpeaker = selectedKokoroSpeakerID
        let chosenKokoroSpeed = viewModel.kokoroSpeed
        let chosenAppleStrategy = viewModel.ttsStrategy

        isPlaying = true
        firstAudioMs = nil
        synthMs = nil
        rtfValue = nil
        totalDurationMs = nil

        playTask = Task {
            if activeEngine == .kokoro && viewModel.kokoroTTS.isReady {
                let kokoro = viewModel.kokoroTTS
                let previousFirstAudioHandler = kokoro.onFirstAudio

                kokoro.onFirstAudio = { ms in
                    self.firstAudioMs = ms
                    previousFirstAudioHandler?(ms)
                }

                defer {
                    kokoro.onFirstAudio = previousFirstAudioHandler
                    if !Task.isCancelled {
                        isPlaying = false
                    }
                }

                do {
                    let metrics = try await kokoro.speakWithMetrics(
                        text: textToSpeak,
                        language: .hinglish,
                        strategyOverride: chosenKokoroStrategy,
                        speakerIDOverride: chosenKokoroSpeaker,
                        speedOverride: chosenKokoroSpeed
                    )
                    guard !Task.isCancelled else { return }
                    self.firstAudioMs = metrics.firstAudioMs
                    self.synthMs = metrics.synthMs
                    self.rtfValue = metrics.rtf
                    self.totalDurationMs = metrics.totalDurationMs
                    self.lastSpokenVoiceLabel = "Kokoro [\(metrics.speakerID)] \(metrics.speakerName) (lang=\(metrics.lang), speed=\(String(format: "%.2fx", metrics.speed)))"
                    self.lastSpokenText = metrics.spokenText
                } catch is CancellationError {
                    // Stopped by user
                } catch {
                    print("TTS Lab Kokoro playback error: \(error)")
                }
            } else {
                let appleTTS = viewModel.appleTTS
                let previousFirstAudioHandler = appleTTS.onFirstAudio

                appleTTS.onFirstAudio = { ms in
                    self.firstAudioMs = ms
                    previousFirstAudioHandler?(ms)
                }

                defer {
                    appleTTS.onFirstAudio = previousFirstAudioHandler
                    if !Task.isCancelled {
                        isPlaying = false
                    }
                }

                do {
                    let metrics = try await appleTTS.speakWithMetrics(
                        text: textToSpeak,
                        language: .hinglish,
                        strategyOverride: chosenAppleStrategy,
                        voiceIdentifierOverride: AppleTTS.ishaVoiceInfo.id
                    )
                    guard !Task.isCancelled else { return }
                    self.firstAudioMs = metrics.firstAudioMs
                    self.synthMs = metrics.firstAudioMs
                    self.rtfValue = 0.0
                    self.totalDurationMs = metrics.totalDurationMs
                    self.lastSpokenVoiceLabel = "Apple \(metrics.voiceName) (\(metrics.voiceLanguage)) • \(metrics.voiceQuality) [\(metrics.voiceIdentifier)]"
                    self.lastSpokenText = metrics.spokenText
                } catch is CancellationError {
                    // Stopped by user
                } catch {
                    print("TTS Lab Apple playback error: \(error)")
                }
            }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        viewModel.kokoroTTS.stop()
        viewModel.appleTTS.stop()
        viewModel.ttsClient.stop()
        isPlaying = false
    }
}

#Preview {
    ContentView()
}
