import Foundation

/// Client for the Grok Bot session API used by `@cursor/bdk` 0.2.27
/// (`cursor-grokbot-agents`). The routes and host come from that package's
/// `GrokBotAgentsBackend`, not from a guessed URL.
public enum GrokBotAPI {
    public static let defaultBaseURLString = "https://api.cursor.com"
    public static let clientType = "agent-serve"
    public static let credentialAccount = "cursor-api-key"
    public static let emptyTranscriptTail = "-1"
    public static let nameLimit = 255
    public static let sendMessageKind = "send-message"
    public static let minimumIdlePollsWithoutBusy = 4
    public static let defaultPollInterval: TimeInterval = 0.75
    public static let minimumPollInterval: TimeInterval = 0.4
    public static let maximumPollInterval: TimeInterval = 2
    public static let rosterPollInterval: TimeInterval = 5
    public static let createdWindow: TimeInterval = 60
    public static let requestTimeout: TimeInterval = 60
    public static let errorBodyLimit = 300
    public static let interruptReason = "Interrupted from the Grok Bot watch."
    public static let widgetKind = "com.grokbot.watch.bot-activity"

    public static func clampedPollInterval(_ value: TimeInterval) -> TimeInterval {
        min(maximumPollInterval, max(minimumPollInterval, value))
    }

    public static func validateName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            throw GrokBotClientError.invalidName("Enter the bot's name.")
        }
        if name.count > nameLimit {
            throw GrokBotClientError.invalidName("Bot names can be at most \(nameLimit) characters.")
        }
        return name
    }

    public static func createdBotWarning(name: String) -> String {
        "No Grok Bot named \"\(name)\" existed on this account, so an empty one was created. Check the name if that is unexpected."
    }

    public static func normalizeBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? defaultBaseURLString : trimmed
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil
        else {
            throw GrokBotClientError.insecureBaseURL(value)
        }
        let allowed = scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1"))
        guard allowed else {
            throw GrokBotClientError.insecureBaseURL(value)
        }
        var clean = URLComponents()
        clean.scheme = scheme
        clean.host = host
        clean.port = components.port
        guard let url = clean.url else {
            throw GrokBotClientError.insecureBaseURL(value)
        }
        return url
    }

    public static func sessionRequest(name: String, baseURL: URL, token: String, requestID: String) throws -> GrokBotRequest {
        let validated = try validateName(name)
        let url = try endpoint(baseURL: baseURL, sessionId: nil, suffix: nil, query: [])
        return GrokBotRequest(
            method: "POST",
            url: url,
            headers: headers(token: token, requestID: requestID, hasBody: true),
            body: try JSONCoding.encoder.encode(SessionBody(name: validated))
        )
    }

    public static func sendRequest(
        sessionId: String,
        text: String,
        messageId: String,
        baseURL: URL,
        token: String,
        requestID: String
    ) throws -> GrokBotRequest {
        let url = try endpoint(baseURL: baseURL, sessionId: sessionId, suffix: "messages", query: [])
        let body = SendBody(text: text, messageId: messageId)
        return GrokBotRequest(
            method: "POST",
            url: url,
            headers: headers(token: token, requestID: requestID, hasBody: true),
            body: try JSONCoding.encoder.encode(body)
        )
    }

    public static func entriesRequest(
        sessionId: String,
        afterUpdatedSeq: String,
        baseURL: URL,
        token: String,
        requestID: String
    ) throws -> GrokBotRequest {
        let url = try endpoint(
            baseURL: baseURL,
            sessionId: sessionId,
            suffix: "entries",
            query: [URLQueryItem(name: "afterUpdatedSeq", value: afterUpdatedSeq)]
        )
        return GrokBotRequest(
            method: "GET",
            url: url,
            headers: headers(token: token, requestID: requestID, hasBody: false),
            body: nil
        )
    }

    public static func interruptRequest(
        sessionId: String,
        reason: String,
        baseURL: URL,
        token: String,
        requestID: String
    ) throws -> GrokBotRequest {
        let url = try endpoint(baseURL: baseURL, sessionId: sessionId, suffix: "interrupt", query: [])
        return GrokBotRequest(
            method: "POST",
            url: url,
            headers: headers(token: token, requestID: requestID, hasBody: true),
            body: try JSONCoding.encoder.encode(InterruptBody(reason: reason))
        )
    }

    public static func decodeSession(_ data: Data) throws -> BotSession {
        let wire = try decode(SessionWire.self, from: data)
        return BotSession(
            sessionId: wire.id,
            name: wire.name,
            createdAtMs: wire.createdAtMs.value,
            latestUpdatedSeq: wire.latestUpdatedSeq
        )
    }

    public static func decodeSend(_ data: Data) throws -> SendReceipt {
        let wire = try decode(SendWire.self, from: data)
        guard let delivery = SendReceipt.Delivery(rawValue: wire.delivery) else {
            throw GrokBotClientError.unexpectedDelivery(wire.delivery)
        }
        return SendReceipt(messageId: wire.messageId, delivery: delivery)
    }

    public static func decodeEntries(_ data: Data) throws -> EntriesPage {
        let wire = try decode(EntriesWire.self, from: data)
        return EntriesPage(
            entries: wire.entries.map { entry in
                GrokBotEntry(
                    seq: entry.seq,
                    updatedSeq: entry.updatedSeq,
                    kind: entry.kind,
                    role: entry.role,
                    text: entry.text,
                    createdAtMs: entry.createdAtMs.value
                )
            },
            latestUpdatedSeq: wire.latestUpdatedSeq,
            turn: TurnStatus(idle: wire.turn.idle, inFlight: wire.turn.inFlight, queued: wire.turn.queued)
        )
    }

    public static func message(status: Int, body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        if let wire = try? JSONCoding.decoder.decode(ErrorWire.self, from: body) {
            if let error = wire.error, !error.isEmpty {
                return clip(error)
            }
            if let message = wire.message, !message.isEmpty {
                return clip(message)
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "The Grok Bot API returned HTTP \(status)."
        }
        return clip(trimmed)
    }

    static func endpoint(baseURL: URL, sessionId: String?, suffix: String?, query: [URLQueryItem]) throws -> URL {
        var url = baseURL
        url.appendPathComponent("v0")
        url.appendPathComponent("grokbot")
        url.appendPathComponent("sessions")
        if let sessionId {
            url.appendPathComponent(sessionId)
        }
        if let suffix {
            url.appendPathComponent(suffix)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GrokBotClientError.decoding("Could not build a Grok Bot URL.")
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let built = components.url else {
            throw GrokBotClientError.decoding("Could not build a Grok Bot URL.")
        }
        return built
    }

    private static func headers(token: String, requestID: String, hasBody: Bool) -> [String: String] {
        var headers = [
            "authorization": "Bearer \(token)",
            "x-cursor-client-type": clientType,
            "x-request-id": requestID
        ]
        if hasBody {
            headers["content-type"] = "application/json"
        }
        return headers
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONCoding.decoder.decode(type, from: data)
        } catch {
            throw GrokBotClientError.decoding("The Grok Bot API returned an unexpected payload.")
        }
    }

    private static func clip(_ text: String) -> String {
        if text.count <= errorBodyLimit {
            return text
        }
        return String(text.prefix(errorBodyLimit))
    }
}

