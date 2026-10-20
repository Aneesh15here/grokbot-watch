import GrokBotCore
import SwiftUI

@main
struct GrokBotWatchApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(presenter: WatchRuntime.presenter)
        }
    }
}

@MainActor
enum WatchRuntime {
    static let secrets = KeychainSecretStore()
    static let network = PathMonitor()
    static let presenter: AppPresenter = {
        let store = FileStateStore(url: stateURL())
        let settings = store.load().settings
        let model = AppModel(
            transport: makeTransport(settings: settings, secrets: secrets),
            speaker: WatchSpeaker(),
            haptics: WatchHaptics(),
            store: store
        )
        return AppPresenter(model: model)
    }()

    static func stateURL() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("state.json")
    }

    static func makeTransport(settings: AppSettings, secrets: SecretStoring) -> BotTransport {
        if settings.useMockTransport {
            return MockBotTransport.demo()
        }
        if let transport = try? TransportFactory.liveTransport(
            secrets: secrets,
            settings: settings,
            http: URLSessionHTTPClient(),
            makeRequestID: { UUID().uuidString }
        ) {
            return transport
        }
        return MissingCredentialTransport()
    }
}

enum LaunchFlag {
    static let key = "launch.talkToLastBot"

    static func write() {
        UserDefaults.standard.set(true, forKey: key)
        guard let url = sharedLaunchURL() else { return }
        try? LaunchFile.write(.talkToLastBot, to: url)
    }

    static func consume() -> LaunchAction? {
        let flagged = UserDefaults.standard.bool(forKey: key)
        if flagged {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if let url = sharedLaunchURL(), let action = LaunchFile.consume(from: url) {
            return action
        }
        return flagged ? .talkToLastBot : nil
    }

    private static func sharedLaunchURL() -> URL? {
        SharedLocations.launchURL(
            useAppGroup: AppGroupAccess.isEnabled(),
            appGroupID: AppGroupAccess.groupID()
        )
    }
}
