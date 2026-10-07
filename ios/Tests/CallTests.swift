import XCTest
@testable import Companion

final class CallTests: XCTestCase {
    func testStreamedPCMLittleEndianSignedSamplesAndMalformedChunks() throws {
        let samples = try XCTUnwrap(CallPCM.samples(Data([0, 0, 0, 128, 255, 127])))
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[1], -1)
        XCTAssertEqual(samples[2], 32767.0 / 32768.0, accuracy: 0.00001)
        XCTAssertNil(CallPCM.samples(Data()))
        XCTAssertNil(CallPCM.samples(Data([0])))
        XCTAssertNil(CallPCM.samples(Data(repeating: 0, count: 16386)))
    }
    func testCallSocketKeepsCredentialInHeaderAndRejectsInsecureAddress() throws {
        let connection = try CompanionAPI(base: "https://example.com/personal", token: String(repeating: "a", count: 32)).callSocket()
        let request = try XCTUnwrap(connection.originalRequest)
        XCTAssertEqual(request.url?.absoluteString, "wss://example.com/personal/v1/call/realtime")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + String(repeating: "a", count: 32))
        XCTAssertNil(request.url?.query)
        XCTAssertThrowsError(try CompanionAPI(base: "http://example.com", token: String(repeating: "a", count: 32)).callSocket())
        XCTAssertThrowsError(try CompanionAPI(base: "https://example.com?token=x", token: String(repeating: "a", count: 32)).callSocket())
        connection.cancel(with: .normalClosure, reason: nil)
    }
    func testOldCallRecordsRemainReadableAndInterruptedTurnsPersist() throws {
        let json = "{\"id\":\"\(UUID().uuidString)\",\"role\":\"assistant\",\"segments\":[{\"en\":\"Hello.\",\"zh\":\"你好。\"}],\"at\":0}"
        var line = try JSONDecoder().decode(CallLine.self, from: Data(json.utf8))
        XCTAssertNil(line.interrupted)
        line.interrupted = true
        XCTAssertEqual(try JSONDecoder().decode(CallLine.self, from: JSONEncoder().encode(line)).interrupted, true)
    }
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
