import XCTest
@testable import Companion

final class QQMusicTests: XCTestCase {
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
