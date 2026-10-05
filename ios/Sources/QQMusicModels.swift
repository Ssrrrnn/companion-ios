import Foundation

enum QQMembership: String {
    case unknown, ordinary, vip, svip
    var label: String {
        switch self {
        case .unknown: return "会员状态待确认"
        case .ordinary: return "普通账号"
        case .vip: return "绿钻会员"
        case .svip: return "超级会员"
        }
    }
}
struct QQPlaylist: Identifiable, Equatable {
    let id: String
    let title: String
    let cover: String
    let count: Int
    var collected = false
}
struct QQSongPage {
    let songs: [ListeningTrack]
    let total: Int
    let nextOffset: Int
    var upstreamHasMore: Bool? = nil
    var hasMore: Bool { !songs.isEmpty && (upstreamHasMore ?? (nextOffset < total)) }
}
struct TimedLyric: Identifiable, Equatable {
    let time: Double
    let text: String
    var id: String { "\(time):\(text)" }
    static func parse(_ source: String) -> [TimedLyric] {
        guard let regex = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#) else { return [] }
        var output: [TimedLyric] = []
        for line in source.split(whereSeparator: \.isNewline) {
            let line = String(line)
            let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
            guard let last = matches.last, let end = Range(last.range, in: line) else { continue }
            let text = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            for match in matches {
                guard let minutes = Range(match.range(at: 1), in: line), let seconds = Range(match.range(at: 2), in: line),
                      let m = Double(line[minutes]), let s = Double(line[seconds]) else { continue }
                output.append(TimedLyric(time: m * 60 + s, text: text))
            }
        }
        var ids = Set<String>()
        return output.filter { ids.insert($0.id).inserted }.sorted { $0.time < $1.time }
    }
}
// Protocol adapters are written for Morrow. No third-party player code is bundled.
enum QQWire {
    static func string(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    static func integer(_ value: Any?) -> Int { Int(string(value)) ?? 0 }
    static func identifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 40 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains($0) }
    }
    static func cookieDomain(_ domain: String) -> Bool {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "qq.com" || host == "y.qq.com" || host.hasSuffix(".y.qq.com")
    }
    static func account(_ cookies: [String: String]) -> String {
        let names = cookies["login_type"] == "2" ? ["wxuin", "qqmusic_uin", "uin"] : ["uin", "qqmusic_uin", "wxuin", "p_uin"]
        for key in names {
            let raw = cookies[key] ?? ""
            let value = raw.hasPrefix("o") ? String(raw.dropFirst()) : raw
            if !value.isEmpty && value.count <= 30 && value.utf8.allSatisfy({ (48...57).contains($0) }) { return String(value.drop(while: { $0 == "0" })) }
        }
        return ""
    }
    static func musicKey(_ cookies: [String: String]) -> String {
        for key in ["qm_keyst", "qqmusic_key", "music_key", "wxskey"] {
            if let value = cookies[key], !value.isEmpty { return value }
        }
        return ""
    }
    static func imageURL(_ value: String) -> URL? {
        let value = value.hasPrefix("//") ? "https:" + value : value.replacingOccurrences(of: "http://", with: "https://")
        guard let url = ListeningTrack.validURL(value), let host = url.host?.lowercased(),
              ["y.qq.com", "qpic.cn", "gtimg.cn", "gtimg.com", "qlogo.cn"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }
    static func audioURL(_ value: String) -> URL? {
        let value = value.replacingOccurrences(of: "http://", with: "https://")
        guard let url = ListeningTrack.validURL(value), let host = url.host?.lowercased(),
              host == "qqmusic.qq.com" || host.hasSuffix(".qqmusic.qq.com") else { return nil }
        return url
    }
    static func playlist(_ row: [String: Any], collected: Bool = false) -> QQPlaylist? {
        let liked = integer(row["dirid"]) == 201
        let id = liked ? "liked" : string(row["dissid"] ?? row["tid"] ?? row["diss_id"] ?? row["id"])
        guard id == "liked" || identifier(id) else { return nil }
        return QQPlaylist(id: id, title: liked ? "我喜欢" : string(row["diss_name"] ?? row["dissname"] ?? row["name"] ?? row["title"]),
                          cover: string(row["diss_cover"] ?? row["logo"] ?? row["picurl"]),
                          count: integer(row["song_cnt"] ?? row["songnum"] ?? row["total_song_num"]), collected: collected)
    }
    static func song(_ raw: [String: Any]) -> ListeningTrack? {
        let row = (raw["track_info"] ?? raw["songInfo"] ?? raw["songinfo"]) as? [String: Any] ?? raw
        let mid = string(row["mid"] ?? row["songmid"])
        let title = string(row["name"] ?? row["songname"])
        guard identifier(mid), !title.isEmpty else { return nil }
        let singers = row["singer"] as? [[String: Any]] ?? []
        let album = row["album"] as? [String: Any] ?? [:]
        let albumMID = string(album["mid"] ?? row["albummid"])
        let cover = identifier(albumMID) ? "https://y.gtimg.cn/music/photo_new/T002R500x500M000\(albumMID).jpg" : ""
        let file = row["file"] as? [String: Any] ?? [:]
        return ListeningTrack(id: "qq:" + mid, title: title, url: "https://y.qq.com/n/ryqq/songDetail/" + mid, kind: "music",
                              artist: singers.map { string($0["name"]) }.joined(separator: " / "),
                              qqMID: mid, mediaMID: string(file["media_mid"] ?? row["strMediaMid"]), artwork: cover)
    }
    // A successful transport or a VIP-looking nickname is not membership evidence.
    // Only accept an account-scoped, successful response with explicit status fields.
    static func membership(_ payload: [String: Any], account: String, now: Date = .now) -> QQMembership {
        guard payload["code"] != nil, integer(payload["code"]) == 0, let block = payload["req_1"] as? [String: Any],
              block["code"] != nil, integer(block["code"]) == 0, let data = block["data"] as? [String: Any] else { return .unknown }
        var scope: [String: Any]?
        for name in ["uin_map", "infoMap", "info_map"] {
            if let map = data[name] as? [String: Any], let row = map[account] as? [String: Any] { scope = row; break }
        }
        if scope == nil, string(data["uin"]) == account { scope = data }
        guard let scope else { return .unknown }
        var flags = scope
        for name in ["vip_info", "vipInfo", "membership_info"] {
            if let nested = scope[name] as? [String: Any] { flags.merge(nested) { _, new in new } }
        }
        let canonical = Dictionary(flags.map { ($0.key.lowercased().replacingOccurrences(of: "_", with: ""), $0.value) }, uniquingKeysWith: { _, new in new })
        func status(_ keys: [String]) -> Bool? {
            let values = keys.compactMap { canonical[$0] }.compactMap { value -> Bool? in
                if let number = value as? NSNumber { return number.doubleValue > 0 }
                if let text = value as? String {
                    if let n = Double(text) { return n > 0 }
                    if text == "true" { return true }; if text == "false" { return false }
                }
                return nil
            }
            return values.isEmpty ? nil : values.contains(true)
        }
        func expired(_ keys: [String]) -> Bool {
            for key in keys {
                guard let raw = canonical[key] else { continue }
                let value = string(raw)
                if let number = Double(value), number > 1_000_000_000 {
                    return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1000 : number) <= now
                }
                if let date = ISO8601DateFormatter().date(from: value) { return date <= now }
            }
            return false
        }
        let vip = status(["isvip", "ivipflag", "inewvip", "vipflag", "viptype", "isgreenvip"])
        let svip = status(["issvip", "isupervip", "inewsupervip", "sviptype", "issupervip"])
        if svip == true && !expired(["superendtime", "svipendtime", "svipexpiretime"]) { return .svip }
        if vip == true && !expired(["vipendtime", "endtime", "vipexpiretime"]) { return .vip }
        return vip == nil ? .unknown : .ordinary
    }
}
