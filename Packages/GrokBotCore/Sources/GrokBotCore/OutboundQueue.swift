import Foundation

public struct QueuedMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var botName: String
    public var sessionId: String?
    public var text: String
    public var enqueuedAt: Date

    public init(id: String, botName: String, sessionId: String?, text: String, enqueuedAt: Date) {
        self.id = id
        self.botName = botName
        self.sessionId = sessionId
        self.text = text
        self.enqueuedAt = enqueuedAt
    }
}

public enum EnqueueResult: Equatable, Sendable {
    case queued
    case duplicate
    case full
}

public struct OutboundQueue: Codable, Equatable, Sendable {
    public static let limit = 50
    public private(set) var items: [QueuedMessage]

    public init(items: [QueuedMessage] = []) {
        self.items = items
    }

    public var count: Int { items.count }

    public func peek() -> QueuedMessage? { items.first }

    public mutating func enqueue(_ item: QueuedMessage) -> EnqueueResult {
        if items.contains(where: { $0.id == item.id }) {
            return .duplicate
        }
        if items.count >= Self.limit {
            return .full
        }
        items.append(item)
        return .queued
    }

    public mutating func remove(id: String) {
        items.removeAll { $0.id == id }
    }

    public mutating func stripSessionIDs() {
        items = items.map { item in
            var copy = item
            copy.sessionId = nil
            return copy
        }
    }
}
