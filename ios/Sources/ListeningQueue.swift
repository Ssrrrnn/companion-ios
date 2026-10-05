import Foundation

enum ListeningQueue {
    static let limit = 5_000
    static func normalized(_ track: ListeningTrack) -> ListeningTrack {
        guard track.qqMID == nil, let share = MusicShare.from(track.url, label: track.title), share.provider == "qq" else { return track }
        var result = track
        result.qqMID = share.identifier
        return result
    }
    static func key(_ track: ListeningTrack) -> String { track.qqMID.map { "qq:" + $0 } ?? track.url }
    static func merged(_ existing: [ListeningTrack], _ incoming: [ListeningTrack]) -> [ListeningTrack] {
        var keys = Set<String>(), ids = Set<String>()
        return (existing + incoming).map(normalized).filter {
            ListeningTrack.validURL($0.url) != nil && keys.insert(key($0)).inserted && ids.insert($0.id).inserted
        }.prefix(limit).map { $0 }
    }
    static func candidate(in tracks: [ListeningTrack], selectedID: String?, forward: Bool) -> ListeningTrack? {
        let index = tracks.firstIndex { $0.id == selectedID }
        let candidates: [ListeningTrack]
        if forward { candidates = Array(tracks.dropFirst(index.map { $0 + 1 } ?? 0)) }
        else { candidates = Array(tracks.prefix(index ?? 0).reversed()) }
        return candidates.first { !$0.external || $0.qqMID != nil }
    }
}
