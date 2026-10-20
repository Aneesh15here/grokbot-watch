import AVFoundation
import Foundation
import GrokBotCore
import Network
import Security
import SwiftUI
import WatchKit
import WidgetKit

@MainActor
final class AppPresenter: ObservableObject {
    @Published private(set) var snapshot: AppSnapshot
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        snapshot = model.snapshot
        model.onChange = { [weak self] in
            guard let self else { return }
            self.snapshot = self.model.snapshot
        }
        model.onActivity = { snapshot in
            WidgetBridge.publish(snapshot)
        }
    }
}

enum WidgetBridge {
    static func publish(_ snapshot: ActivitySnapshot) {
        guard let url = SharedLocations.activityURL(
            useAppGroup: AppGroupAccess.isEnabled(),
            appGroupID: AppGroupAccess.groupID()
        ) else { return }
        try? ActivityFile.write(snapshot, to: url)
        WidgetCenter.shared.reloadTimelines(ofKind: GrokBotAPI.widgetKind)
    }
}

struct KeychainSecretStore: SecretStoring {
    private var service: String {
        Bundle.main.bundleIdentifier ?? "com.aneesh15here.grokbotwatch"
    }

    func save(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    func load(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        "The watch Keychain could not store the key (\(status))."
    }
}

@MainActor
final class WatchSpeaker: SpeechSpeaking {
    private let synthesizer = AVSpeechSynthesizer()

    func enqueue(_ sentence: String, settings: VoiceSettings) {
        let utterance = AVSpeechUtterance(string: sentence)
        if let identifier = settings.voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: identifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: settings.localeIdentifier)
        }
        let scaled = AVSpeechUtteranceDefaultSpeechRate * Float(settings.rateMultiplier)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, scaled))
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

@MainActor
final class WatchHaptics: HapticPlaying {
    func play(_ cue: HapticCue) {
        switch cue {
        case .botFinished:
            WKInterfaceDevice.current().play(.success)
        case .messageQueued:
            WKInterfaceDevice.current().play(.click)
        case .failed:
            WKInterfaceDevice.current().play(.failure)
        }
    }
}

enum WatchDictation {
    /// Presents the watch text input controller.
    /// `nil` suggestions open dictation immediately. An empty array would show the
    /// keyboard, Scribble, and microphone list instead. A non-nil list shows those
    /// plus the suggestions. The Speech framework is not in the watchOS SDK.
    @MainActor
    @discardableResult
    static func capture(
        suggestions: [String]?,
        onResult: @escaping @MainActor (String?) -> Void
    ) -> Bool {
        guard let controller = WKApplication.shared().visibleInterfaceController else {
            return false
        }
        controller.presentTextInputController(
            withSuggestions: suggestions.map { Array<Any>($0) },
            allowedInputMode: .plain,
            completion: completion(onResult)
        )
        return true
    }

    /// WatchKit may call this off the main actor. Build it outside an isolated context.
    nonisolated static func completion(
        _ onResult: @escaping @MainActor (String?) -> Void
    ) -> @Sendable ([Any]?) -> Void {
        { results in
            let trimmed = (results?.first as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let text = (trimmed?.isEmpty == false) ? trimmed : nil
            Task { @MainActor in
                onResult(text)
            }
        }
    }
}

final class CallRuntime: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
    private var session: WKExtendedRuntimeSession?

    func start() {
        guard session?.state != .running && session?.state != .scheduled else { return }
        let session = WKExtendedRuntimeSession()
        session.delegate = self
        session.start()
        self.session = session
    }

    func stop() {
        session?.invalidate()
        session = nil
    }

    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {}

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        session = nil
    }
}

final class PathMonitor: ObservableObject {
    @Published private(set) var isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.grokbot.watch.network")
    var onChange: ((Bool) -> Void)?

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isOnline = online
                self?.onChange?(online)
            }
        }
        monitor.start(queue: queue)
    }
}
