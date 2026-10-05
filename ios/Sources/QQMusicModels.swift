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
    var rawSpan: Int = 0
    var hasMore: Bool { (!songs.isEmpty || rawSpan > 0) && (upstreamHasMore == true || nextOffset < total) }
    func canContinue(after existingIDs: Set<String>, offset: Int) -> Bool {
        hasMore && nextOffset > offset && ((songs.isEmpty && rawSpan > 0) || songs.contains { !existingIDs.contains($0.id) })
    }
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
    static func songPage(_ detail: [String: Any], offset: Int, fallbackTotal: Int) throws -> QQSongPage {
        guard let rows = (detail["songlist"] ?? detail["songList"]) as? [[String: Any]] else { throw ConnectionError.server("这个歌单暂时无法读取，请在 QQ 音乐检查是否可见") }
        let fullList = rows.count > 100
        let slice = fullList ? Array(rows.dropFirst(offset).prefix(100)) : rows
        let span = fullList ? slice.count : min(100, max(slice.count, integer(detail["songlist_size"])))
        let total = max(fullList ? rows.count : offset + span, max(fallbackTotal, integer(detail["total_song_num"] ?? detail["totalSongNum"] ?? detail["songnum"])))
        return QQSongPage(songs: slice.compactMap(song), total: total, nextOffset: offset + span,
                         upstreamHasMore: detail["hasmore"] == nil ? nil : integer(detail["hasmore"]) != 0, rawSpan: span)
    }
    static func searchPage(_ data: [String: Any], page: Int) throws -> QQSongPage {
        guard let section = data["song"] as? [String: Any], let rows = section["list"] as? [[String: Any]] else { throw ConnectionError.server("音乐搜索暂未返回结果") }
        let offset = (page - 1) * 30 + rows.count
        return QQSongPage(songs: rows.compactMap(song), total: max(offset, integer(section["totalnum"])), nextOffset: offset, rawSpan: rows.count)
    }
    enum LoginNavigation: Equatable { case webpage, app, blocked }
    static func loginHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return ["qq.com", "tencent.com", "qqmusic.com", "gtimg.com", "qpic.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
    static func loginNavigation(_ url: URL, sourceHost: String, sourceScheme: String) -> LoginNavigation {
        if url.absoluteString == "about:blank" { return .webpage }
        guard url.user == nil, url.password == nil else { return .blocked }
        if url.scheme == "https", loginHost(url.host ?? "") { return .webpage }
        // Official pages also launch their login app through JavaScript navigation.
        if ["mqq", "mqqapi", "mqqopensdkapi", "qqmusic", "weixin"].contains(url.scheme ?? ""),
           sourceScheme == "https", loginHost(sourceHost) { return .app }
        return .blocked
    }
    static func cookieValues(_ cookies: [HTTPCookie]) -> [String: String] {
        // Prefer the music website's account over a generic QQ session with the same name.
        let candidates = cookies.filter { cookieDomain($0.domain) && ($0.expiresDate == nil || $0.expiresDate! > .now) }
        let sorted = candidates.sorted {
            let left = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let right = $1.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if (left == "qq.com") != (right == "qq.com") { return left != "qq.com" }
            if left != right { return left < right }
            return $0.path.count > $1.path.count
        }
        return Dictionary(sorted.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
    static func replacingPlaylists(_ previous: [QQPlaylist], with incoming: [QQPlaylist], collected: Bool) -> [QQPlaylist] {
        let retained = previous.filter { $0.collected != collected || ($0.id == "liked" && !incoming.contains(where: { $0.id == "liked" })) }
        var ids = Set<String>()
        return (incoming + retained).filter { ids.insert($0.id).inserted }
    }
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
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = iso.date(from: value) { return date <= now }
                iso.formatOptions = [.withInternetDateTime]
                if let date = iso.date(from: value) { return date <= now }
                let local = DateFormatter(); local.locale = Locale(identifier: "en_US_POSIX")
                local.timeZone = TimeZone(identifier: "Asia/Shanghai"); local.dateFormat = "yyyy-MM-dd HH:mm:ss"
                if let date = local.date(from: value) { return date <= now }
            }
            return false
        }
        let vip = status(["isvip", "ivipflag", "inewvip", "vipflag", "isgreenvip"]) ?? status(["viptype"])
        let svip = status(["issvip", "isupervip", "inewsupervip", "issupervip"]) ?? status(["sviptype"])
        if svip == true && !expired(["superendtime", "svipendtime", "svipexpiretime"]) { return .svip }
        if vip == true && !expired(["vipendtime", "endtime", "vipexpiretime"]) { return .vip }
        return vip == nil ? .unknown : .ordinary
    }
}
