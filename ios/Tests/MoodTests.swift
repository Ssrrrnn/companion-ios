import XCTest
@testable import Companion
final class MoodTests: XCTestCase {
    func testStatisticsCountDaysAndKeepPeopleSeparate() {
        let records = [
            SharedEntry(id: "1", actor: "user", kind: "mood", day: "2026-10-05", title: "", text: "", emoji: "😊"),
            SharedEntry(id: "2", actor: "user", kind: "mood", day: "2026-10-05", title: "", text: "", emoji: "😌"),
            SharedEntry(id: "3", actor: "assistant", kind: "mood", day: "2026-10-05", title: "", text: "", emoji: "📖"),
            SharedEntry(id: "4", actor: "user", kind: "event", day: "2026-10-06", title: "", text: "", emoji: "")]
        XCTAssertEqual(MoodStyle.latestPerDay(records, actor: "user").map(\.emoji), ["😌"])
        XCTAssertEqual(MoodStyle.latestPerDay(records, actor: "assistant").map(\.emoji), ["📖"])
        XCTAssertEqual(MoodStyle.label("📖"), "心情")
    }
}
