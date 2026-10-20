import Foundation

public final class MockBotTransport: BotTransport {
    public static let demoNames = ["Plan Keeper", "Chief of Staff"]

    private struct Pending {
        var text: String
        var releaseAt: Date
    }

    private struct Bot {
        var session: BotSession
        var log: [GrokBotEntry]
        var pending: [Pending]
        var seenMessageIDs: Set<String>
        var nextSeq: Int
    }

    private var bots: [String: Bot] = [:]
    private var idsByName: [String: String] = [:]
    private let now: () -> Date
    private let replyDelay: TimeInterval
    public private(set) var sentMessageIDs: [String] = []

    public init(now: @escaping () -> Date = { Date() }, replyDelay: TimeInterval = 0.75) {
        self.now = now
        self.replyDelay = replyDelay
    }

    public static func demo(now: @escaping () -> Date = { Date() }) -> MockBotTransport {
        let transport = MockBotTransport(now: now)
        let origin = now()
        transport.install(
            name: "Plan Keeper",
            sessionId: "mock-plan-keeper",
            createdAtMs: Self.oldTimestamp(now: origin),
            pending: [
                Pending(text: "Still checking the forecast.", releaseAt: origin.addingTimeInterval(1.5)),
                Pending(text: "Skies clear after four.", releaseAt: origin.addingTimeInterval(2.25))
            ]
        )
        transport.install(
            name: "Chief of Staff",
            sessionId: "mock-chief-of-staff",
            createdAtMs: Self.oldTimestamp(now: origin),
            pending: []
        )
        return transport
    }

    public func resolveSession(named name: String) async throws -> BotSession {
        let validated = try GrokBotAPI.validateName(name)
        let key = validated.lowercased()
        if let sessionId = idsByName[key], let bot = bots[sessionId] {
            return bot.session
        }
        let moment = now()
        let session = BotSession(
            sessionId: "mock-\(UUID().uuidString)",
            name: validated,
            createdAtMs: Int64(moment.timeIntervalSince1970 * 1000),
            latestUpdatedSeq: GrokBotAPI.emptyTranscriptTail
        )
        bots[session.sessionId] = Bot(session: session, log: [], pending: [], seenMessageIDs: [], nextSeq: 1)
        idsByName[key] = session.sessionId
        return session
    }

    public func send(sessionId: String, text: String, messageId: String) async throws -> SendReceipt {
        guard var bot = bots[sessionId] else {
            throw GrokBotClientError.api(status: 404, message: "Unknown session")
        }
        if bot.seenMessageIDs.contains(messageId) {
            return SendReceipt(messageId: messageId, delivery: .duplicate)
        }
        bot.seenMessageIDs.insert(messageId)
        sentMessageIDs.append(messageId)
        let moment = now()
        let chunks = replyChunks(botName: bot.session.name, userText: text)
        bot.pending = chunks.enumerated().map { index, chunk in
            Pending(text: chunk, releaseAt: moment.addingTimeInterval(replyDelay * Double(index + 1)))
        }
        bots[sessionId] = bot
        return SendReceipt(messageId: messageId, delivery: .acceptedTemporal)
    }

    public func entries(sessionId: String, afterUpdatedSeq: String) async throws -> EntriesPage {
        guard var bot = bots[sessionId] else {
            throw GrokBotClientError.api(status: 404, message: "Unknown session")
        }
        releaseDue(into: &bot)
        bots[sessionId] = bot
        let fresh = entries(in: bot, after: afterUpdatedSeq)
        let tail = bot.log.last?.updatedSeq ?? GrokBotAPI.emptyTranscriptTail
        return EntriesPage(entries: fresh, latestUpdatedSeq: tail, turn: turn(for: bot))
    }

    public func interrupt(sessionId: String, reason: String) async throws {
        guard var bot = bots[sessionId] else {
            throw GrokBotClientError.api(status: 404, message: "Unknown session")
        }
        _ = reason
        bot.pending = []
        bots[sessionId] = bot
    }

    private func install(name: String, sessionId: String, createdAtMs: Int64, pending: [Pending]) {
        let session = BotSession(
            sessionId: sessionId,
            name: name,
            createdAtMs: createdAtMs,
            latestUpdatedSeq: GrokBotAPI.emptyTranscriptTail
        )
        bots[sessionId] = Bot(session: session, log: [], pending: pending, seenMessageIDs: [], nextSeq: 1)
        idsByName[name.lowercased()] = sessionId
    }

    private func releaseDue(into bot: inout Bot) {
        let moment = now()
        while let next = bot.pending.first, next.releaseAt <= moment {
            bot.pending.removeFirst()
            let seq = String(bot.nextSeq)
            bot.nextSeq += 1
            bot.log.append(
                GrokBotEntry(
                    seq: seq,
                    updatedSeq: seq,
                    kind: GrokBotAPI.sendMessageKind,
                    role: "assistant",
                    text: next.text,
                    createdAtMs: Int64(moment.timeIntervalSince1970 * 1000)
                )
            )
        }
        bot.session.latestUpdatedSeq = bot.log.last?.updatedSeq ?? GrokBotAPI.emptyTranscriptTail
    }

    private func entries(in bot: Bot, after cursor: String) -> [GrokBotEntry] {
        if cursor == GrokBotAPI.emptyTranscriptTail {
            return bot.log
        }
        guard let index = bot.log.firstIndex(where: { $0.updatedSeq == cursor }) else {
            return []
        }
        return Array(bot.log.dropFirst(index + 1))
    }

    private func turn(for bot: Bot) -> TurnStatus {
        if bot.pending.isEmpty {
            return .idle
        }
        return TurnStatus(idle: false, inFlight: true, queued: 0)
    }

    private func replyChunks(botName: String, userText: String) -> [String] {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "Got it.",
            "\(botName) will handle “\(trimmed)”."
        ]
    }

    private static func oldTimestamp(now: Date) -> Int64 {
        Int64(now.addingTimeInterval(-86_400 * 10).timeIntervalSince1970 * 1000)
    }
}
