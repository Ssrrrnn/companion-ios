import Foundation

enum ReadingLimits {
    static let fileBytes = 200 * 1024 * 1024
    static let characters = 20_000_000
    static let description = "最多 200 MB、2000 万字"
}

/// Decodes bounded byte chunks, retaining incomplete code points and the last
/// grapheme so UTF-8/UTF-16, combining marks and joined emoji cross chunks intact.
struct ReadingUTFDecoder {
    private var bytes = Data()
    private var encoding: String.Encoding?
    private var carry = ""

    mutating func consume(_ chunk: Data, final: Bool = false) throws -> String {
        bytes.append(chunk)
        if encoding == nil {
            guard bytes.count >= 4 || final else { return "" }
            if bytes.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; bytes.removeFirst(2) }
            else if bytes.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; bytes.removeFirst(2) }
            else if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { encoding = .utf8; bytes.removeFirst(3) }
            else if bytes.count >= 4 && bytes[bytes.startIndex + 1] == 0 && bytes[bytes.startIndex + 3] == 0 { encoding = .utf16LittleEndian }
            else if bytes.count >= 4 && bytes[bytes.startIndex] == 0 && bytes[bytes.startIndex + 2] == 0 { encoding = .utf16BigEndian }
            else {
                let validUTF8 = (0...min(3, bytes.count)).contains { String(data: bytes.prefix(bytes.count - $0), encoding: .utf8) != nil }
                // Preserve the prior UTF-16-without-BOM fallback for text files.
                encoding = validUTF8 ? .utf8 : .utf16BigEndian
            }
        }
        let selectedEncoding = encoding!
        var decoded: String?
        var consumed = bytes.count
        if selectedEncoding == .utf8 {
            for tail in 0...min(3, bytes.count) {
                if let text = String(data: bytes.prefix(bytes.count - tail), encoding: selectedEncoding) {
                    decoded = text; consumed = bytes.count - tail; break
                }
            }
        } else {
            consumed -= consumed % 2
            if consumed >= 2 {
                let a = UInt16(bytes[bytes.startIndex + consumed - 2])
                let b = UInt16(bytes[bytes.startIndex + consumed - 1])
                let last = selectedEncoding == .utf16LittleEndian ? a | (b << 8) : (a << 8) | b
                if (0xD800...0xDBFF).contains(last) { consumed -= 2 }
            }
            decoded = String(data: bytes.prefix(consumed), encoding: selectedEncoding)
        }
        guard let decoded else { throw ReadingError.unreadable }
        bytes.removeFirst(consumed)
        if final && !bytes.isEmpty { throw ReadingError.unreadable }
        let text = carry + decoded
        if final { carry = ""; return text }
        guard let last = text.last else { return "" }
        carry = String(last)
        return String(text.dropLast())
    }
}

struct ReadingPageIndex: Codable { let offsets: [UInt64] }

/// One UTF-8 file and a small byte-offset index. No array of whole-book pages.
final class ReadingPageWriter {
    private let file: FileHandle
    private let maximum: Int
    private var current = ""
    private var pageLength = 0
    private var total = 0
    private var offsets: [UInt64] = [0]
    private var visible = false
    init(folder: URL, maximum: Int = ReadingLimits.characters) throws {
        self.maximum = maximum
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("text.utf8")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]) else { throw ReadingError.unreadable }
        file = try FileHandle(forWritingTo: url)
    }
    deinit { try? file.close() }
    func append(_ text: String) throws {
        for character in text {
            total += 1
            guard total <= maximum else { throw ReadingError.tooManyCharacters }
            if !character.isWhitespace { visible = true }
            current.append(character); pageLength += 1
            if pageLength >= 1000 || (pageLength >= 750 && character == "\n") { try flush() }
        }
    }
    private func flush() throws {
        guard !current.isEmpty else { return }
        let data = Data(current.utf8)
        try file.write(contentsOf: data)
        offsets.append(offsets.last! + UInt64(data.count))
        current = ""; pageLength = 0
    }
    func finish(folder: URL) throws -> Int {
        guard visible else { throw ReadingError.unreadable }
        try flush(); try file.close()
        try JSONEncoder().encode(ReadingPageIndex(offsets: offsets)).write(to: folder.appendingPathComponent("pages.json"), options: [.atomic, .completeFileProtection])
        return offsets.count - 1
    }
}
