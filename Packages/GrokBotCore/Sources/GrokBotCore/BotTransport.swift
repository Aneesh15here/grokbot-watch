import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol BotTransport: AnyObject {
    func resolveSession(named name: String) async throws -> BotSession
    func send(sessionId: String, text: String, messageId: String) async throws -> SendReceipt
    func entries(sessionId: String, afterUpdatedSeq: String) async throws -> EntriesPage
    func interrupt(sessionId: String, reason: String) async throws
}

public protocol HTTPSending: AnyObject {
    func send(_ request: GrokBotRequest) async throws -> HTTPResponse
}

public struct HTTPResponse: Equatable, Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol SpeechSpeaking: AnyObject {
    func enqueue(_ sentence: String, settings: VoiceSettings)
    func stop()
}

public protocol HapticPlaying: AnyObject {
    func play(_ cue: HapticCue)
}

public protocol Sleeper: AnyObject {
    func sleep(seconds: TimeInterval) async throws
}

public final class TaskSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        let nanoseconds = UInt64((seconds * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

public final class ImmediateSleeper: Sleeper {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {}
}

public final class URLSessionHTTPClient: HTTPSending {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: GrokBotRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = GrokBotAPI.requestTimeout
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return HTTPResponse(status: status, body: data)
        } catch let error as GrokBotClientError {
            throw error
        } catch {
            throw GrokBotClientError.transport(error.localizedDescription)
        }
    }
}

public final class MissingCredentialTransport: BotTransport {
    public init() {}

    public func resolveSession(named name: String) async throws -> BotSession {
        _ = try GrokBotAPI.validateName(name)
        throw GrokBotClientError.missingCredential
    }

    public func send(sessionId: String, text: String, messageId: String) async throws -> SendReceipt {
        _ = (sessionId, text, messageId)
        throw GrokBotClientError.missingCredential
    }

    public func entries(sessionId: String, afterUpdatedSeq: String) async throws -> EntriesPage {
        _ = (sessionId, afterUpdatedSeq)
        throw GrokBotClientError.missingCredential
    }

    public func interrupt(sessionId: String, reason: String) async throws {
        _ = (sessionId, reason)
        throw GrokBotClientError.missingCredential
    }
}

public final class GrokBotHTTPTransport: BotTransport {
    public let baseURL: URL
    private let token: String
    private let http: HTTPSending
    private let makeRequestID: () -> String

    public init(baseURL: URL, token: String, http: HTTPSending, makeRequestID: @escaping () -> String) {
        self.baseURL = baseURL
        self.token = token
        self.http = http
        self.makeRequestID = makeRequestID
    }

    public func resolveSession(named name: String) async throws -> BotSession {
        let request = try GrokBotAPI.sessionRequest(name: name, baseURL: baseURL, token: token, requestID: makeRequestID())
        let body = try await perform(request)
        return try GrokBotAPI.decodeSession(body)
    }

    public func send(sessionId: String, text: String, messageId: String) async throws -> SendReceipt {
        let request = try GrokBotAPI.sendRequest(
            sessionId: sessionId,
            text: text,
            messageId: messageId,
            baseURL: baseURL,
            token: token,
            requestID: makeRequestID()
        )
        let body = try await perform(request)
        return try GrokBotAPI.decodeSend(body)
    }

    public func entries(sessionId: String, afterUpdatedSeq: String) async throws -> EntriesPage {
        let request = try GrokBotAPI.entriesRequest(
            sessionId: sessionId,
            afterUpdatedSeq: afterUpdatedSeq,
            baseURL: baseURL,
            token: token,
            requestID: makeRequestID()
        )
        let body = try await perform(request)
        return try GrokBotAPI.decodeEntries(body)
    }

    public func interrupt(sessionId: String, reason: String) async throws {
        let request = try GrokBotAPI.interruptRequest(
            sessionId: sessionId,
            reason: reason,
            baseURL: baseURL,
            token: token,
            requestID: makeRequestID()
        )
        _ = try await perform(request, allowEmpty: true)
    }

    private func perform(_ request: GrokBotRequest, allowEmpty: Bool = false) async throws -> Data {
        let response = try await http.send(request)
        guard (200...299).contains(response.status) else {
            throw GrokBotClientError.api(status: response.status, message: GrokBotAPI.message(status: response.status, body: response.body))
        }
        if allowEmpty && response.body.isEmpty {
            return Data("{}".utf8)
        }
        return response.body
    }
}

public enum TransportFactory {
    public static func makeLive(
        token: String,
        baseURLString: String,
        http: HTTPSending,
        makeRequestID: @escaping () -> String
    ) throws -> GrokBotHTTPTransport {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GrokBotClientError.missingCredential
        }
        let baseURL = try GrokBotAPI.normalizeBaseURL(baseURLString)
        return GrokBotHTTPTransport(baseURL: baseURL, token: trimmed, http: http, makeRequestID: makeRequestID)
    }

    public static func liveTransport(
        secrets: SecretStoring,
        settings: AppSettings,
        http: HTTPSending,
        makeRequestID: @escaping () -> String
    ) throws -> GrokBotHTTPTransport {
        let token = try secrets.load(account: GrokBotAPI.credentialAccount) ?? ""
        return try makeLive(token: token, baseURLString: settings.baseURLString, http: http, makeRequestID: makeRequestID)
    }
}
