import Foundation

public struct ActivitySnapshot: Codable, Equatable, Sendable {
    public var botName: String
    public var phase: ActivityPhase
    public var queuedCount: Int
    public var detail: String
    public var updatedAt: Date
    public var placeholder: Bool

    public init(
        botName: String,
        phase: ActivityPhase,
        queuedCount: Int,
        detail: String,
        updatedAt: Date,
        placeholder: Bool
    ) {
        self.botName = botName
        self.phase = phase
        self.queuedCount = queuedCount
        self.detail = detail
        self.updatedAt = updatedAt
        self.placeholder = placeholder
    }

    public static let placeholderSnapshot = ActivitySnapshot(
        botName: "Grok Bot",
        phase: .idle,
        queuedCount: 0,
        detail: "Open app",
        updatedAt: Date(timeIntervalSince1970: 0),
        placeholder: true
    )

    public var inlineText: String {
        if placeholder {
            return "Open Grok Bot"
        }
        return "\(botName) · \(detail)"
    }

    public var shortStatus: String {
        if placeholder {
            return "Open"
        }
        switch phase {
        case .working:
            return "Work"
        case .queued:
            return queuedCount > 0 ? "Q\(queuedCount)" : "Queue"
        case .idle:
            return "Idle"
        case .settling:
            return "Done"
        }
    }

    public var content: Content {
        Content(botName: botName, phase: phase, queuedCount: queuedCount, detail: detail, placeholder: placeholder)
    }

    public struct Content: Equatable, Sendable {
        public var botName: String
        public var phase: ActivityPhase
        public var queuedCount: Int
        public var detail: String
        public var placeholder: Bool
    }

    public static func phase(for turn: TurnStatus) -> ActivityPhase {
        if turn.inFlight {
            return .working
        }
        if turn.queued > 0 {
            return .queued
        }
        if turn.idle {
            return .idle
        }
        return .settling
    }

    public static func detail(phase: ActivityPhase, queuedCount: Int) -> String {
        switch phase {
        case .working:
            return "Working"
        case .queued:
            return queuedCount == 1 ? "Queued 1" : "Queued \(queuedCount)"
        case .idle:
            return "Idle"
        case .settling:
            return "Finishing"
        }
    }

    public static func prominent(rows: [BotRow], lastUsedName: String?, now: Date) -> ActivitySnapshot {
        let ranked = rows.sorted { lhs, rhs in
            rank(lhs.phase) > rank(rhs.phase)
        }
        let chosen = ranked.first { $0.phase == .working || $0.phase == .queued }
            ?? rows.first { $0.name == lastUsedName }
            ?? rows.first
        guard let chosen else {
            return placeholderSnapshot
        }
        let phase = chosen.phase
        return ActivitySnapshot(
            botName: chosen.name,
            phase: phase,
            queuedCount: chosen.queuedCount,
            detail: detail(phase: phase, queuedCount: chosen.queuedCount),
            updatedAt: now,
            placeholder: false
        )
    }

    private static func rank(_ phase: ActivityPhase) -> Int {
        switch phase {
        case .working:
            return 3
        case .queued:
            return 2
        case .settling:
            return 1
        case .idle:
            return 0
        }
    }
}

public enum ActivityFile {
    public static func write(_ snapshot: ActivitySnapshot, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> ActivitySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder.decode(ActivitySnapshot.self, from: data)
    }
}
