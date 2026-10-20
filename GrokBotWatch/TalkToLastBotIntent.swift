import AppIntents
import GrokBotCore

struct TalkToLastBotIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Last Grok Bot"
    static let description = IntentDescription("Open a call with the Grok Bot you used last.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        LaunchFlag.write()
        return .result(dialog: "Opening your last Grok Bot.")
    }
}

struct GrokBotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToLastBotIntent(),
            phrases: [
                "Talk to my last Grok Bot with \(.applicationName)",
                "Call my last bot with \(.applicationName)"
            ],
            shortTitle: "Talk to last bot",
            systemImageName: "waveform"
        )
    }
}
