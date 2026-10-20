import Foundation

@MainActor
public final class AppModel {
    public var onChange: (() -> Void)?
    public var onActivity: ((ActivitySnapshot) -> Void)?

    private var transport: BotTransport
    private let speaker: SpeechSpeaking
    private let haptics: HapticPlaying
    private let store: StatePersisting
    private let sleeper: Sleeper
    private let now: () -> Date
    private let makeID: () -> String

    private var contacts: [BotContact]
    private var queue: OutboundQueue
    private var settings: AppSettings
    private var transcripts: [String: [TranscriptLine]]
    private var turns: [String: TurnStatus] = [:]
    private var activeSessionId: String?
    private var phase: CallPhase = .ready
    private var partial = ""
    private var warning: String?
    private var online: Bool
    private var pump: ReplyPump?
    private var awaitingFinish = false
    private var lastActivityContent: ActivitySnapshot.Content?

    public init(
        transport: BotTransport,
        speaker: SpeechSpeaking,
        haptics: HapticPlaying,
        store: StatePersisting,
        sleeper: Sleeper = TaskSleeper(),
        now: @escaping () -> Date = { Date() },
        makeID: @escaping () -> String = { UUID().uuidString },
        online: Bool = true
    ) {
        let persisted = store.load()
        self.transport = transport
        self.speaker = speaker
        self.haptics = haptics
        self.store = store
        self.sleeper = sleeper
        self.now = now
        self.makeID = makeID
        self.contacts = persisted.contacts
        self.queue = OutboundQueue(items: persisted.queue)
        self.settings = persisted.settings
        self.settings.pollInterval = GrokBotAPI.clampedPollInterval(persisted.settings.pollInterval)
        self.transcripts = persisted.transcripts
        self.online = online
    }

    public var snapshot: AppSnapshot {
        AppSnapshot(
            rows: rows,
            inCall: activeSessionId != nil,
            activeBotName: activeContact?.name,
            phase: phase,
            botWorking: activeTurn?.isBusy ?? false,
            transcript: activeSessionId.flatMap { transcripts[$0] } ?? [],
            partial: partial,
            warning: warning,
            queuedCount: queue.count,
            settings: settings
        )
    }

    public func run() async {
        while !Task.isCancelled {
            if activeSessionId != nil {
                await pollOnce()
                try? await sleeper.sleep(seconds: GrokBotAPI.clampedPollInterval(settings.pollInterval))
            } else {
                await refreshRoster()
                try? await sleeper.sleep(seconds: GrokBotAPI.rosterPollInterval)
            }
        }
    }

