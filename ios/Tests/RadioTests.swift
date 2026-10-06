import XCTest
@testable import Companion

final class RadioTests: XCTestCase {
    func testFullLongTextIsPreservedAndEveryRequestIsBoundedByUnicodeScalars() {
        let text = String(repeating: "一句话。👨‍👩‍👧‍👦\n", count: 200)
        let parts = RadioScript.parts(text: text, title: "文章", host: "他", opening: false)
        XCTAssertGreaterThan(parts.count, 2)
        XCTAssertEqual(parts.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(parts.allSatisfy { $0.unicodeScalars.count <= 380 })
    }
    func testOversizedContentIsRejectedInsteadOfSilentlyTruncated() {
        XCTAssertTrue(RadioScript.parts(text: String(repeating: "字", count: 6001), title: "书", host: "他", opening: false).isEmpty)
        XCTAssertTrue(RadioScript.parts(text: " \n ", title: "书", host: "他", opening: false).isEmpty)
    }
    func testOptionalHostLinksDoNotChangeTheSelectedText() {
        let text = "把今天留成一页。"
        let parts = RadioScript.parts(text: text, title: "日记", host: "他", opening: true)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.first!.contains("他的电台"))
        XCTAssertEqual(parts[1], text)
    }
    @MainActor func testSavedProgramsSurviveRestartAndDeletion() throws {
        let suite = "morrow-radio-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let radio = RadioSpace(defaults: defaults)
        let program = try XCTUnwrap(radio.save(title: "我的一期", text: "想听的文字。", source: "我的选文", tone: "night"))
        let restored = RadioSpace(defaults: defaults)
        XCTAssertEqual(restored.programs, [program])
        restored.remove(program)
        XCTAssertTrue(RadioSpace(defaults: defaults).programs.isEmpty)
        XCTAssertNil(radio.save(title: "过长", text: String(repeating: "字", count: 6001), source: "我的选文", tone: "natural"))
    }
    func testHomeSwipeDoesNotInterceptVerticalScrollOrSmallDrags() {
        XCTAssertTrue(HomeSwipe.opens(x: -110, y: 12))
        XCTAssertFalse(HomeSwipe.opens(x: -40, y: 2))
        XCTAssertFalse(HomeSwipe.opens(x: -80, y: -130))
        XCTAssertFalse(HomeSwipe.opens(x: 110, y: 0))
    }
}
