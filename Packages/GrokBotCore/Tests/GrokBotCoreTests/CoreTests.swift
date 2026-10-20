import XCTest
@testable import GrokBotCore

final class SentenceSplitterTests: XCTestCase {
    func testSplitsOnSentenceBoundariesAndKeepsTheFirstSentenceFirst() {
        var splitter = SentenceSplitter()
        let sentences = splitter.push("Alpha sentence. Beta sentence.")
        XCTAssertEqual(sentences, ["Alpha sentence.", "Beta sentence."])
    }

    func testEmitsTheFirstSentenceBeforeTheRestArrives() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.push("Alpha sentence."), ["Alpha sentence."])
        XCTAssertEqual(splitter.push(" Beta sentence."), ["Beta sentence."])
    }

    func testDoesNotSplitAbbreviationsOrDecimals() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(
            splitter.push("Dr. Smith is here. Pi is 3.14 today."),
            ["Dr. Smith is here.", "Pi is 3.14 today."]
        )
    }

    func testSplitsCJKWithoutASpace() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.push("你好。下一句。"), ["你好。", "下一句。"])
    }
}

final class ReplyPumpTests: XCTestCase {
    func testSpeaksSendMessageSentencesAndIgnoresOtherKinds() {
        var pump = ReplyPump(cursor: "-1", confirmIdle: true)
        let step = pump.consume(
            EntriesPage(
                entries: [
                    GrokBotEntry(seq: "1", updatedSeq: "1", kind: "send-message", role: "assistant", text: "Alpha sentence. Beta sentence.", createdAtMs: 0),
                    GrokBotEntry(seq: "2", updatedSeq: "2", kind: "tool", role: nil, text: "searching", createdAtMs: 0)
                ],
                latestUpdatedSeq: "2",
                turn: TurnStatus(idle: false, inFlight: true, queued: 0)
            )
        )
        XCTAssertEqual(step.sentences, ["Alpha sentence.", "Beta sentence."])
        XCTAssertEqual(step.notices, ["searching"])
        XCTAssertFalse(step.finished)
    }

    func testDuplicateSequenceIsNotSpokenTwice() {
        var pump = ReplyPump(cursor: "-1", confirmIdle: false)
        let page = EntriesPage(
            entries: [GrokBotEntry(seq: "1", updatedSeq: "1", kind: "send-message", role: nil, text: "Alpha sentence.", createdAtMs: 0)],
            latestUpdatedSeq: "1",
            turn: TurnStatus(idle: false, inFlight: true, queued: 0)
        )
        XCTAssertEqual(pump.consume(page).sentences, ["Alpha sentence."])
        XCTAssertEqual(pump.consume(page).sentences, [])
    }

    func testConfirmIdleWaitsForFourQuietPollsUnlessTheTurnWasBusy() {
        var pump = ReplyPump(cursor: "-1", confirmIdle: true)
        let idle = EntriesPage(entries: [], latestUpdatedSeq: "-1", turn: .idle)
        for _ in 0..<3 {
            XCTAssertFalse(pump.consume(idle).finished)
        }
        XCTAssertTrue(pump.consume(idle).finished)

        var busy = ReplyPump(cursor: "-1", confirmIdle: true)
        _ = busy.consume(EntriesPage(entries: [], latestUpdatedSeq: "-1", turn: TurnStatus(idle: false, inFlight: true, queued: 1)))
        XCTAssertTrue(busy.consume(idle).finished)
    }
}

