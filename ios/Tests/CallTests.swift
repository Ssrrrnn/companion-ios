import XCTest
@testable import Companion

final class CallTests: XCTestCase {
    func testBilingualTranscriptKeepsOriginalAndTranslationThroughPersistence() throws {
        let line = CallLine(id: UUID(), role: "assistant", segments: [CallSegment(en: "I'm here.", zh: "我在呢。"), CallSegment(en: "Take your time.", zh: "慢慢说。")], at: .now)
        let restored = try JSONDecoder().decode(CallLine.self, from: JSONEncoder().encode(line))
        XCTAssertEqual(restored.translation, "我在呢。\n慢慢说。")
        XCTAssertEqual(restored.original, "I'm here.\nTake your time.")
        XCTAssertEqual(restored, line)
    }
    func testUserSpeechDoesNotInventAnEnglishTranslation() {
        let line = CallLine(id: UUID(), role: "user", segments: [CallSegment(en: "", zh: "今天有点累。")], at: .now)
        XCTAssertEqual(line.translation, "今天有点累。")
        XCTAssertTrue(line.original.isEmpty)
    }
    @MainActor func testHangupPersistsActualTranscriptAndCanDeleteAfterRestart() throws {
        let suite = "morrow-call-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let call = CallSpace(defaults: defaults)
        call.preview(); XCTAssertTrue(call.active)
        call.end(); XCTAssertFalse(call.active)
        let record = try XCTUnwrap(call.records.first)
        XCTAssertNotNil(record.ended); XCTAssertEqual(record.lines.count, 2)
        let restored = CallSpace(defaults: defaults)
        XCTAssertEqual(restored.records, [record])
        restored.remove(record.id)
        XCTAssertTrue(CallSpace(defaults: defaults).records.isEmpty)
    }
    func testUnfinishedRecordDoesNotFabricateElapsedDuration() {
        let start = Date.now
        XCTAssertEqual(CallRecord(id: UUID(), started: start, ended: nil, lines: []).duration, 0)
        XCTAssertEqual(CallRecord(id: UUID(), started: start, ended: start.addingTimeInterval(75), lines: []).duration, 75)
    }
    @MainActor func testMediaHandoffEndsCallAndRetainsItsTranscript() async throws {
        let suite = "morrow-call-handoff-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let call = CallSpace(defaults: defaults)
        call.preview()
        NotificationCenter.default.post(name: .morrowStopCall, object: nil)
        for _ in 0..<10 { if !call.active { break }; await Task.yield() }
        XCTAssertFalse(call.active)
        XCTAssertEqual(call.records.first?.lines.count, 2)
        XCTAssertNotNil(call.records.first?.ended)
    }

}