    public func seedDemoBots() async {
        for name in MockBotTransport.demoNames where !contacts.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            await addBot(named: name)
        }
    }

    public func addBot(named rawName: String) async {
        let name: String
        do {
            name = try GrokBotAPI.validateName(rawName)
        } catch {
            warning = error.localizedDescription
            finish()
            return
        }
        if contacts.contains(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
            finish()
            return
        }
        do {
            let session = try await transport.resolveSession(named: name)
            let created = SessionFreshness.wasJustCreated(session: session, now: now(), hadContact: false)
            contacts.append(
                BotContact(
                    name: session.name,
                    sessionId: session.sessionId,
                    cursor: session.latestUpdatedSeq,
                    createdAtMs: session.createdAtMs,
                    lastContactAt: now(),
                    freshlyCreated: created
                )
            )
            warning = created ? GrokBotAPI.createdBotWarning(name: session.name) : nil
        } catch {
            warning = error.localizedDescription
        }
        finish()
    }

    public func dismissWarning() {
        warning = nil
        for index in contacts.indices {
            contacts[index].freshlyCreated = false
        }
        finish()
    }

    public func report(_ message: String) {
        warning = message
        finish()
    }

    public func startCall(named name: String) async {
        guard let contact = find(name) else {
            warning = "Add \(name) before calling."
            finish()
            return
        }
        speaker.stop()
        activeSessionId = contact.sessionId
        settings.lastBotName = contact.name
        phase = .ready
        partial = ""
        pump = ReplyPump(cursor: contact.cursor, confirmIdle: false)
        awaitingFinish = false
        touchContact(contact.sessionId) 
        finish()
        await pollOnce()
    }

    public func switchBot(named name: String) async {
        guard activeSessionId != nil else {
            await startCall(named: name)
            return
        }
        guard find(name)?.sessionId != activeSessionId else { return }
        speaker.stop()
        awaitingFinish = false
        await startCall(named: name)
    }

    public func endCall() {
        speaker.stop()
        activeSessionId = nil
        pump = nil
        awaitingFinish = false
        partial = ""
        phase = .ready
        finish()
    }

    public func setListening(_ listening: Bool) {
        guard activeSessionId != nil else { return }
        if listening {
            speaker.stop()
            phase = .listening
            finish()
            return
        }
        if phase == .listening {
            phase = .ready
            finish()
        }
    }

    public func setPartial(_ text: String) {
        partial = text
        finish()
    }

    public func submitUtterance(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        partial = ""
        guard let contact = activeContact else {
            finish()
            return
        }
        guard !trimmed.isEmpty else {
            if phase == .listening {
                phase = .ready
            }
            finish()
            return
        }
        let message = QueuedMessage(
            id: makeID(),
            botName: contact.name,
            sessionId: contact.sessionId,
            text: trimmed,
            enqueuedAt: now()
        )
        append(TranscriptLine(id: message.id, author: .you, text: trimmed), sessionId: contact.sessionId)
        if !online {
            enqueue(message)
            phase = .queuedOffline
            finish()
            return
        }
        await deliver(message)
    }

    public func pollOnce() async {
        guard let sessionId = activeSessionId, let contact = contacts.first(where: { $0.sessionId == sessionId }) else {
            await refreshRoster()
            return
        }
        let page: EntriesPage
        do {
            page = try await transport.entries(sessionId: sessionId, afterUpdatedSeq: contact.cursor)
        } catch {
            handlePollError(error)
            return
        }
        apply(page, sessionId: sessionId)
        finish()
    }

    public func refreshRoster() async {
        for contact in contacts where contact.sessionId != activeSessionId {
            do {
                let page = try await transport.entries(sessionId: contact.sessionId, afterUpdatedSeq: contact.cursor)
                turns[contact.sessionId] = page.turn
            } catch {
                continue
            }
        }
        finish()
    }

    public func setOnline(_ online: Bool) async {
        self.online = online
        if online {
            await flushQueue()
        } else {
            finish()
        }
    }

    public func flushQueue() async {
        guard online else {
            finish()
            return
        }
        while let next = queue.peek() {
            let sessionId: String
            do {
                sessionId = try await resolveSessionId(for: next)
            } catch let error as GrokBotClientError where error.shouldQueue {
                warning = error.localizedDescription
                finish()
                return
            } catch {
                warning = error.localizedDescription
                finish()
                return
            }
            if turns[sessionId]?.isBusy == true {
                finish()
                return
            }
            do {
                _ = try await transport.send(sessionId: sessionId, text: next.text, messageId: next.id)
                queue.remove(id: next.id)
                if activeSessionId == sessionId {
                    awaitingFinish = true
                    phase = .working
                    let cursor = contacts.first(where: { $0.sessionId == sessionId })?.cursor ?? GrokBotAPI.emptyTranscriptTail
                    pump = ReplyPump(cursor: cursor, confirmIdle: true)
                }
            } catch let error as GrokBotClientError where error.shouldQueue {
                warning = error.localizedDescription
                finish()
                return
            } catch {
                warning = error.localizedDescription
                finish()
                return
            }
        }
        if phase == .queuedOffline {
            phase = activeSessionId == nil ? .ready : .working
        }
        finish()
    }

    public func updateVoice(_ voice: VoiceSettings) {
        settings.voice = voice
        finish()
    }

    public func updatePollInterval(_ interval: TimeInterval) {
        settings.pollInterval = GrokBotAPI.clampedPollInterval(interval)
        finish()
    }

    public func setUseMock(_ useMock: Bool) {
        guard settings.useMockTransport != useMock else { return }
        settings.useMockTransport = useMock
        contacts = []
        transcripts = [:]
        turns = [:]
        activeSessionId = nil
        pump = nil
        awaitingFinish = false
        phase = .ready
        queue = OutboundQueue()
        warning = "Transport changed. Add each bot again by its exact name."
        finish()
    }

    public func updateBaseURLString(_ value: String) {
        settings.baseURLString = value.trimmingCharacters(in: .whitespacesAndNewlines)
        finish()
    }

    public func replaceTransport(_ transport: BotTransport) {
        self.transport = transport
        finish()
    }

    public func consumeLaunch(_ action: LaunchAction?) async {
        switch LaunchPlan.make(action: action, lastBotName: settings.lastBotName) {
        case .roster:
            if action == .talkToLastBot {
                warning = "No last bot yet. Add one and call it once."
                finish()
            }
        case .call(let name):
            await startCall(named: name)
        }
    }

    private var rows: [BotRow] {
        contacts.map { contact in
            let turn = turns[contact.sessionId] ?? .idle
            let phase = ActivitySnapshot.phase(for: turn)
            return BotRow(
                name: contact.name,
                sessionId: contact.sessionId,
                phase: phase,
                queuedCount: turn.queued,
                isLastUsed: contact.name == settings.lastBotName,
                freshlyCreated: contact.freshlyCreated
            )
        }
    }

    private var activeContact: BotContact? {
        guard let activeSessionId else { return nil }
        return contacts.first { $0.sessionId == activeSessionId }
    }

    private var activeTurn: TurnStatus? {
        guard let activeSessionId else { return nil }
        return turns[activeSessionId]
    }

    private func deliver(_ message: QueuedMessage) async {
        guard let sessionId = message.sessionId else {
            enqueue(message)
            finish()
            return
        }
        phase = .working
        if turns[sessionId]?.isBusy == true {
            do {
                try await transport.interrupt(sessionId: sessionId, reason: GrokBotAPI.interruptReason)
                turns[sessionId] = .idle
            } catch let error as GrokBotClientError where error.shouldQueue {
                enqueue(message)
                phase = .queuedOffline
                finish()
                return
            } catch {
                warning = error.localizedDescription
                phase = .failed(error.localizedDescription)
                haptics.play(.failed)
                finish()
                return
            }
        }
        do {
            _ = try await transport.send(sessionId: sessionId, text: message.text, messageId: message.id)
            awaitingFinish = true
            let cursor = contacts.first(where: { $0.sessionId == sessionId })?.cursor ?? GrokBotAPI.emptyTranscriptTail
            pump = ReplyPump(cursor: cursor, confirmIdle: true)
            phase = .working
        } catch let error as GrokBotClientError where error.shouldQueue {
            enqueue(message)
            phase = .queuedOffline
        } catch {
            warning = error.localizedDescription
            phase = .failed(error.localizedDescription)
            haptics.play(.failed)
        }
        finish()
    }

    private func enqueue(_ message: QueuedMessage) {
        switch queue.enqueue(message) {
        case .queued:
            haptics.play(.messageQueued)
            append(
                TranscriptLine(id: "queue-\(message.id)", author: .notice, text: "Queued until the watch is online."),
                sessionId: message.sessionId ?? ""
            )
        case .duplicate:
            break
        case .full:
            warning = "The offline queue is full. Connect and let the queued messages send."
            haptics.play(.failed)
        }
    }

    private func resolveSessionId(for message: QueuedMessage) async throws -> String {
        if let sessionId = message.sessionId, contacts.contains(where: { $0.sessionId == sessionId }) {
            return sessionId
        }
        let session = try await transport.resolveSession(named: message.botName)
        if let index = contacts.firstIndex(where: { $0.name.compare(session.name, options: .caseInsensitive) == .orderedSame }) {
            contacts[index].sessionId = session.sessionId
            return session.sessionId
        }
        contacts.append(
            BotContact(
                name: session.name,
                sessionId: session.sessionId,
                cursor: session.latestUpdatedSeq,
                createdAtMs: session.createdAtMs,
                lastContactAt: now(),
                freshlyCreated: false
            )
        )
        return session.sessionId
    }

    private func apply(_ page: EntriesPage, sessionId: String) {
        guard let index = contacts.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        var state = pump ?? ReplyPump(cursor: contacts[index].cursor, confirmIdle: false)
        let step = state.consume(page)
        pump = state
        contacts[index].cursor = step.cursor
        turns[sessionId] = step.turn
        for notice in step.notices {
            append(TranscriptLine(id: makeID(), author: .notice, text: notice), sessionId: sessionId)
        }
        if !step.sentences.isEmpty {
            for sentence in step.sentences {
                append(TranscriptLine(id: makeID(), author: .bot, text: sentence), sessionId: sessionId)
                if phase != .listening, sessionId == activeSessionId {
                    speaker.enqueue(sentence, settings: settings.voice)
                }
            }
            if phase != .listening, sessionId == activeSessionId {
                phase = .speaking
            }
        }
        if step.turn.isBusy {
            awaitingFinish = true
            if phase != .listening && phase != .speaking && sessionId == activeSessionId {
                phase = .working
            }
        }
        if step.finished && awaitingFinish && sessionId == activeSessionId {
            haptics.play(.botFinished)
            awaitingFinish = false
            if phase != .listening {
                phase = .ready
            }
            pump?.confirmIdle = false
            pump?.sawBusy = false
            pump?.idlePolls = 0
        }
    }

    private func handlePollError(_ error: Error) {
        if let client = error as? GrokBotClientError, client.shouldQueue {
            warning = online ? client.localizedDescription : "The watch is offline. You can still talk. Messages wait on the watch."
            if !online && phase != .listening {
                phase = .ready
            }
        } else {
            warning = error.localizedDescription
            phase = .failed(error.localizedDescription)
            haptics.play(.failed)
        }
        finish()
    }

    private func append(_ line: TranscriptLine, sessionId: String) {
        guard !sessionId.isEmpty else { return }
        var lines = transcripts[sessionId] ?? []
        lines.append(line)
        if lines.count > 40 {
            lines.removeFirst(lines.count - 40)
        }
        transcripts[sessionId] = lines
    }

    private func find(_ name: String) -> BotContact? {
        contacts.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    private func touchContact(_ sessionId: String) {
        guard let index = contacts.firstIndex(where: { $0.sessionId == sessionId }) else { return }
        contacts[index].lastContactAt = now()
    }

    private func finish() {
        let snapshot = ActivitySnapshot.prominent(rows: rows, lastUsedName: settings.lastBotName, now: now())
        if snapshot.content != lastActivityContent {
            lastActivityContent = snapshot.content
            onActivity?(snapshot)
        }
        store.save(
            PersistedState(
                contacts: contacts,
                queue: queue.items,
                settings: settings,
                transcripts: transcripts
            )
        )
        onChange?()
    }
}