final class QueueAndActivityTests: XCTestCase {
    func testQueueKeepsOrderDedupesAndStopsAtTheLimit() {
        var queue = OutboundQueue()
        let first = QueuedMessage(id: "a", botName: "Plan Keeper", sessionId: "s", text: "one", enqueuedAt: Date(timeIntervalSince1970: 1))
        let second = QueuedMessage(id: "b", botName: "Plan Keeper", sessionId: "s", text: "two", enqueuedAt: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(queue.enqueue(first), .queued)
        XCTAssertEqual(queue.enqueue(first), .duplicate)
        XCTAssertEqual(queue.enqueue(second), .queued)
        XCTAssertEqual(queue.peek()?.id, "a")
        queue.remove(id: "a")
        XCTAssertEqual(queue.peek()?.id, "b")
        queue.stripSessionIDs()
        XCTAssertNil(queue.peek()?.sessionId)

        var full = OutboundQueue()
        for index in 0..<OutboundQueue.limit {
            XCTAssertEqual(
                full.enqueue(QueuedMessage(id: "\(index)", botName: "Bot", sessionId: nil, text: "t", enqueuedAt: Date())),
                .queued
            )
        }
        XCTAssertEqual(
            full.enqueue(QueuedMessage(id: "overflow", botName: "Bot", sessionId: nil, text: "t", enqueuedAt: Date())),
            .full
        )
    }

    func testProminentSnapshotPrefersAWorkingBot() {
        let rows = [
            BotRow(name: "Chief of Staff", sessionId: "1", phase: .idle, queuedCount: 0, isLastUsed: true, freshlyCreated: false),
            BotRow(name: "Plan Keeper", sessionId: "2", phase: .working, queuedCount: 2, isLastUsed: false, freshlyCreated: false)
        ]
        let snapshot = ActivitySnapshot.prominent(rows: rows, lastUsedName: "Chief of Staff", now: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(snapshot.botName, "Plan Keeper")
        XCTAssertEqual(snapshot.phase, .working)
        XCTAssertEqual(snapshot.inlineText, "Plan Keeper · Working")
        XCTAssertEqual(snapshot.shortStatus, "Work")
        XCTAssertEqual(ActivitySnapshot.prominent(rows: [], lastUsedName: nil, now: Date()).inlineText, "Open Grok Bot")
    }

    func testPhaseMappingIsExhaustiveForTurnFlags() {
        XCTAssertEqual(ActivitySnapshot.phase(for: TurnStatus(idle: false, inFlight: true, queued: 3)), .working)
        XCTAssertEqual(ActivitySnapshot.phase(for: TurnStatus(idle: false, inFlight: false, queued: 2)), .queued)
        XCTAssertEqual(ActivitySnapshot.detail(phase: .queued, queuedCount: 2), "Queued 2")
        XCTAssertEqual(ActivitySnapshot.phase(for: .idle), .idle)
        XCTAssertEqual(ActivitySnapshot.phase(for: TurnStatus(idle: false, inFlight: false, queued: 0)), .settling)
    }

    func testLaunchPlanUsesTheLastBot() {
        XCTAssertEqual(LaunchPlan.make(action: .talkToLastBot, lastBotName: "Plan Keeper"), .call("Plan Keeper"))
        XCTAssertEqual(LaunchPlan.make(action: .talkToLastBot, lastBotName: nil), .roster)
        XCTAssertEqual(LaunchPlan.make(action: nil, lastBotName: "Plan Keeper"), .roster)
    }

    func testActivityAndLaunchFilesRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let activityURL = directory.appendingPathComponent("activity.json")
        let launchURL = directory.appendingPathComponent("launch.json")
        let snapshot = ActivitySnapshot(
            botName: "Plan Keeper",
            phase: .queued,
            queuedCount: 1,
            detail: "Queued 1",
            updatedAt: Date(timeIntervalSince1970: 20),
            placeholder: false
        )
        try ActivityFile.write(snapshot, to: activityURL)
        XCTAssertEqual(ActivityFile.read(from: activityURL), snapshot)
        try LaunchFile.write(.talkToLastBot, to: launchURL)
        XCTAssertEqual(LaunchFile.consume(from: launchURL), .talkToLastBot)
        XCTAssertNil(LaunchFile.consume(from: launchURL))
        try? FileManager.default.removeItem(at: directory)
    }

    func testFreePersonalTeamSkipsTheAppGroup() {
        XCTAssertNil(SharedLocations.activityURL())
        XCTAssertNil(SharedLocations.launchURL())
        XCTAssertNil(SharedLocations.stateURL())
        XCTAssertEqual(
            SharedLocations.activityURL(useAppGroup: true),
            SharedLocations.containerURL()?.appendingPathComponent("activity.json")
        )
        XCTAssertEqual(SharedLocations.appGroupID, "group.com.aneesh15here.grokbotwatch")
        XCTAssertFalse(AppGroupAccess.isEnabled(infoValue: nil))
        XCTAssertFalse(AppGroupAccess.isEnabled(infoValue: "NO"))
        XCTAssertFalse(AppGroupAccess.isEnabled(infoValue: "$(GROKBOT_USE_APP_GROUP)"))
        XCTAssertTrue(AppGroupAccess.isEnabled(infoValue: "YES"))
        XCTAssertTrue(AppGroupAccess.isEnabled(infoValue: true))
        XCTAssertFalse(AppGroupAccess.isEnabled(infoValue: false))
        XCTAssertEqual(AppGroupAccess.groupID(infoValue: nil), SharedLocations.appGroupID)
        XCTAssertEqual(AppGroupAccess.groupID(infoValue: "$(GROKBOT_APP_GROUP_ID)"), SharedLocations.appGroupID)
        XCTAssertEqual(AppGroupAccess.groupID(infoValue: "  "), SharedLocations.appGroupID)
        XCTAssertEqual(AppGroupAccess.groupID(infoValue: "group.example.watch"), "group.example.watch")
    }
}

final class GrokBotHTTPTransportTests: XCTestCase {
    func testBuildsOnlyTheFourDocumentedRoutes() async throws {
        let http = CapturingHTTP()
        http.handler = { request in
            if request.url.path.hasSuffix("/entries") {
                return HTTPResponse(status: 200, body: Data(#"{"entries":[],"latestUpdatedSeq":"-1","turn":{"idle":true,"inFlight":false,"queued":0}}"#.utf8))
            }
            if request.url.path.hasSuffix("/messages") {
                return HTTPResponse(status: 200, body: Data(#"{"messageId":"m1","delivery":"accepted_temporal"}"#.utf8))
            }
            if request.url.path.hasSuffix("/interrupt") {
                return HTTPResponse(status: 202, body: Data())
            }
            return HTTPResponse(
                status: 200,
                body: Data(#"{"id":"ses_1","name":"Plan Keeper","createdAtMs":10,"latestUpdatedSeq":"-1"}"#.utf8)
            )
        }
        let transport = try TransportFactory.makeLive(
            token: "super-secret-token",
            baseURLString: "https://api.cursor.com",
            http: http,
            makeRequestID: { "req-1" }
        )
        let session = try await transport.resolveSession(named: "Plan Keeper")
        let receipt = try await transport.send(sessionId: session.sessionId, text: "Hello", messageId: "m1")
        let page = try await transport.entries(sessionId: session.sessionId, afterUpdatedSeq: "-1")
        try await transport.interrupt(sessionId: session.sessionId, reason: GrokBotAPI.interruptReason)
        XCTAssertEqual(receipt.delivery, .acceptedTemporal)
        XCTAssertEqual(page.turn, .idle)
        XCTAssertEqual(http.requests.map(\.method), ["POST", "POST", "GET", "POST"])
        XCTAssertEqual(
            http.requests.map { $0.url.path },
            [
                "/v0/grokbot/sessions",
                "/v0/grokbot/sessions/ses_1/messages",
                "/v0/grokbot/sessions/ses_1/entries",
                "/v0/grokbot/sessions/ses_1/interrupt"
            ]
        )
        let entries = try XCTUnwrap(URLComponents(url: http.requests[2].url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(entries.queryItems, [URLQueryItem(name: "afterUpdatedSeq", value: "-1")])
        for request in http.requests {
            XCTAssertEqual(request.headers["authorization"], "Bearer super-secret-token")
            XCTAssertEqual(request.headers["x-cursor-client-type"], "agent-serve")
            XCTAssertEqual(request.headers["x-request-id"], "req-1")
        }
        XCTAssertEqual(http.requests[0].headers["content-type"], "application/json")
        XCTAssertNil(http.requests[2].body)
        let sendBody = try JSONCoding.decoder.decode(SendProbe.self, from: XCTUnwrap(http.requests[1].body))
        XCTAssertEqual(sendBody.text, "Hello")
        XCTAssertEqual(sendBody.messageId, "m1")
        let interruptBody = try JSONCoding.decoder.decode(InterruptProbe.self, from: XCTUnwrap(http.requests[3].body))
        XCTAssertEqual(interruptBody.reason, GrokBotAPI.interruptReason)
    }

    func testRejectsUnexpectedDeliveryAndDoesNotEchoTheToken() async throws {
        let http = CapturingHTTP()
        http.handler = { _ in
            HTTPResponse(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let transport = try TransportFactory.makeLive(
            token: "super-secret-token",
            baseURLString: "https://api.cursor.com",
            http: http,
            makeRequestID: { "r" }
        )
        do {
            _ = try await transport.resolveSession(named: "Plan Keeper")
            XCTFail("Expected an API error")
        } catch let error as GrokBotClientError {
            XCTAssertEqual(error, .api(status: 401, message: "unauthorized"))
            XCTAssertFalse(error.localizedDescription.contains("super-secret-token"))
            XCTAssertFalse(error.shouldQueue)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testDuplicateAndRejectedDeliveries() throws {
        let accepted = try GrokBotAPI.decodeSend(Data(#"{"messageId":"m","delivery":"duplicate"}"#.utf8))
        XCTAssertEqual(accepted.delivery, .duplicate)
        XCTAssertThrowsError(try GrokBotAPI.decodeSend(Data(#"{"messageId":"m","delivery":"dropped"}"#.utf8))) { error in
            XCTAssertEqual(error as? GrokBotClientError, .unexpectedDelivery("dropped"))
        }
    }

    func testBaseURLAndNameRules() throws {
        XCTAssertEqual(try GrokBotAPI.normalizeBaseURL("").absoluteString, "https://api.cursor.com")
        XCTAssertEqual(try GrokBotAPI.normalizeBaseURL("http://127.0.0.1:3000").absoluteString, "http://127.0.0.1:3000")
        XCTAssertThrowsError(try GrokBotAPI.normalizeBaseURL("http://bots.example.com"))
        XCTAssertThrowsError(try GrokBotAPI.normalizeBaseURL("https://api.cursor.com/v0/grokbot"))
        XCTAssertEqual(try GrokBotAPI.validateName("  Plan Keeper  "), "Plan Keeper")
        XCTAssertThrowsError(try GrokBotAPI.validateName(" "))
        XCTAssertThrowsError(try GrokBotAPI.validateName(String(repeating: "a", count: 256)))
        XCTAssertThrowsError(try TransportFactory.makeLive(token: "  ", baseURLString: "https://api.cursor.com", http: CapturingHTTP(), makeRequestID: { "r" })) { error in
            XCTAssertEqual(error as? GrokBotClientError, .missingCredential)
        }
    }

    func testCredentialComesFromTheSecretStore() throws {
        let secrets = MemorySecretStore()
        try secrets.save("key-from-keychain", account: GrokBotAPI.credentialAccount)
        let settings = AppSettings.initial
        let http = CapturingHTTP()
        let transport = try TransportFactory.liveTransport(secrets: secrets, settings: settings, http: http, makeRequestID: { "r" })
        XCTAssertEqual(transport.baseURL.absoluteString, "https://api.cursor.com")
        try secrets.delete(account: GrokBotAPI.credentialAccount)
        XCTAssertThrowsError(try TransportFactory.liveTransport(secrets: secrets, settings: settings, http: http, makeRequestID: { "r" }))
    }

    func testCreatedSessionWarningMatchesTheOfficialClient() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = BotSession(
            sessionId: "ses",
            name: "Typo",
            createdAtMs: Int64(now.timeIntervalSince1970 * 1000),
            latestUpdatedSeq: "-1"
        )
        XCTAssertTrue(SessionFreshness.wasJustCreated(session: fresh, now: now, hadContact: false))
        XCTAssertFalse(SessionFreshness.wasJustCreated(session: fresh, now: now, hadContact: true))
        var existing = fresh
        existing.latestUpdatedSeq = "4"
        XCTAssertFalse(SessionFreshness.wasJustCreated(session: existing, now: now, hadContact: false))
    }

    func testLongAPIErrorIsClipped() {
        let body = Data("{\"error\":\"\(String(repeating: "x", count: 500))\"}".utf8)
        let message = GrokBotAPI.message(status: 500, body: body)
        XCTAssertEqual(message.count, GrokBotAPI.errorBodyLimit)
        XCTAssertTrue(GrokBotClientError.api(status: 503, message: message).shouldQueue)
        XCTAssertFalse(GrokBotClientError.api(status: 400, message: "bad").shouldQueue)
    }
}

final class MockTransportTests: XCTestCase {
    func testDemoBotStaysWorkingUntilItsScheduledReply() async throws {
        let clock = ManualClock(date: Date(timeIntervalSince1970: 10_000))
        let mock = MockBotTransport.demo(now: { clock.date })
        let session = try await mock.resolveSession(named: "Plan Keeper")
        let first = try await mock.entries(sessionId: session.sessionId, afterUpdatedSeq: "-1")
        XCTAssertTrue(first.turn.inFlight)
        XCTAssertTrue(first.entries.isEmpty)
        clock.date = clock.date.addingTimeInterval(1.6)
        let second = try await mock.entries(sessionId: session.sessionId, afterUpdatedSeq: first.latestUpdatedSeq)
        XCTAssertEqual(second.entries.map(\.text), ["Still checking the forecast."])
        XCTAssertEqual(second.entries.first?.kind, "send-message")
        let duplicate = try await mock.send(sessionId: session.sessionId, text: "Hi", messageId: "m1")
        XCTAssertEqual(duplicate.delivery, .acceptedTemporal)
        let again = try await mock.send(sessionId: session.sessionId, text: "Hi", messageId: "m1")
        XCTAssertEqual(again.delivery, .duplicate)
        XCTAssertEqual(mock.sentMessageIDs, ["m1"])
        try await mock.interrupt(sessionId: session.sessionId, reason: "stop")
        let afterInterrupt = try await mock.entries(sessionId: session.sessionId, afterUpdatedSeq: second.latestUpdatedSeq)
        XCTAssertEqual(afterInterrupt.turn, .idle)
        XCTAssertTrue(afterInterrupt.entries.isEmpty)
    }
}

@MainActor
final class AppModelTests: XCTestCase {
    func testSpeaksTheFirstSentenceBeforeTheTurnSettles() async throws {
        let transport = ScriptedTransport()
        let speaker = RecordingSpeaker()
        let haptics = RecordingHaptics()
        let model = makeModel(transport: transport, speaker: speaker, haptics: haptics)
        transport.prepare(name: "Plan Keeper", pages: [
            .idle,
            .message("Alpha sentence.", inFlight: true),
            .message("Beta sentence.", inFlight: true),
            .idle
        ])
        await model.addBot(named: "Plan Keeper")
        await model.startCall(named: "Plan Keeper")
        await model.submitUtterance("Hello")
        XCTAssertTrue(speaker.sentences.isEmpty)
        XCTAssertTrue(haptics.cues.isEmpty)
        await model.pollOnce()
        XCTAssertEqual(speaker.sentences, ["Alpha sentence."])
        XCTAssertTrue(haptics.cues.isEmpty)
        XCTAssertEqual(model.snapshot.phase, .speaking)
        await model.pollOnce()
        XCTAssertEqual(speaker.sentences, ["Alpha sentence.", "Beta sentence."])
        await model.pollOnce()
        XCTAssertEqual(haptics.cues, [.botFinished])
        XCTAssertEqual(model.snapshot.phase, .ready)
    }

    func testOneDeliverySpeaksItsFirstSentenceBeforeIdleConfirmation() async throws {
        let transport = ScriptedTransport()
        let speaker = RecordingSpeaker()
        let haptics = RecordingHaptics()
        let model = makeModel(transport: transport, speaker: speaker, haptics: haptics)
        transport.prepare(name: "Plan Keeper", pages: [
            .idle,
            .message("Alpha sentence. Beta sentence.", inFlight: true),
            .idle
        ])
        await model.addBot(named: "Plan Keeper")
        await model.startCall(named: "Plan Keeper")
        await model.submitUtterance("Hello")
        await model.pollOnce()
        XCTAssertEqual(speaker.sentences, ["Alpha sentence.", "Beta sentence."])
        XCTAssertTrue(haptics.cues.isEmpty)
        await model.pollOnce()
        XCTAssertEqual(haptics.cues, [.botFinished])
    }

    func testOpeningAnIdleBotDoesNotHapticAndABusyBotDoesWhenItFinishes() async {
        let transport = ScriptedTransport()
        let haptics = RecordingHaptics()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: haptics)
        transport.prepare(name: "Chief of Staff", pages: [.idle, .idle])
        await model.addBot(named: "Chief of Staff")
        await model.startCall(named: "Chief of Staff")
        await model.pollOnce()
        XCTAssertTrue(haptics.cues.isEmpty)

        let working = ScriptedTransport()
        let workingHaptics = RecordingHaptics()
        let workingModel = makeModel(transport: working, speaker: RecordingSpeaker(), haptics: workingHaptics)
        working.prepare(name: "Plan Keeper", pages: [.working, .idle])
        await workingModel.addBot(named: "Plan Keeper")
        await workingModel.startCall(named: "Plan Keeper")
        XCTAssertTrue(workingHaptics.cues.isEmpty)
        XCTAssertTrue(workingModel.snapshot.botWorking)
        await workingModel.pollOnce()
        XCTAssertEqual(workingHaptics.cues, [.botFinished])
    }

    func testSendWaitsThroughQuietPollsWhenTheTurnNeverLooksBusy() async {
        let transport = ScriptedTransport()
        let haptics = RecordingHaptics()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: haptics)
        transport.prepare(name: "Plan Keeper", pages: [.idle, .idle, .idle, .idle, .idle, .idle])
        await model.addBot(named: "Plan Keeper")
        await model.startCall(named: "Plan Keeper")
        await model.submitUtterance("Hello")
        for _ in 0..<3 {
            await model.pollOnce()
            XCTAssertTrue(haptics.cues.isEmpty)
            XCTAssertEqual(model.snapshot.phase, .working)
        }
        await model.pollOnce()
        XCTAssertEqual(haptics.cues, [.botFinished])
    }

    func testSwitchingBotsDoesNotInterruptAndTheNextUtteranceGoesToTheNewBot() async throws {
        let transport = ScriptedTransport()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: RecordingHaptics())
        transport.prepare(name: "Plan Keeper", pages: [.working])
        transport.prepare(name: "Chief of Staff", pages: [.idle])
        await model.addBot(named: "Plan Keeper")
        await model.addBot(named: "Chief of Staff")
        await model.startCall(named: "Plan Keeper")
        await model.switchBot(named: "Chief of Staff")
        XCTAssertTrue(transport.events.filter { $0.hasPrefix("interrupt") }.isEmpty)
        XCTAssertEqual(model.snapshot.activeBotName, "Chief of Staff")
        await model.submitUtterance("Move it")
        let send = try XCTUnwrap(transport.events.last)
        XCTAssertTrue(send.contains("send:ses-Chief of Staff"))
        XCTAssertFalse(send.contains("ses-Plan Keeper"))
    }

    func testBusyUtteranceInterruptsBeforeSending() async throws {
        let transport = ScriptedTransport()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: RecordingHaptics())
        transport.prepare(name: "Plan Keeper", pages: [.working])
        await model.addBot(named: "Plan Keeper")
        await model.startCall(named: "Plan Keeper")
        await model.submitUtterance("Stop and do this")
        let barge = transport.events.filter { $0.hasPrefix("interrupt") || $0.hasPrefix("send") }
        XCTAssertEqual(barge.count, 2)
        XCTAssertEqual(barge[0], "interrupt:ses-Plan Keeper")
        XCTAssertTrue(barge[1].hasPrefix("send:ses-Plan Keeper:"))
    }

    func testOfflineUtteranceQueuesAndFlushesWithTheSameMessageID() async throws {
        let transport = ScriptedTransport()
        let haptics = RecordingHaptics()
        let store = MemoryStateStore()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: haptics, store: store)
        transport.prepare(name: "Plan Keeper", pages: [.idle])
        await model.addBot(named: "Plan Keeper")
        await model.startCall(named: "Plan Keeper")
        await model.setOnline(false)
        await model.submitUtterance("Remember this")
        XCTAssertTrue(transport.events.filter { $0.hasPrefix("send") }.isEmpty)
        XCTAssertEqual(model.snapshot.queuedCount, 1)
        XCTAssertEqual(model.snapshot.phase, .queuedOffline)
        XCTAssertEqual(haptics.cues, [.messageQueued])
        let queuedID = try XCTUnwrap(store.state.queue.first?.id)
        await model.setOnline(true)
        XCTAssertEqual(model.snapshot.queuedCount, 0)
        XCTAssertTrue(transport.events.contains("send:ses-Plan Keeper:\(queuedID)"))
    }

    func testFlushWaitsWhileTheBotIsBusy() async {
        let transport = ScriptedTransport()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: RecordingHaptics())
        transport.prepare(name: "Plan Keeper", pages: [.working])
        await model.addBot(named: "Plan Keeper")
        await model.startCall(named: "Plan Keeper")
        await model.setOnline(false)
        await model.submitUtterance("Later")
        await model.setOnline(true)
        XCTAssertEqual(model.snapshot.queuedCount, 1)
        XCTAssertTrue(transport.events.filter { $0.hasPrefix("send") }.isEmpty)
    }

    func testFreshNameWarnsThatAnEmptyBotWasCreated() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = ScriptedTransport()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: RecordingHaptics(), now: now)
        transport.prepared["typo"] = BotSession(
            sessionId: "ses-typo",
            name: "Typo",
            createdAtMs: Int64(now.timeIntervalSince1970 * 1000),
            latestUpdatedSeq: "-1"
        )
        await model.addBot(named: "Typo")
        XCTAssertEqual(model.snapshot.warning, GrokBotAPI.createdBotWarning(name: "Typo"))
        XCTAssertTrue(model.snapshot.rows.first?.freshlyCreated == true)
    }

    func testLaunchActionCallsTheLastBot() async {
        let transport = ScriptedTransport()
        let model = makeModel(transport: transport, speaker: RecordingSpeaker(), haptics: RecordingHaptics())
        transport.prepare(name: "Plan Keeper", pages: [.idle])
        await model.addBot(named: "Plan Keeper")
        await model.consumeLaunch(.talkToLastBot)
        XCTAssertFalse(model.snapshot.inCall)
        XCTAssertNotNil(model.snapshot.warning)
        await model.startCall(named: "Plan Keeper")
        model.endCall()
        await model.consumeLaunch(.talkToLastBot)
        XCTAssertTrue(model.snapshot.inCall)
        XCTAssertEqual(model.snapshot.activeBotName, "Plan Keeper")
    }

    func testVoiceRateAndPollIntervalStayInRange() {
        let model = makeModel(transport: ScriptedTransport(), speaker: RecordingSpeaker(), haptics: RecordingHaptics())
        model.updatePollInterval(0.01)
        XCTAssertEqual(model.snapshot.settings.pollInterval, GrokBotAPI.minimumPollInterval)
        model.updateVoice(VoiceSettings(localeIdentifier: "ja-JP", rateMultiplier: 1.15, voiceIdentifier: "Kyoko"))
        XCTAssertEqual(model.snapshot.settings.voice.localeIdentifier, "ja-JP")
        XCTAssertEqual(model.snapshot.settings.voice.rateLabel, "Fast")
    }

    private func makeModel(
        transport: ScriptedTransport,
        speaker: RecordingSpeaker,
        haptics: RecordingHaptics,
        store: MemoryStateStore = MemoryStateStore(),
        now: Date? = nil
    ) -> AppModel {
        AppModel(
            transport: transport,
            speaker: speaker,
            haptics: haptics,
            store: store,
            sleeper: ImmediateSleeper(),
            now: { now ?? Date(timeIntervalSince1970: 1_700_000_000) },
            makeID: {
                let count = store.state.queue.count + 1
                return "id-\(count)"
            },
            online: true
        )
    }
}

private struct SendProbe: Decodable {
    var text: String
    var messageId: String
}

private struct InterruptProbe: Decodable {
    var reason: String
}

final class ManualClock: @unchecked Sendable {
    var date: Date
    init(date: Date) { self.date = date }
}

final class CapturingHTTP: HTTPSending {
    var requests: [GrokBotRequest] = []
    var handler: (GrokBotRequest) -> HTTPResponse = { _ in HTTPResponse(status: 500, body: Data()) }

    func send(_ request: GrokBotRequest) async throws -> HTTPResponse {
        requests.append(request)
        return handler(request)
    }
}

final class RecordingSpeaker: SpeechSpeaking {
    var sentences: [String] = []
    func enqueue(_ sentence: String, settings: VoiceSettings) {
        sentences.append(sentence)
    }
    func stop() {}
}

final class RecordingHaptics: HapticPlaying {
    var cues: [HapticCue] = []
    func play(_ cue: HapticCue) {
        cues.append(cue)
    }
}

final class ScriptedTransport: BotTransport {
    var prepared: [String: BotSession] = [:]
    var pages: [String: [EntriesPage]] = [:]
    var events: [String] = []
    private var cursors: [String: Int] = [:]

    func prepare(name: String, pages: [EntriesPage]) {
        let session = BotSession(sessionId: "ses-\(name)", name: name, createdAtMs: 0, latestUpdatedSeq: "-1")
        prepared[name.lowercased()] = session
        self.pages[session.sessionId] = pages
    }

    func resolveSession(named name: String) async throws -> BotSession {
        let validated = try GrokBotAPI.validateName(name)
        if let session = prepared[validated.lowercased()] {
            return session
        }
        let session = BotSession(sessionId: "ses-\(validated)", name: validated, createdAtMs: 0, latestUpdatedSeq: "-1")
        prepared[validated.lowercased()] = session
        return session
    }

    func send(sessionId: String, text: String, messageId: String) async throws -> SendReceipt {
        events.append("send:\(sessionId):\(messageId)")
        return SendReceipt(messageId: messageId, delivery: .acceptedTemporal)
    }

    func entries(sessionId: String, afterUpdatedSeq: String) async throws -> EntriesPage {
        _ = afterUpdatedSeq
        events.append("entries:\(sessionId)")
        let list = pages[sessionId] ?? []
        let index = cursors[sessionId] ?? 0
        if index < list.count {
            cursors[sessionId] = index + 1
            return list[index]
        }
        return .idle
    }

    func interrupt(sessionId: String, reason: String) async throws {
        _ = reason
        events.append("interrupt:\(sessionId)")
    }
}

private extension EntriesPage {
    static let idle = EntriesPage(entries: [], latestUpdatedSeq: "-1", turn: .idle)
    static let working = EntriesPage(entries: [], latestUpdatedSeq: "-1", turn: TurnStatus(idle: false, inFlight: true, queued: 0))

    static func message(_ text: String, inFlight: Bool) -> EntriesPage {
        EntriesPage(
            entries: [GrokBotEntry(seq: text, updatedSeq: text, kind: "send-message", role: "assistant", text: text, createdAtMs: 0)],
            latestUpdatedSeq: text,
            turn: TurnStatus(idle: !inFlight, inFlight: inFlight, queued: 0)
        )
    }
}
