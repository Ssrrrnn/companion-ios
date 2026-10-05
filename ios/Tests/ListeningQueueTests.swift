import XCTest
@testable import Companion

final class ListeningQueueTests: XCTestCase {
    private func song(_ id: String) -> ListeningTrack { ListeningTrack(id: id, title: id, url: "https://y.qq.com/n/ryqq/songDetail/" + id, kind: "music", qqMID: id) }
    func testKnownTotalContinuesWhenUpstreamFlagIsZeroAndUsesRawSpan() throws {
        let detail: [String: Any] = ["songlist": [["mid": "Song1", "name": "One"], ["mid": "../invalid", "name": "Hidden"]], "songlist_size": 100, "total_song_num": 250, "hasmore": 0]
        let page = try QQWire.songPage(detail, offset: 0, fallbackTotal: 250)
        XCTAssertEqual(page.songs.map(\.id), ["qq:Song1"])
        XCTAssertEqual(page.nextOffset, 100)
        XCTAssertTrue(page.canContinue(after: [], offset: 0))
    }
    func testFullPlaylistIsSlicedAcrossPagesWithoutRepeatingFirstPage() throws {
        let rows = (1...205).map { ["mid": "Song\($0)", "name": "Song \($0)"] }
        let page = try QQWire.songPage(["songlist": rows, "hasmore": 0], offset: 100, fallbackTotal: 205)
        XCTAssertEqual(page.songs.count, 100)
        XCTAssertEqual(page.songs.first?.qqMID, "Song101")
        XCTAssertEqual(page.nextOffset, 200)
        XCTAssertTrue(page.hasMore)
        let last = try QQWire.songPage(["songlist": rows], offset: 200, fallbackTotal: 205)
        XCTAssertEqual(last.songs.count, 5); XCTAssertFalse(last.hasMore)
    }
    func testSearchPageKeepsSongsAndPagination() throws {
        let rows = (1...30).map { ["songmid": "Song\($0)", "songname": "Song \($0)"] }
        let page = try QQWire.searchPage(["song": ["list": rows, "totalnum": 90]], page: 2)
        XCTAssertEqual(page.songs.count, 30)
        XCTAssertEqual(page.nextOffset, 60); XCTAssertTrue(page.hasMore)
    }
    func testManualQQLinkMigratesAndDuplicateSongIsNotAppended() {
        let legacy = ListeningTrack(id: "old", title: "Song", url: "https://y.qq.com/n/ryqq/songDetail/Song1", kind: "music")
        let items = ListeningQueue.merged([legacy], [song("Song1"), song("Song2")])
        XCTAssertEqual(items.count, 2); XCTAssertEqual(items[0].qqMID, "Song1")
        XCTAssertEqual(items[0].id, "old")
    }
    func testLargePlaylistKeepsSongsBeyondTheOld300EntryLimit() {
        let tracks = (1...501).map { song("Song\($0)") }
        let queue = ListeningQueue.merged([], tracks)
        XCTAssertEqual(queue.count, 501)
        XCTAssertEqual(queue.last?.qqMID, "Song501")
    }
    @MainActor func testFailedSongCanAdvanceAndBulkRemovalPersistsWithoutReappending() async throws {
        let name = "morrow-queue-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = ListeningSpace(defaults: defaults, playbackResolver: { _ in throw ConnectionError.server("无播放权限") }, systemControls: false)
        let first = song("Song1"), second = song("Song2"), third = song("Song3")
        let stamp = try XCTUnwrap(model.replaceQueue([first, second, third], startingAt: first))
        for _ in 0..<100 { if !model.resolving { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.resolving); XCTAssertNil(model.current)
        XCTAssertEqual(model.selectedTrackID, first.id)
        model.next()
        for _ in 0..<100 { if !model.resolving { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.selectedTrackID, second.id)
        XCTAssertTrue(model.error?.contains("Song2") == true)
        model.remove(ids: [first.id, second.id])
        XCTAssertEqual(model.queue.map(\.id), [third.id])
        XCTAssertFalse(model.appendPlaylistTracks([first], generation: stamp))
        let restored = ListeningSpace(defaults: defaults, systemControls: false)
        XCTAssertEqual(restored.queue.map(\.id), [third.id])
        restored.clearQueue(); XCTAssertTrue(restored.queue.isEmpty)
    }
}
