import Foundation

public struct BotSession: Equatable, Sendable {
    public var sessionId: String
    public var name: String
    public var createdAtMs: Int64
    public var latestUpdatedSeq: String

    public init(sessionId: String, name: String, createdAtMs: Int64, latestUpdatedSeq: String) {
        self.sessionId = sessionId
        self.name = name
        self.createdAtMs = createdAtMs
        self.latestUpdatedSeq = latestUpdatedSeq
    }
}

public struct GrokBotEntry: Equatable, Sendable {
    public var seq: String
    public var updatedSeq: String
    public var kind: String
    public var role: String?
    public var text: String?
    public var createdAtMs: Int64

    public init(seq: String, updatedSeq: String, kind: String, role: String?, text: String?, createdAtMs: Int64) {
        self.seq = seq
        self.updatedSeq = updatedSeq
        self.kind = kind
        self.role = role
        self.text = text
        self.createdAtMs = createdAtMs
    }
}

public struct TurnStatus: Equatable, Sendable {
    public var idle: Bool
    public var inFlight: Bool
    public var queued: Int

    public init(idle: Bool, inFlight: Bool, queued: Int) {
        self.idle = idle
        self.inFlight = inFlight
        self.queued = queued
    }

    public static let idle = TurnStatus(idle: true, inFlight: false, queued: 0)

    public var isBusy: Bool {
        inFlight || queued > 0
    }
}

public struct EntriesPage: Equatable, Sendable {
    public var entries: [GrokBotEntry]
    public var latestUpdatedSeq: String
    public var turn: TurnStatus

    public init(entries: [GrokBotEntry], latestUpdatedSeq: String, turn: TurnStatus) {
        self.entries = entries
        self.latestUpdatedSeq = latestUpdatedSeq
        self.turn = turn
    }
}

public struct SendReceipt: Equatable, Sendable {
    public var messageId: String
    public var delivery: Delivery

    public init(messageId: String, delivery: Delivery) {
        self.messageId = messageId
        self.delivery = delivery
    }

    public enum Delivery: String, Equatable, Sendable {
        case acceptedTemporal = "accepted_temporal"
        case duplicate
    }
}

public struct BotContact: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionId }
    public var name: String
    public var sessionId: String
    public var cursor: String
    public var createdAtMs: Int64
    public var lastContactAt: Date
    public var freshlyCreated: Bool

    public init(
        name: String,
        sessionId: String,
        cursor: String,
        createdAtMs: Int64,
        lastContactAt: Date,
        freshlyCreated: Bool
    ) {
        self.name = name
        self.sessionId = sessionId
        self.cursor = cursor
        self.createdAtMs = createdAtMs
        self.lastContactAt = lastContactAt
        self.freshlyCreated = freshlyCreated
    }
}

public struct VoiceLocale: Equatable, Identifiable, Sendable {
    public var id: String { identifier }
    public var identifier: String
    public var label: String

    public init(identifier: String, label: String) {
        self.identifier = identifier
        self.label = label
    }
}

public struct VoiceSettings: Codable, Equatable, Sendable {
    public var localeIdentifier: String
    public var rateMultiplier: Double
    public var voiceIdentifier: String?

    public init(localeIdentifier: String, rateMultiplier: Double, voiceIdentifier: String?) {
        self.localeIdentifier = localeIdentifier
        self.rateMultiplier = rateMultiplier
        self.voiceIdentifier = voiceIdentifier
    }

    public static let initial = VoiceSettings(localeIdentifier: "en-US", rateMultiplier: 1, voiceIdentifier: nil)

    public static let locales: [VoiceLocale] = [
        VoiceLocale(identifier: "en-US", label: "English"),
        VoiceLocale(identifier: "es-ES", label: "Spanish"),
        VoiceLocale(identifier: "fr-FR", label: "French"),
        VoiceLocale(identifier: "de-DE", label: "German"),
        VoiceLocale(identifier: "pt-BR", label: "Portuguese"),
        VoiceLocale(identifier: "ja-JP", label: "Japanese"),
        VoiceLocale(identifier: "zh-CN", label: "Chinese")
    ]

    public static let ratePresets: [Double] = [0.85, 1.0, 1.15, 1.35]

    public var rateLabel: String {
        switch nearestRateIndex {
        case 0:
            return "Slow"
        case 1:
            return "Normal"
        case 2:
            return "Fast"
        default:
            return "Faster"
        }
    }

