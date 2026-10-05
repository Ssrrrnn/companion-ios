import Foundation

/// Presentation only: source history and voice identifiers remain unchanged.
struct ChatPiece: Identifiable {
    let source: Message
    let index: Int
    let text: String
    let count: Int
    var music: MusicShare? = nil
    var id: String { count == 1 ? source.id : "\(source.id):sentence:\(index)" }
    var anchor: String { index == 0 ? source.id : id }
    var message: Message { Message(id: id, role: source.role, text: text) }
    static func make(_ source: Message) -> [ChatPiece] {
        let parsed = QuotedText(source.text)
        let content = MusicShareContent(parsed.body)
        let sentences = content.body.isEmpty && !content.shares.isEmpty ? [] : (source.role == "assistant" ? SentenceText.split(content.body) : [content.body])
        let values: [(String, MusicShare?)] = sentences.map { ($0, nil) } + content.shares.map { ($0.markdown, $0) }
        return values.enumerated().map { index, value in
            let body = value.0
            let text: String
            if index == 0, let quote = parsed.quote {
                text = "[回复「\(parsed.author ?? "他")」]\n\(quote)\n[/回复]\n\(body)"
            } else { text = body }
            return ChatPiece(source: source, index: index, text: text, count: values.count, music: value.1)
        }
    }
}

/// Incremental presentation cache. Typing, audio ticks and unchanged history
/// must not split the entire conversation again for every visible row.
struct ChatRow: Identifiable {
    let piece: ChatPiece
    let startsGroup: Bool
    var id: String { piece.id }
}

struct ChatPresentationCache {
    private var entries: [String: (Message, [ChatPiece])] = [:]
    private(set) var splitCount = 0
    mutating func update(_ messages: [Message]) -> [ChatRow] {
        var retained: [String: (Message, [ChatPiece])] = [:]
        var rows: [ChatRow] = []
        var previousRole: String?
        for message in messages {
            let pieces: [ChatPiece]
            if let cached = entries[message.id], cached.0 == message { pieces = cached.1 }
            else { pieces = ChatPiece.make(message); splitCount += 1 }
            retained[message.id] = (message, pieces)
            for piece in pieces {
                rows.append(ChatRow(piece: piece, startsGroup: previousRole != message.role))
                previousRole = message.role
            }
        }
        entries = retained
        return rows
    }
}

enum SentenceText {
    static func split(_ text: String) -> [String] {
        let characters = Array(text)
        var parts: [String] = []
        var current = ""
        var i = 0
        let closers: Set<Character> = ["」", "』", "”", "’", "\"", "'", ")", "）", "】"]
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { parts.append(value) }
            current = ""
        }
        while i < characters.count {
            let character = characters[i]
            if character == "\n" { flush(); i += 1; continue }
            current.append(character)
            let next = i + 1 < characters.count ? characters[i + 1] : nil
            let chineseEnd = "。！？".contains(character)
            // Latin punctuation only ends a sentence at whitespace/end; keep URLs and decimals intact.
            let latinEnd = ".!?".contains(character) && (next == nil || next!.isWhitespace || closers.contains(next!))
            if chineseEnd || latinEnd {
                while i + 1 < characters.count && (closers.contains(characters[i + 1]) || "。！？!?".contains(characters[i + 1])) {
                    i += 1; current.append(characters[i])
                }
                flush()
            }
            i += 1
        }
        flush()
        return parts.isEmpty ? [text] : parts
    }
}
