import XCTest
import CoreLocation
@testable import Companion

final class CompanionActivityTests: XCTestCase {
    func testSeparateBookProgressAndNeverReadMarker() throws {
        let data = Data(#"{"id":"book","title":"书","page_count":20,"user_page":12,"assistant_page":-1,"received":4}"#.utf8)
        let value = try JSONDecoder().decode(SharedBookProgress.self, from: data)
        XCTAssertEqual(value.user_page, 12); XCTAssertEqual(value.hisProgress, "他还没读")
    }
    func testActivityDecodeAndPlannedIsNotDone() throws {
        let data = Data(#"{"id":"receipt","day":"2026-10-05","kind":"plan","status":"planned","title":"今日规划","text":"读书","at":"2026-10-05T08:00:00+08:00","evidence":{}}"#.utf8)
        let value = try JSONDecoder().decode(CompanionActivity.self, from: data)
        XCTAssertEqual(value.statusLabel, "计划")
    }
    func testGreetingChangesByBeijingTimeAndStaleLocationIsRejected() throws {
        let morning = try XCTUnwrap(SharedDates.instant("2026-10-05T08:00:00+08:00"))
        let night = try XCTUnwrap(SharedDates.instant("2026-10-05T23:00:00+08:00"))
        XCTAssertNotEqual(HomeGreeting.text(at: morning, name: "他"), HomeGreeting.text(at: night, name: "他"))
        let stale = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31, longitude: 121), altitude: 0, horizontalAccuracy: 100, verticalAccuracy: 0, timestamp: morning.addingTimeInterval(-300))
        XCTAssertNil(PhoneLocation.sample(stale, now: morning))
        let fresh = CLLocation(coordinate: CLLocationCoordinate2D(latitude: 31, longitude: 121), altitude: 0, horizontalAccuracy: 100, verticalAccuracy: 0, timestamp: morning)
        XCTAssertEqual(PhoneLocation.sample(fresh, now: morning)?.accuracy, 100)
    }
    func testBuiltAppDeclaresLocationPermission() {
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String ?? "").isEmpty)
    }
}
