import AVFoundation
import GrokBotCore
import SwiftUI

struct CallView: View {
    @ObservedObject var presenter: AppPresenter
    @State private var showingSwitch = false
    @State private var showingVoice = false
    @State private var showingType = false
    @State private var draft = ""
    @State private var dictationError: String?
    @State private var rateIndex: Double = 1
    @State private var dictating = false

    var body: some View {
        let snapshot = presenter.snapshot
        VStack(spacing: 6) {
            VStack(spacing: 2) {
                Text(snapshot.activeBotName ?? "Bot")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(snapshot.phase.title)
                    if snapshot.botWorking && snapshot.phase != .working {
                        Text("· working")
                    }
                }
                .font(.caption2)
                .foregroundStyle(statusColor)
            }
            .frame(maxWidth: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(snapshot.transcript.suffix(6)) { line in
                        Text(lineText(line, botName: snapshot.activeBotName))
                            .font(.caption2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let dictationError {
                        Text(dictationError)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            talkButton

            HStack {
                Button("Switch") { showingSwitch = true }
                    .accessibilityIdentifier("call.switch")
                Button("Voice") { showingVoice = true }
                    .accessibilityIdentifier("call.voice")
                Button("Type", action: beginTyping)
                    .disabled(dictating)
                    .accessibilityIdentifier("call.type")
                Button("End") { presenter.model.endCall() }
                    .accessibilityIdentifier("call.end")
            }
            .font(.caption2)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 6)
        .digitalCrownRotation(
            $rateIndex,
            from: 0,
            through: Double(VoiceSettings.ratePresets.count - 1),
            by: 1,
            sensitivity: .medium,
            isContinuous: false,
            isHapticFeedbackEnabled: true
        )
        .onAppear {
            rateIndex = Double(snapshot.settings.voice.nearestRateIndex)
        }
        .onChange(of: rateIndex) { _, newValue in
            let voice = presenter.snapshot.settings.voice.withRateIndex(Int(newValue.rounded()))
            presenter.model.updateVoice(voice)
        }
        .sheet(isPresented: $showingSwitch) {
            SwitchBotView(presenter: presenter)
        }
        .sheet(isPresented: $showingVoice) {
            VoiceSettingsView(presenter: presenter)
        }
        .sheet(isPresented: $showingType) {
            TypeMessageView(draft: $draft) {
                let text = draft
                draft = ""
                showingType = false
                Task { await presenter.model.submitUtterance(text) }
            }
        }
    }

    private var talkButton: some View {
        let listening = presenter.snapshot.phase == .listening || dictating
        return Button(action: beginDictation) {
            ZStack {
                Circle()
                    .fill(listening ? Color.green.opacity(0.9) : Color.accentColor)
                    .frame(width: 54, height: 54)
                Image(systemName: listening ? "waveform" : "mic.fill")
                    .font(.title3)
                    .foregroundStyle(.black)
            }
        }
        .buttonStyle(.plain)
        .disabled(dictating)
        .accessibilityIdentifier("call.talk")
        .accessibilityLabel("Dictate")
    }

    private func beginDictation() {
        guard !dictating else { return }
        dictating = true
        dictationError = nil
        presenter.model.setListening(true)
        let presented = WatchDictation.capture(suggestions: nil) { text in
            dictating = false
            Task { await presenter.model.submitUtterance(text ?? "") }
        }
        guard presented else {
            dictating = false
            presenter.model.setListening(false)
            dictationError = "Dictation is unavailable right now. Tap Type."
            return
        }
    }

    private func beginTyping() {
        guard !dictating else { return }
        dictationError = nil
        let presented = WatchDictation.capture(suggestions: ["Yes", "No", "Thanks", "Stop"]) { text in
            guard let text else { return }
            Task { await presenter.model.submitUtterance(text) }
        }
        if !presented {
            showingType = true
        }
    }

    private var statusColor: Color {
        switch presenter.snapshot.phase {
        case .listening:
            return .green
        case .working, .speaking:
            return .orange
        case .queuedOffline, .failed:
            return .yellow
        case .ready:
            return .secondary
        }
    }

    private func lineText(_ line: TranscriptLine, botName: String?) -> String {
        switch line.author {
        case .you:
            return "You: \(line.text)"
        case .bot:
            return "\(botName ?? "Bot"): \(line.text)"
        case .notice:
            return line.text
        }
    }
}

struct SwitchBotView: View {
    @ObservedObject var presenter: AppPresenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(presenter.snapshot.rows) { row in
            Button(row.name) {
                Task {
                    await presenter.model.switchBot(named: row.name)
                    dismiss()
                }
            }
        }
        .navigationTitle("Switch")
    }
}

struct VoiceSettingsView: View {
    @ObservedObject var presenter: AppPresenter

    var body: some View {
        let voice = presenter.snapshot.settings.voice
        List {
            Section("Language") {
                ForEach(VoiceSettings.locales) { locale in
                    Button {
                        var updated = voice
                        updated.localeIdentifier = locale.identifier
                        updated.voiceIdentifier = nil
                        presenter.model.updateVoice(updated)
                    } label: {
                        HStack {
                            Text(locale.label)
                            Spacer()
                            if voice.localeIdentifier == locale.identifier {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Section("Speed") {
                ForEach(Array(VoiceSettings.ratePresets.enumerated()), id: \.offset) { index, preset in
                    Button(label(for: preset)) {
                        presenter.model.updateVoice(voice.withRateIndex(index))
                    }
                }
            }
            Section("Voice") {
                ForEach(matchingVoices, id: \.identifier) { item in
                    Button(item.name) {
                        var updated = voice
                        updated.voiceIdentifier = item.identifier
                        presenter.model.updateVoice(updated)
                    }
                }
            }
            Text("The digital crown also changes speed during a call. Voice and speed stay on the watch.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .navigationTitle("Voice")
    }

    private var matchingVoices: [AVSpeechSynthesisVoice] {
        let language = String(presenter.snapshot.settings.voice.localeIdentifier.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(language) }
    }

    private func label(for preset: Double) -> String {
        VoiceSettings(localeIdentifier: "en-US", rateMultiplier: preset, voiceIdentifier: nil).rateLabel
    }
}

struct TypeMessageView: View {
    @Binding var draft: String
    var send: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            TextField("Message", text: $draft)
            Button("Send") { send() }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("call.sendTyped")
        }
        .padding(.horizontal, 4)
    }
}
