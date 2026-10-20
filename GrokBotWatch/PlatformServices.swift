import AVFoundation
import Foundation
import GrokBotCore
import Network
import Security
import Speech
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
        guard let url = SharedLocations.activityURL() else { return }
        try? ActivityFile.write(snapshot, to: url)
        WidgetCenter.shared.reloadTimelines(ofKind: GrokBotAPI.widgetKind)
    }
}

struct KeychainSecretStore: SecretStoring {
    private let service = "com.grokbot.watch"

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

@MainActor
final class WatchDictation: NSObject, ObservableObject {
    @Published private(set) var partial = ""
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()

    func begin(localeIdentifier: String) async throws {
        stopEngine()
        let granted = await Self.requestAccess()
        guard granted else {
            throw DictationError(message: "Speech recognition is off. Type the message instead.")
        }
        try configureSession()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw DictationError(message: "Speech recognition is unavailable. Type the message instead.")
        }
        recognizer.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        partial = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in
                self?.partial = text
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError(message: "The microphone is unavailable. Type the message instead.")
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func end() -> String {
        let text = partial
        stopEngine()
        partial = ""
        return text
    }

    private func stopEngine() {
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true)
    }

    private static func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}

struct DictationError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
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
