import Foundation

public struct PersistedState: Codable, Equatable, Sendable {
    public var schema: Int
    public var contacts: [BotContact]
    public var queue: [QueuedMessage]
    public var settings: AppSettings
    public var transcripts: [String: [TranscriptLine]]

    public init(
        schema: Int = 1,
        contacts: [BotContact],
        queue: [QueuedMessage],
        settings: AppSettings,
        transcripts: [String: [TranscriptLine]]
    ) {
        self.schema = schema
        self.contacts = contacts
        self.queue = queue
        self.settings = settings
        self.transcripts = transcripts
    }

    public static let empty = PersistedState(contacts: [], queue: [], settings: .initial, transcripts: [:])
}

public protocol StatePersisting: AnyObject {
    func load() -> PersistedState
    func save(_ state: PersistedState)
}

public final class MemoryStateStore: StatePersisting {
    public var state: PersistedState

    public init(state: PersistedState = .empty) {
        self.state = state
    }

    public func load() -> PersistedState { state }

    public func save(_ state: PersistedState) {
        self.state = state
    }
}

public final class FileStateStore: StatePersisting {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONCoding.decoder.decode(PersistedState.self, from: data)
        else {
            return .empty
        }
        return state
    }

    public func save(_ state: PersistedState) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONCoding.encoder.encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

public enum LaunchFile {
    public static func write(_ action: LaunchAction, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder.encode(action)
        try data.write(to: url, options: .atomic)
    }

    public static func consume(from url: URL) -> LaunchAction? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return try? JSONCoding.decoder.decode(LaunchAction.self, from: data)
    }
}

public enum SharedLocations {
    public static let appGroupID = "group.com.grokbot.watch"

    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        #if os(Linux)
        _ = fileManager
        return nil
        #else
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        #endif
    }

    public static func activityURL(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?.appendingPathComponent("activity.json")
    }

    public static func launchURL(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?.appendingPathComponent("launch.json")
    }

    public static func stateURL(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?.appendingPathComponent("state.json")
    }
}

public protocol SecretStoring: AnyObject {
    func save(_ value: String, account: String) throws
    func load(account: String) throws -> String?
    func delete(account: String) throws
}

public final class MemorySecretStore: SecretStoring {
    private var values: [String: String] = [:]

    public init() {}

    public func save(_ value: String, account: String) throws {
        values[account] = value
    }

    public func load(account: String) throws -> String? {
        values[account]
    }

    public func delete(account: String) throws {
        values[account] = nil
    }
}
