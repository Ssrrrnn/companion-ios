import XCTest
@testable import Companion

final class KeepsakeTests: XCTestCase {
    func testMusicMarkdownBecomesCardAndKeepsHumanReason() throws {
        let message = Message(id: "music", role: "assistant", text: "想把这首给你。\n[Song · Artist](https://y.qq.com/n/ryqq/songDetail/Test123?tracking=x)")
        let pieces = ChatPiece.make(message)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].text, "想把这首给你。")
        let share = try XCTUnwrap(pieces[1].music)
        XCTAssertEqual(share.title, "Song"); XCTAssertEqual(share.artist, "Artist")
        XCTAssertEqual(share.url, "https://y.qq.com/n/ryqq/songDetail/Test123")
        XCTAssertEqual(share.track.qqMID, "Test123")
        XCTAssertFalse(pieces[1].text.contains("tracking"))
    }
    func testMusicLinksRejectForeignHostsCredentialsAndWrongSongs() {
        for url in ["https://y.qq.com.evil.test/n/ryqq/songDetail/Test123", "https://token@y.qq.com/n/ryqq/songDetail/Test123", "https://y.qq.com:444/n/ryqq/songDetail/Test123", "https://y.qq.com/n/ryqq/songDetail/../private", "https://music.163.com/playlist?id=1", "http://y.qq.com/n/ryqq/songDetail/Test123"] {
            XCTAssertNil(MusicShare.from(url))
        }
        XCTAssertEqual(MusicShare.from("https://music.163.com/#/song?id=12345")?.identifier, "12345")
        XCTAssertNil(MusicShare.from("https://music.163.com/song?id=oops"))
    }
    func testRepeatedMusicLinkProducesOneCardAndQuoteIsPreserved() throws {
        let url = "https://y.qq.com/n/ryqq/songDetail/Test123"
        let message = Message(id: "one", role: "assistant", text: "[回复「我」]\n想听歌\n[/回复]\n[Song](\(url))\n[Song](\(url))")
        let pieces = ChatPiece.make(message)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertNotNil(pieces[0].music)
        XCTAssertEqual(QuotedText(pieces[0].text).quote, "想听歌")
        XCTAssertEqual(pieces[0].anchor, message.id)
    }
    func testOldKeepsakeResponseAndDatedPageBothDecode() throws {
        let old = try JSONDecoder().decode(Collection.self, from: Data(#"{"items":[{"id":"1","text":"Old"}]}"#.utf8))
        XCTAssertNil(old.items.first?.at)
        let page = Collection(items: [Keepsake(id: "2", text: "New", at: "2026-10-05T19:00:00Z", note: "Remember")], has_more: true, next_before: "2")
        let decoded = try JSONDecoder().decode(Collection.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(decoded.items, page.items)
        XCTAssertEqual(decoded.next_before, "2")
    }
    func testPinsAndSearchKeepDistinctCollections() {
        let first = CabinetEntry(sourceID: "1", kind: .diaries, text: "Today", attribution: "他的日记", date: Date(timeIntervalSince1970: 200))
        let second = CabinetEntry(sourceID: "1", kind: .memories, text: "Prefers books", attribution: "长期记忆", date: Date(timeIntervalSince1970: 100))
        XCTAssertNotEqual(first.id, second.id)
        let ordered = CabinetEntry.sorted([first, second], pinned: [second.id])
        XCTAssertEqual(ordered.map(\.id), [second.id, first.id])
        XCTAssertEqual(CabinetEntry.sorted([first, second], pinned: [], query: "BOOKS").map(\.id), [second.id])
    }
}
