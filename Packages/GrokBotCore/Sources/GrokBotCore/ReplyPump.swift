import Foundation

struct ReplyPump: Equatable {
    var cursor: String
    var confirmIdle: Bool
    var sawBusy: Bool
    var idlePolls: Int
    var splitter: SentenceSplitter
    var seenSeqs: Set<String>

    init(cursor: String, confirmIdle: Bool) {
        self.cursor = cursor
        self.confirmIdle = confirmIdle
        self.sawBusy = false
        self.idlePolls = 0
        self.splitter = SentenceSplitter()
        self.seenSeqs = []
    }

    struct Step: Equatable {
        var sentences: [String]
        var notices: [String]
        var finished: Bool
        var turn: TurnStatus
        var cursor: String
    }

    mutating func consume(_ page: EntriesPage) -> Step {
        var sentences: [String] = []
        var notices: [String] = []
        for entry in page.entries {
            guard seenSeqs.insert(entry.seq).inserted else { continue }
            if entry.kind == GrokBotAPI.sendMessageKind, let text = entry.text, !text.isEmpty {
                sentences.append(contentsOf: splitter.push(text))
                if let tail = splitter.flush() {
                    sentences.append(tail)
                }
            } else if let text = entry.text, !text.isEmpty {
                notices.append(text)
            }
        }
        cursor = page.latestUpdatedSeq
        if page.turn.isBusy {
            sawBusy = true
        }
        var finished = false
        if page.entries.isEmpty && !page.turn.isBusy && page.turn.idle {
            idlePolls += 1
            let confirmed = sawBusy || !confirmIdle || idlePolls >= GrokBotAPI.minimumIdlePollsWithoutBusy
            if confirmed {
                finished = true
                if let tail = splitter.flush() {
                    sentences.append(tail)
                }
            }
        } else if !page.entries.isEmpty {
            idlePolls = 0
        }
        return Step(sentences: sentences, notices: notices, finished: finished, turn: page.turn, cursor: cursor)
    }
}
