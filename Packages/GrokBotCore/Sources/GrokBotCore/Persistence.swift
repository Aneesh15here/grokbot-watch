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
    /// `group.` plus `options.bundleIdPrefix` in project.yml.
    public static let appGroupID = "group.com.aneesh15here.grokbotwatch"

    public static func containerURL(
        appGroupID: String = SharedLocations.appGroupID,
        fileManager: FileManager = .default
    ) -> URL? {
        #if os(Linux)
        _ = (appGroupID, fileManager)
        return nil
        #else
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        #endif
    }

    /// Free Personal Team path returns nil. The complication then stays on its placeholder.
    public static func activityURL(
        useAppGroup: Bool = false,
        appGroupID: String = SharedLocations.appGroupID,
        fileManager: FileManager = .default
    ) -> URL? {
        sharedFile("activity.json", useAppGroup: useAppGroup, appGroupID: appGroupID, fileManager: fileManager)
    }

    public static func launchURL(
        useAppGroup: Bool = false,
        appGroupID: String = SharedLocations.appGroupID,
        fileManager: FileManager = .default
    ) -> URL? {
        sharedFile("launch.json", useAppGroup: useAppGroup, appGroupID: appGroupID, fileManager: fileManager)
    }

    public static func stateURL(
        useAppGroup: Bool = false,
        appGroupID: String = SharedLocations.appGroupID,
        fileManager: FileManager = .default
    ) -> URL? {
        sharedFile("state.json", useAppGroup: useAppGroup, appGroupID: appGroupID, fileManager: fileManager)
    }

    private static func sharedFile(
        _ name: String,
        useAppGroup: Bool,
        appGroupID: String,
        fileManager: FileManager
    ) -> URL? {
        guard useAppGroup else { return nil }
        return containerURL(appGroupID: appGroupID, fileManager: fileManager)?.appendingPathComponent(name)
    }
}

public enum AppGroupAccess {
    public static let useAppGroupInfoKey = "GrokBotUseAppGroup"
    public static let appGroupIDInfoKey = "GrokBotAppGroupID"

    public static func isEnabled(infoValue: Any?) -> Bool {
        switch infoValue {
        case let enabled as Bool:
            return enabled
        case let enabled as NSNumber:
            return enabled.boolValue
        case let enabled as String:
            switch enabled.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "yes", "true", "1":
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    public static func groupID(infoValue: Any?, fallback: String = SharedLocations.appGroupID) -> String {
        guard let raw = infoValue as? String else { return fallback }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return fallback }
        return trimmed
    }

    public static func isEnabled(bundle: Bundle = .main) -> Bool {
        isEnabled(infoValue: bundle.object(forInfoDictionaryKey: useAppGroupInfoKey))
    }

    public static func groupID(bundle: Bundle = .main) -> String {
        groupID(infoValue: bundle.object(forInfoDictionaryKey: appGroupIDInfoKey))
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
