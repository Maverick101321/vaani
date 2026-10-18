import SwiftUI

struct ContentView: View {
    @State private var viewModel = VoiceAgentViewModel()
    @State private var isShowingTTSLab = false
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // MARK: - Header & Language Toggle
                    headerSection
                    
                    // MARK: - Current State Indicator
                    stateBadge

                    sttLoadingBadge
                    
                    // MARK: - Cards (Transcript & Response)
                    cardsSection
                    
                    // MARK: - Latency Readout
                    latencySection
                    
                    // MARK: - Audio Visualizer & Mic Control
                    controlsSection
                    
                    if let error = viewModel.errorMessage {
                        errorBanner(error)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Vaani")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingTTSLab = true
                    } label: {
                        Label("TTS Lab", systemImage: "speaker.wave.2.bubble.left.fill")
                            .font(.subheadline.weight(.medium))
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
        VStack(spacing: 12) {
            HStack {
                Label("Voice Agent", systemImage: "waveform.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button {
                    isShowingTTSLab = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                        Text("TTS Lab")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                
                Picker("Language", selection: $viewModel.language) {
                    ForEach(VoiceAgentViewModel.Language.allCases) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 165)
            }
            
            if viewModel.language == .hinglish {
                HStack {
                    Text("Hinglish TTS:")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    
                    Picker("Hinglish TTS Strategy", selection: $viewModel.ttsStrategy) {
                        ForEach(TTSStrategy.allCases) { strategy in
                            Text(strategy.displayName).tag(strategy)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                    
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
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

    private var sttLoadingBadge: some View {
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
        .padding(.vertical, 7)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
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
                if viewModel.latency.ttsTotalDurationMs > 0 {
                    Text(String(format: "TTS Play: %.0f ms", viewModel.latency.ttsTotalDurationMs))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            
            HStack(spacing: 10) {
                latencyMetricPill(label: "STT", ms: viewModel.latency.sttMs)
                latencyMetricPill(label: "LLM", ms: viewModel.latency.llmMs)
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
    
    // MARK: - Animated Audio Visualizer & Mic Button
    
    private var controlsSection: some View {
        VStack(spacing: 20) {
            // Animated level meter while listening
            audioLevelMeter
                .frame(height: 64)
                .padding(.top, 8)
            
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
    @State private var selectedVoiceID: String = "" //Empty string = Auto (Best for Strategy)
    @State private var installedVoices: [TTSVoiceInfo] = []
    @State private var isPlaying: Bool = false
    @State private var firstAudioMs: Double?
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
                    // 1. Strategy Picker
                    strategyCard

                    // 2. Voice Picker
                    voicePickerCard

                    // 3. Text Input & Transliteration Preview
                    textInputCard

                    // 4. Play Button & Latency Readout
                    playbackAndMetricsCard

                    // 5. Preset Sentence Buttons
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
            installedVoices = AppleTTS.availableVoices()
        }
        .onDisappear {
            stopPlayback()
        }
    }

    // MARK: - Sections

    private var strategyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Hinglish Strategy", systemImage: "Character.bubble.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Picker("Strategy", selection: $viewModel.ttsStrategy) {
                ForEach(TTSStrategy.allCases) { strategy in
                    Text(strategy.displayName).tag(strategy)
                }
            }
            .pickerStyle(.segmented)

            Text(viewModel.ttsStrategy.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var voicePickerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Installed Voices", systemImage: "person.wave.2.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                Spacer()

                Text("\(installedVoices.count) voices")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Picker("Select Voice", selection: $selectedVoiceID) {
                Text(autoVoiceDescription).tag("")
                ForEach(installedVoices) { voice in
                    Text(voice.displayLabel).tag(voice.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var autoVoiceDescription: String {
        let pair = viewModel.ttsStrategy.languagePreference
        if let best = AppleTTS.bestVoiceInfo(primaryLanguage: pair.primary, fallbackLanguage: pair.fallback) {
            return "Auto (Best: \(best.displayLabel))"
        }
        return "Auto (Best for \(pair.primary))"
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

            if viewModel.ttsStrategy == .devanagariHiIN && !customText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Strategy C Heuristic Devanagari Preview:")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(HinglishTransliterator.transliterate(customText))
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

            HStack(spacing: 12) {
                metricBox(
                    title: "Time to First Audio",
                    value: firstAudioMs.map { String(format: "%.0f ms", $0) } ?? "--",
                    highlighted: true
                )

                metricBox(
                    title: "Total Duration",
                    value: totalDurationMs.map { String(format: "%.0f ms", $0) } ?? "--",
                    highlighted: false
                )
            }

            if let voiceLabel = lastSpokenVoiceLabel {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last Voice: \(voiceLabel)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let spoken = lastSpokenText {
                        Text("Spoken: \"\(spoken)\"")
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
                .font(.title3.weight(.bold).monospacedDigit())
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

        let chosenStrategy = viewModel.ttsStrategy
        let voiceOverride = selectedVoiceID.isEmpty ? nil : selectedVoiceID

        isPlaying = true
        firstAudioMs = nil
        totalDurationMs = nil

        playTask = Task {
            let appleTTS = (viewModel.ttsClient as? AppleTTS) ?? AppleTTS(hinglishStrategy: chosenStrategy)
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
                    strategyOverride: chosenStrategy,
                    voiceIdentifierOverride: voiceOverride
                )
                guard !Task.isCancelled else { return }
                self.firstAudioMs = metrics.firstAudioMs
                self.totalDurationMs = metrics.totalDurationMs
                self.lastSpokenVoiceLabel = "\(metrics.voiceName) (\(metrics.voiceLanguage)) • \(metrics.voiceQuality) [\(metrics.voiceIdentifier)]"
                self.lastSpokenText = metrics.spokenText
            } catch is CancellationError {
                // Stopped by user
            } catch {
                print("TTS Lab playback error: \(error)")
            }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        viewModel.ttsClient.stop()
        isPlaying = false
    }
}

#Preview {
    ContentView()
}
