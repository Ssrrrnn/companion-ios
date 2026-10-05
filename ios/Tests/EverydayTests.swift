import XCTest
@testable import Companion
final class EverydayTests: XCTestCase {
    func testProviderLinksMustHaveActualProviderHost() {
        XCTAssertEqual(ListeningTrack.provider("music.163.com"), "网易云音乐")
        XCTAssertNil(ListeningTrack.provider("music.163.com.evil.test"))
        XCTAssertNil(ListeningTrack.validURL("http://example.com/audio.mp3"))
        XCTAssertNil(ListeningTrack.validURL("https://secret@example.com/audio.mp3"))
    }
    func testPodcastEnclosuresAndCDATAWithoutResolvingEntities() throws {
        let feed = Data("""
        <rss><channel><item><title><![CDATA[节目 & 日常]]></title><enclosure url="https://example.com/ep.mp3" type="audio/mpeg"/></item><item><title>不安全链接</title><enclosure url="http://example.com/ep.mp3"/></item></channel></rss>
        """.utf8)
        let episodes = try PodcastFeed().parse(feed)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes[0].title, "节目 & 日常")
        XCTAssertEqual(episodes[0].kind, "podcast")
        XCTAssertThrowsError(try PodcastFeed().parse(Data("<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss>&x;</rss>".utf8)))
    }
    func testWeatherUsesActualResponseAndUnknownCodesHaveFallback() throws {
        let data = Data(#"{"current":{"temperature_2m":21.4,"apparent_temperature":20.2,"weather_code":3,"wind_speed_10m":8.0}}"#.utf8)
        let value = try JSONDecoder().decode(WeatherResponse.self, from: data)
        XCTAssertEqual(value.current.temperature_2m, 21.4)
        XCTAssertEqual(WeatherSpace.description(3).0, "多云")
        XCTAssertEqual(WeatherSpace.description(999).0, "天气")
    }
    func testFreeBuildDoesNotClaimHealthCapability() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "MorrowHealthKitEnabled") as? Bool, false)
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio"))
    }
}
