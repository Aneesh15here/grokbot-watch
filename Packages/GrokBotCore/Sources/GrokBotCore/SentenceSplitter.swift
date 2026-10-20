import Foundation

struct SentenceSplitter: Equatable {
    private var buffer = ""
    private static let terminators: Set<Character> = [".", "!", "?", "。", "！", "？"]
    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "eg", "ie"]

    mutating func push(_ text: String) -> [String] {
        buffer.append(text)
        var sentences: [String] = []
        while let sentence = popSentence() {
            sentences.append(sentence)
        }
        return sentences
    }

    mutating func flush() -> String? {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder.isEmpty ? nil : remainder
    }

    private mutating func popSentence() -> String? {
        let characters = Array(buffer)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if Self.terminators.contains(character), isBoundary(characters, index: index), !isAbbreviation(characters, index: index) {
                let sentence = String(characters[0...index]).trimmingCharacters(in: .whitespacesAndNewlines)
                buffer = String(characters[(index + 1)...]).trimmingLeft()
                if !sentence.isEmpty {
                    return sentence
                }
                index = 0
                continue
            }
            index += 1
        }
        return nil
    }

    private func isBoundary(_ characters: [Character], index: Int) -> Bool {
        let character = characters[index]
        if character == "。" || character == "！" || character == "？" {
            return true
        }
        let next = index + 1
        if next >= characters.count {
            return true
        }
        let follower = characters[next]
        return follower.isWhitespace || follower == "\"" || follower == "”" || follower == "'" || follower == "’"
    }

    private func isAbbreviation(_ characters: [Character], index: Int) -> Bool {
        guard characters[index] == "." else { return false }
        return Self.abbreviations.contains(wordBefore(characters, index: index).lowercased())
    }

    private func wordBefore(_ characters: [Character], index: Int) -> String {
        var cursor = index - 1
        var word: [Character] = []
        while cursor >= 0, characters[cursor].isLetter {
            word.insert(characters[cursor], at: 0)
            cursor -= 1
        }
        return String(word)
    }
}

private extension String {
    func trimmingLeft() -> String {
        var copy = self
        while let first = copy.first, first.isWhitespace {
            copy.removeFirst()
        }
        return copy
    }
}
