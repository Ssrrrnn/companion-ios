import XCTest
@testable import Companion

final class SharedCalendarTests: XCTestCase {
    func testMonthGridPreservesLeapDayAndMondayAlignment() throws {
        let month = try XCTUnwrap(SharedDates.parse("2024-02-01"))
        let cells = SharedDates.cells(month)
        XCTAssertEqual(cells.count % 7, 0)
        XCTAssertNil(cells[0]); XCTAssertNil(cells[1]); XCTAssertNil(cells[2])
        XCTAssertEqual(cells.compactMap { $0 }.count, 29)
        XCTAssertEqual(SharedDates.key(try XCTUnwrap(cells[3])), "2024-02-01")
        XCTAssertEqual(SharedDates.key(try XCTUnwrap(cells[31])), "2024-02-29")
    }
    func testDatesUseBeijingAcrossUtcMidnight() throws {
        let date = try XCTUnwrap(SharedDates.instant("2026-10-04T18:00:00Z"))
        XCTAssertEqual(SharedDates.key(date), "2026-10-05")
        XCTAssertEqual(SharedDates.month(date), "2026-10")
    }
    func testPhoneActionRejectsInvalidTimeAndUnrelatedCommand() throws {
        let now = try XCTUnwrap(SharedDates.instant("2026-10-05T10:00:00+08:00"))
        func action(kind: String = "create_calendar_event", start: String = "2026-10-06T10:00:00+08:00", end: String = "2026-10-06T11:00:00+08:00", alarm: Int? = nil) -> PhoneAction {
            PhoneAction(id: UUID().uuidString, kind: kind, title: "一起读书", start: start, end: end, note: nil, alarm_minutes: alarm)
        }
        XCTAssertNoThrow(try PhoneRules.validate(action(), now: now))
        XCTAssertThrowsError(try PhoneRules.validate(action(kind: "delete_calendar"), now: now))
        XCTAssertThrowsError(try PhoneRules.validate(action(end: "2026-10-06T09:00:00+08:00"), now: now))
        XCTAssertThrowsError(try PhoneRules.validate(action(start: "2026-10-06T10:00:00"), now: now))
        XCTAssertThrowsError(try PhoneRules.validate(action(alarm: 1441), now: now))
        XCTAssertThrowsError(try PhoneRules.validate(action(start: "2026-10-04T10:00:00+08:00"), now: now))
    }
    @MainActor
    func testSavingMoodDoesNotAlterChatDraftAndPreservesBothActors() throws {
        let keys = ["shared_calendar_cache_v1", "shared_calendar_pending_v1", "shared_calendar_deletions_v1", "chat_draft_v1"]
        let defaults = UserDefaults.standard
        let original = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, original) { defaults.set(value, forKey: key) } }
        defaults.set("没有发送的草稿", forKey: "chat_draft_v1")
        let space = SharedSpace(); space.preview()
        let botCount = space.entries.filter { $0.actor == "assistant" }.count
        space.saveMood(emoji: "🥰", note: "只想记下来", date: .now)
        XCTAssertEqual(defaults.string(forKey: "chat_draft_v1"), "没有发送的草稿")
        XCTAssertEqual(space.entries.filter { $0.actor == "assistant" }.count, botCount)
        XCTAssertEqual(space.entries.last?.status, "pending_sync")
        let restored = SharedSpace()
        XCTAssertTrue(restored.entries.contains { $0.text == "只想记下来" })
    }
}
