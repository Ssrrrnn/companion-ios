import XCTest
@testable import Companion

final class ChatPiecesTests: XCTestCase {
    func testChineseSentencesAndClosingQuotes() {
        XCTAssertEqual(SentenceText.split("忙完了？过来，让我看看你。\n他说：“晚安。”"), ["忙完了？", "过来，让我看看你。", "他说：“晚安。”"])
    }
    func testDecimalsURLsAndEmojiSurviveSplitting() {
        XCTAssertEqual(SentenceText.split("版本 1.25 在 https://example.com/a?x=1。好了吗？🤍"), ["版本 1.25 在 https://example.com/a?x=1。", "好了吗？", "🤍"])
    }
    func testQuoteBelongsToFirstPieceAndSearchAnchorKeepsSourceID() {
        let message = Message(id: "42:assistant", role: "assistant", text: "[回复「我」]\n今天很累\n[/回复]\n那就赖着。今晚陪你。")
        let pieces = ChatPiece.make(message)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].anchor, message.id)
        XCTAssertEqual(QuotedText(pieces[0].text).quote, "今天很累")
        XCTAssertNil(QuotedText(pieces[1].text).quote)
        XCTAssertEqual(pieces[1].text, "今晚陪你。")
        XCTAssertEqual(Set(pieces.map(\.id)).count, pieces.count)
    }
    func testUserDraftAndPastedParagraphsStayOneMessage() {
        let message = Message(id: "42:user", role: "user", text: "第一句。\n第二句。")
        let pieces = ChatPiece.make(message)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].text, message.text)
        XCTAssertEqual(pieces[0].id, message.id)
    }
}
