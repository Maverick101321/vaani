import SwiftUI

struct ContentView: View {
    @State private var viewModel = VoiceAgentViewModel()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // MARK: - Header & Language Toggle
                    headerSection
                    
                    // MARK: - Current State Indicator
                    stateBadge
                    
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
            .frame(width: 170)
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
            Text("Latency Breakdown")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            
            HStack(spacing: 10) {
                latencyMetricPill(label: "STT", ms: viewModel.latency.sttMs)
                latencyMetricPill(label: "LLM", ms: viewModel.latency.llmMs)
                latencyMetricPill(label: "TTS", ms: viewModel.latency.ttsMs)
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

#Preview {
    ContentView()
}