public struct GrokBotRequest: Equatable, Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String], body: Data?) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public enum GrokBotClientError: Error, Equatable {
    case missingCredential
    case insecureBaseURL(String)
    case invalidName(String)
    case api(status: Int, message: String)
    case unexpectedDelivery(String)
    case transport(String)
    case decoding(String)

    public var shouldQueue: Bool {
        switch self {
        case .missingCredential, .insecureBaseURL, .invalidName, .unexpectedDelivery, .decoding:
            return false
        case .transport:
            return true
        case .api(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        }
    }
}

extension GrokBotClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingCredential:
            return "Add a Cursor API key in Settings. It stays in the watch Keychain."
        case .insecureBaseURL(let value):
            return "The API host must be https, or http on localhost. \(value) is not allowed."
        case .invalidName(let message):
            return message
        case .api(let status, let message):
            return "Grok Bot API \(status): \(message)"
        case .unexpectedDelivery(let delivery):
            return "The bot did not accept the message (delivery: \(delivery))."
        case .transport(let message):
            return message
        case .decoding(let message):
            return message
        }
    }
}

public enum SessionFreshness {
    public static func wasJustCreated(session: BotSession, now: Date, hadContact: Bool) -> Bool {
        guard !hadContact else { return false }
        guard session.latestUpdatedSeq == GrokBotAPI.emptyTranscriptTail else { return false }
        let created = Date(timeIntervalSince1970: TimeInterval(session.createdAtMs) / 1000)
        return created >= now.addingTimeInterval(-GrokBotAPI.createdWindow)
    }
}

enum JSONCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct LenientInt64: Decodable {
    var value: Int64

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int64.self) {
            value = intValue
            return
        }
        let doubleValue = try container.decode(Double.self)
        guard doubleValue.isFinite else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a number.")
        }
        value = Int64(doubleValue)
    }
}

private struct SessionBody: Encodable {
    var name: String
}

private struct SendBody: Encodable {
    var text: String
    var messageId: String
}

private struct InterruptBody: Encodable {
    var reason: String
}

private struct SessionWire: Decodable {
    var id: String
    var name: String
    var createdAtMs: LenientInt64
    var latestUpdatedSeq: String
}

private struct SendWire: Decodable {
    var messageId: String
    var delivery: String
}

private struct EntryWire: Decodable {
    var seq: String
    var updatedSeq: String
    var kind: String
    var role: String?
    var text: String?
    var createdAtMs: LenientInt64
}

private struct TurnWire: Decodable {
    var idle: Bool
    var inFlight: Bool
    var queued: Int
}

private struct EntriesWire: Decodable {
    var entries: [EntryWire]
    var latestUpdatedSeq: String
    var turn: TurnWire
}

private struct ErrorWire: Decodable {
    var error: String?
    var message: String?
}
