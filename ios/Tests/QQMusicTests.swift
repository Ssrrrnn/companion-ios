import XCTest
import WebKit
@testable import Companion

final class QQMusicTests: XCTestCase {
    @MainActor func testWebCookieChangesDetectMusicLoginWithoutNavigation() async throws {
        let account = QQMusicSpace()
        await account.inspectLogin()
        XCTAssertFalse(account.loginReady)
        let completed = await account.completeLogin()
        XCTAssertFalse(completed)
        XCTAssertNotNil(account.error)
        func set(_ name: String, _ value: String) async throws {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: ".y.qq.com", .path: "/", .name: name, .value: value, .secure: "TRUE"]))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                account.webStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
        try await set("uin", "10001")
        try await set("p_skey", "genericQQSession")
        await account.inspectLogin()
        XCTAssertFalse(account.loginReady)
        try await set("qm_keyst", "testMusicSession")
        await account.inspectLogin()
        XCTAssertTrue(account.loginReady)
        // Detection alone must not persist or upload these test credentials.
    }
    func testLoginNavigationAllowsOfficialJavaScriptAppLaunchOnly() throws {
        let app = try XCTUnwrap(URL(string: "qqmusic://login"))
        XCTAssertEqual(QQWire.loginNavigation(app, sourceHost: "y.qq.com", sourceScheme: "https"), .app)
        XCTAssertEqual(QQWire.loginNavigation(app, sourceHost: "y.qq.com.evil.test", sourceScheme: "https"), .blocked)
        XCTAssertEqual(QQWire.loginNavigation(app, sourceHost: "y.qq.com", sourceScheme: "http"), .blocked)
        XCTAssertEqual(QQWire.loginNavigation(try XCTUnwrap(URL(string: "https://ssl.ptlogin2.qq.com/login")), sourceHost: "y.qq.com", sourceScheme: "https"), .webpage)
        XCTAssertEqual(QQWire.loginNavigation(try XCTUnwrap(URL(string: "https://token@y.qq.com/")), sourceHost: "y.qq.com", sourceScheme: "https"), .blocked)
    }
    func testCookieSelectionPrefersMusicAccountAndIgnoresExpiredOrForeignCookies() throws {
        func cookie(_ domain: String, value: String, expires: Date? = nil) throws -> HTTPCookie {
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: "/", .name: "uin", .value: value]
            if let expires { properties[.expires] = expires }
            return try XCTUnwrap(HTTPCookie(properties: properties))
        }
        let generic = try cookie(".qq.com", value: "10001")
        let music = try cookie(".y.qq.com", value: "10002")
        let expired = try cookie("c.y.qq.com", value: "10003", expires: .distantPast)
        let foreign = try cookie("evil.test", value: "10004")
        XCTAssertEqual(QQWire.account(QQWire.cookieValues([generic, expired, foreign, music])), "10002")
        XCTAssertEqual(QQWire.account(QQWire.cookieValues([music, foreign, generic, expired])), "10002")
    }
    func testPlaylistRefreshKeepsFailedSectionAndRemovesSuccessfulEmptySection() {
        let liked = QQPlaylist(id: "liked", title: "我喜欢", cover: "", count: 10)
        let created = QQPlaylist(id: "100", title: "创建", cover: "", count: 1)
        let saved = QQPlaylist(id: "200", title: "收藏", cover: "", count: 2, collected: true)
        let next = QQPlaylist(id: "300", title: "新建", cover: "", count: 3)
        let refreshed = QQWire.replacingPlaylists([liked, created, saved], with: [next], collected: false)
        XCTAssertEqual(Set(refreshed.map(\.id)), ["liked", "200", "300"])
        let emptied = QQWire.replacingPlaylists(refreshed, with: [], collected: true)
        XCTAssertEqual(Set(emptied.map(\.id)), ["liked", "300"])
    }
    func testRepeatedPlaylistPageCannotKeepLoadingForever() {
        let track = ListeningTrack(id: "same", title: "Song", url: "https://example.com/audio.mp3", kind: "music")
        let page = QQSongPage(songs: [track], total: 300, nextOffset: 200)
        XCTAssertTrue(page.canContinue(after: [], offset: 100))
        XCTAssertFalse(page.canContinue(after: ["same"], offset: 100))
        XCTAssertFalse(page.canContinue(after: [], offset: 200))
    }
    private func membership(_ fields: [String: Any], uin: String = "10001", code: Int = 0) -> [String: Any] {
        ["code": 0, "req_1": ["code": code, "data": ["uin_map": [uin: ["vip_info": fields]]]]]
    }
    func testMembershipMustMatchAccountAndSuccessfulResponse() {
        XCTAssertEqual(QQWire.membership(membership(["is_vip": true]), account: "99999"), .unknown)
        XCTAssertEqual(QQWire.membership(membership(["is_vip": true], code: 1000), account: "10001"), .unknown)
        XCTAssertEqual(QQWire.membership(membership(["title": "VIP"]), account: "10001"), .unknown)
        XCTAssertEqual(QQWire.membership(["code": 0, "req_1": ["code": 0, "data": [:]]], account: "10001"), .unknown)
    }
    func testMembershipExpiryAndSeparateTiers() {
        XCTAssertEqual(QQWire.membership(membership(["is_vip": true, "end_time": 1000000001]), account: "10001"), .ordinary)
        XCTAssertEqual(QQWire.membership(membership(["is_vip": true, "end_time": 2100000000]), account: "10001"), .vip)
        XCTAssertEqual(QQWire.membership(membership(["is_vip": false]), account: "10001"), .ordinary)
        XCTAssertEqual(QQWire.membership(membership(["is_vip": false, "vip_type": 1]), account: "10001"), .ordinary)
        XCTAssertEqual(QQWire.membership(membership(["is_vip": true, "end_time": "2001-01-01T00:00:00.000Z"]), account: "10001"), .ordinary)
        XCTAssertEqual(QQWire.membership(membership(["is_vip": true, "end_time": "2001-01-01 00:00:00"]), account: "10001"), .ordinary)
        XCTAssertEqual(QQWire.membership(membership(["iVipFlag": 1, "iSuperVip": 1, "superEndTime": "2036-01-01T00:00:00Z"]), account: "10001"), .svip)
        XCTAssertEqual(QQWire.membership(membership(["is_vip": true, "vip_end_time": 2100000000, "is_svip": true, "svip_end_time": 1000000001]), account: "10001"), .vip)
    }
    func testGenericQQLoginDoesNotClaimMusicPlaybackAuthorization() {
        XCTAssertEqual(QQWire.account(["uin": "o0010001"]), "10001")
        XCTAssertEqual(QQWire.account(["login_type": "2", "wxuin": "10002", "uin": "10001"]), "10002")
        XCTAssertEqual(QQWire.musicKey(["p_skey": "genericQQTicket"]), "")
        XCTAssertFalse(QQWire.cookieDomain("qq.com.evil.test"))
        XCTAssertFalse(QQWire.cookieDomain("accounts.qq.com"))
        XCTAssertTrue(QQWire.cookieDomain(".y.qq.com"))
        XCTAssertNil(QQWire.audioURL("https://qqmusic.qq.com.evil.test/test.mp3"))
        XCTAssertNil(QQWire.audioURL("https://secret@ws.stream.qqmusic.qq.com/test.mp3"))
    }
    func testCatalogTrackPersistsWithoutPlaybackTicketAndOldQueueStillDecodes() throws {
        let song = try XCTUnwrap(QQWire.song(["songmid": "003rJSwm3TechU", "songname": "Example", "singer": [["name": "Singer"]], "albummid": "000TestAlbum", "strMediaMid": "000MediaMID"]))
        XCTAssertEqual(song.id, "qq:003rJSwm3TechU")
        XCTAssertEqual(song.qqMID, "003rJSwm3TechU")
        XCTAssertTrue(song.url.hasPrefix("https://y.qq.com/n/ryqq/songDetail/"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(song), as: UTF8.self).contains("vkey"))
        let old = try JSONDecoder().decode(ListeningTrack.self, from: Data(#"{"id":"old","title":"Episode","url":"https://example.com/ep.mp3","kind":"podcast","artist":""}"#.utf8))
        XCTAssertNil(old.qqMID)
    }
    func testLyricsSupportRepeatedTimestampsAndIgnoreMetadata() {
        let lines = TimedLyric.parse("[ar:Singer]\n[00:01.25][00:03.00]Hello\n[00:05.00]World")
        XCTAssertEqual(lines.map(\.time), [1.25, 3, 5])
        XCTAssertEqual(lines.map(\.text), ["Hello", "Hello", "World"])
    }
}