    public var nearestRateIndex: Int {
        let presets = Self.ratePresets
        var best = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for index in presets.indices {
            let distance = abs(presets[index] - rateMultiplier)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    public func withRateIndex(_ index: Int) -> VoiceSettings {
        var copy = self
        let clamped = min(max(0, index), Self.ratePresets.count - 1)
        copy.rateMultiplier = Self.ratePresets[clamped]
        return copy
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var useMockTransport: Bool
    public var pollInterval: TimeInterval
    public var voice: VoiceSettings
    public var lastBotName: String?

    public init(
        baseURLString: String,
        useMockTransport: Bool,
        pollInterval: TimeInterval,
        voice: VoiceSettings,
        lastBotName: String?
    ) {
        self.baseURLString = baseURLString
        self.useMockTransport = useMockTransport
        self.pollInterval = pollInterval
        self.voice = voice
        self.lastBotName = lastBotName
    }

    public static let initial = AppSettings(
        baseURLString: GrokBotAPI.defaultBaseURLString,
        useMockTransport: true,
        pollInterval: GrokBotAPI.defaultPollInterval,
        voice: .initial,
        lastBotName: nil
    )
}

public enum TranscriptAuthor: String, Codable, Equatable, Sendable {
    case you
    case bot
    case notice
}

public struct TranscriptLine: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var author: TranscriptAuthor
    public var text: String

    public init(id: String, author: TranscriptAuthor, text: String) {
        self.id = id
        self.author = author
        self.text = text
    }
}

public enum CallPhase: Equatable, Sendable {
    case ready
    case listening
    case working
    case speaking
    case queuedOffline
    case failed(String)

    public var title: String {
        switch self {
        case .ready:
            return "Ready"
        case .listening:
            return "Listening"
        case .working:
            return "Working"
        case .speaking:
            return "Speaking"
        case .queuedOffline:
            return "Queued"
        case .failed:
            return "Problem"
        }
    }
}

public enum ActivityPhase: String, Codable, Equatable, Sendable {
    case working
    case queued
    case idle
    case settling

    public var detail: String {
        switch self {
        case .working:
            return "Working"
        case .queued:
            return "Queued"
        case .idle:
            return "Idle"
        case .settling:
            return "Finishing"
        }
    }

    public var symbolName: String {
        switch self {
        case .working:
            return "ellipsis.circle.fill"
        case .queued:
            return "clock.fill"
        case .idle:
            return "waveform"
        case .settling:
            return "hourglass"
        }
    }
}

public enum HapticCue: Equatable, Sendable {
    case botFinished
    case messageQueued
    case failed
}

public enum LaunchAction: String, Codable, Equatable, Sendable {
    case talkToLastBot
}

public enum LaunchPlan: Equatable, Sendable {
    case roster
    case call(String)

    public static func make(action: LaunchAction?, lastBotName: String?) -> LaunchPlan {
        guard let action else { return .roster }
        switch action {
        case .talkToLastBot:
            guard let lastBotName, !lastBotName.isEmpty else { return .roster }
            return .call(lastBotName)
        }
    }
}

public struct BotRow: Equatable, Identifiable, Sendable {
    public var id: String { sessionId }
    public var name: String
    public var sessionId: String
    public var phase: ActivityPhase
    public var queuedCount: Int
    public var isLastUsed: Bool
    public var freshlyCreated: Bool

    public init(
        name: String,
        sessionId: String,
        phase: ActivityPhase,
        queuedCount: Int,
        isLastUsed: Bool,
        freshlyCreated: Bool
    ) {
        self.name = name
        self.sessionId = sessionId
        self.phase = phase
        self.queuedCount = queuedCount
        self.isLastUsed = isLastUsed
        self.freshlyCreated = freshlyCreated
    }
}

public struct AppSnapshot: Equatable, Sendable {
    public var rows: [BotRow]
    public var inCall: Bool
    public var activeBotName: String?
    public var phase: CallPhase
    public var botWorking: Bool
    public var transcript: [TranscriptLine]
    public var partial: String
    public var warning: String?
    public var queuedCount: Int
    public var settings: AppSettings

    public init(
        rows: [BotRow],
        inCall: Bool,
        activeBotName: String?,
        phase: CallPhase,
        botWorking: Bool,
        transcript: [TranscriptLine],
        partial: String,
        warning: String?,
        queuedCount: Int,
        settings: AppSettings
    ) {
        self.rows = rows
        self.inCall = inCall
        self.activeBotName = activeBotName
        self.phase = phase
        self.botWorking = botWorking
        self.transcript = transcript
        self.partial = partial
        self.warning = warning
        self.queuedCount = queuedCount
        self.settings = settings
    }
}
