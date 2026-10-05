import SwiftUI
import WebKit
import Security

private struct QQCookie: Codable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expires: Date?
    var active: Bool { expires == nil || expires! > .now }
    var native: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path, .secure: "TRUE"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)
    }
}
private enum QQCredentialStore {
    static let service = "com.ssrrrnn.companion.qqmusic"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "web-session"] }
    static func read() -> [QQCookie] {
        var search = query; search[kSecReturnData as String] = true; search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return [] }
        return (try? JSONDecoder().decode([QQCookie].self, from: data)) ?? []
    }
    static func save(_ cookies: [QQCookie]) throws {
        let data = try JSONEncoder().encode(cookies)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecSuccess { return }
        guard result == errSecItemNotFound else { throw ConnectionError.keychain }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw ConnectionError.keychain }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}
// Credentials are sent only to the fixed QQ Music API hosts. Refuse redirects
// rather than risk forwarding login headers to a redirected CDN or login page.
private final class QQNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@MainActor
final class QQMusicSpace: ObservableObject {
    @Published private(set) var nickname = "QQ 音乐"
    @Published private(set) var avatar = ""
    @Published private(set) var membership = QQMembership.unknown
    @Published private(set) var playlists: [QQPlaylist] = []
    @Published private(set) var refreshedAt: Date?
    @Published private(set) var busy = false
    @Published private(set) var loginReady = false
    @Published var error: String?
    let webStore = WKWebsiteDataStore.nonPersistent()
    private var cookies: [QQCookie]
    private var generation = UUID()
    private let transport: URLSession
    private let noRedirect = QQNoRedirect()
    var accountID: String { QQWire.account(values) }
    var connected: Bool { !accountID.isEmpty && !QQWire.musicKey(values).isEmpty }
    private var values: [String: String] { Dictionary(cookies.filter(\.active).map { ($0.name, $0.value) }, uniquingKeysWith: { old, _ in old }) }
    init() {
        cookies = QQCredentialStore.read().filter { $0.active && QQWire.cookieDomain($0.domain) }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        transport = URLSession(configuration: config)
    }
    func prepareWebSession() async {
        for cookie in cookies.filter(\.active).compactMap(\.native) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                webStore.httpCookieStore.setCookie(cookie) { continuation.resume() }
            }
        }
    }
    func inspectLogin() async {
        let raw = await webCookies()
        let values = Dictionary(raw.map { ($0.name, $0.value) }, uniquingKeysWith: { old, _ in old })
        loginReady = !QQWire.account(values).isEmpty && !QQWire.musicKey(values).isEmpty
    }
    private func webCookies() async -> [HTTPCookie] {
        let raw = await withCheckedContinuation { continuation in webStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
        return raw.filter { QQWire.cookieDomain($0.domain) && ($0.expiresDate == nil || $0.expiresDate! > .now) }
    }
    func completeLogin() async -> Bool {
        let raw = await webCookies()
        let allowed = Set(["uin", "qqmusic_uin", "wxuin", "p_uin", "qm_keyst", "qqmusic_key", "music_key", "wxskey", "login_type", "qm_login_type", "p_skey", "skey", "psrf_qqopenid", "psrf_qqaccess_token", "psrf_qqrefresh_token", "wxrefresh_token"])
        let saved = raw.filter { allowed.contains($0.name) || $0.name.hasPrefix("ptnick_") }.map {
            QQCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate)
        }
        let values = Dictionary(saved.map { ($0.name, $0.value) }, uniquingKeysWith: { old, _ in old })
        guard !QQWire.account(values).isEmpty, !QQWire.musicKey(values).isEmpty else {
            error = "还没有获得 QQ 音乐登录状态。请在官网完成登录，再点同步。"; return false
        }
        do {
            try QQCredentialStore.save(saved)
            generation = UUID(); busy = false; cookies = saved; playlists = []; membership = .unknown; refreshedAt = nil; error = nil
            await refresh(); return true
        } catch { self.error = "登录信息未能安全保存，请重试。"; return false }
    }
    func disconnect() async {
        generation = UUID(); cookies = []; QQCredentialStore.clear()
        playlists = []; membership = .unknown; refreshedAt = nil; nickname = "QQ 音乐"; avatar = ""; error = nil; loginReady = false; busy = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            webStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
    }
    private func request(_ endpoint: String, params: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        guard connected else { throw ConnectionError.server("先连接 QQ 音乐账号") }
        guard var parts = URLComponents(string: endpoint), parts.scheme == "https",
              ["c.y.qq.com", "u.y.qq.com"].contains(parts.host ?? "") else { throw ConnectionError.server("音乐接口地址不支持") }
        if !params.isEmpty { parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = parts.url else { throw ConnectionError.server("音乐接口地址不支持") }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        request.setValue("https://y.qq.com/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        let scoped = cookies.filter(\.active).compactMap(\.native).filter { cookie in
            let host = url.host ?? "", domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path)
        }
        for (key, value) in HTTPCookie.requestHeaderFields(with: scoped) { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }
        let stamp = generation
        let (bytes, response) = try await transport.bytes(for: request, delegate: noRedirect)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.server("QQ 音乐接口暂未响应，请稍后刷新或重新登录") }
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count > 4_000_000 { throw ConnectionError.server("音乐返回内容过大，请分批读取") } }
        guard stamp == generation else { throw CancellationError() }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConnectionError.server("QQ 音乐返回格式暂不支持") }
        return object
    }
    private var common: [String: String] {
        ["format": "json", "inCharset": "utf8", "outCharset": "utf-8", "notice": "0", "platform": "yqq.json", "needNewCode": "0", "loginUin": accountID, "g_tk": "5381"]
    }
    private func checked(_ object: [String: Any]) throws {
        let code = QQWire.integer(object["code"] ?? object["result"])
        guard code == 0 else { throw ConnectionError.server([1000, 301, 10004, 104003, -100008].contains(code) ? "QQ 音乐登录已失效或权限不足，请重新登录" : "QQ 音乐暂未返回数据，请稍后刷新") }
    }
    private func rpc(module: String, method: String, params: [String: Any], clientType: Int = 24) async throws -> [String: Any] {
        let object = try await request("https://u.y.qq.com/cgi-bin/musicu.fcg", body: [
            "comm": ["uin": accountID, "authst": QQWire.musicKey(values), "format": "json", "ct": clientType, "cv": 0],
            "req_1": ["module": module, "method": method, "param": params]])
        try checked(object)
        guard let block = object["req_1"] as? [String: Any] else { throw ConnectionError.server("QQ 音乐返回内容暂不支持") }
        try checked(block)
        return object
    }
    func refresh() async {
        guard connected, !busy else { return }
        busy = true; error = nil; membership = .unknown
        let stamp = generation
        defer { if stamp == generation { busy = false } }
        let uin = accountID
        // Independent failures do not erase a successfully returned playlist section.
        do {
            let profile = try await request("https://c.y.qq.com/rsc/fcgi-bin/fcg_get_profile_homepage.fcg", params: common.merging(["cid": "205360838", "userid": uin, "reqfrom": "1", "hostUin": "0"]) { _, new in new })
            try checked(profile)
            if let data = profile["data"] as? [String: Any] {
                let creator = data["creator"] as? [String: Any] ?? data
                let name = QQWire.string(creator["nick"] ?? creator["nickname"])
                if !name.isEmpty { nickname = name }
                avatar = QQWire.string(creator["headpic"] ?? creator["avatar"])
            }
        } catch { if stamp == generation { self.error = "账号资料暂未同步，歌单将继续尝试读取" } }
        guard stamp == generation else { return }
        var memberships: [QQMembership] = []
        for method in ["SRFVipQuery_V2", "SRFVipQuery"] {
            if let result = try? await rpc(module: "userInfo.VipQueryServer", method: method, params: ["uin_list": [uin]]) {
                memberships.append(QQWire.membership(result, account: uin))
            }
            guard stamp == generation else { return }
        }
        if memberships.contains(.svip) { membership = .svip }
        else if memberships.contains(.vip) { membership = .vip }
        else if memberships.count == 2 && memberships.allSatisfy({ $0 == .ordinary }) { membership = .ordinary }
        var result: [QQPlaylist] = []
        var completed = 0
        for collected in [false, true] {
            do {
                for page in 0..<25 {
                    let start = page * 200
                    let parameters = collected
                        ? ["ct": "20", "cid": "205360956", "userid": uin, "reqtype": "3", "sin": String(start), "ein": String(start + 199)]
                        : ["hostUin": "0", "hostuin": uin, "sin": String(start), "size": "200"]
                    let endpoint = collected ? "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg" : "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss"
                    let object = try await request(endpoint, params: common.merging(parameters) { _, new in new }); try checked(object)
                    guard let data = object["data"] as? [String: Any], let rows = data[collected ? "cdlist" : "disslist"] as? [[String: Any]] else { throw ConnectionError.server("这一组歌单暂未同步") }
                    result += rows.compactMap { QQWire.playlist($0, collected: collected) }
                    if rows.count < 200 { break }
                    if page == 24 { self.error = "已读取前 5000 个歌单" }
                }
                completed += 1
            } catch { if stamp == generation { self.error = collected ? "收藏歌单暂未同步，可稍后刷新" : "创建歌单暂未同步，请刷新或重新登录" } }
            guard stamp == generation else { return }
        }
        if !result.contains(where: { $0.id == "liked" }) {
            if let page = try? await songs(in: QQPlaylist(id: "liked", title: "我喜欢", cover: "", count: 0)) {
                result.insert(QQPlaylist(id: "liked", title: "我喜欢", cover: page.songs.first?.artwork ?? "", count: page.total), at: 0)
                completed += 1
            }
        }
        guard stamp == generation else { return }
        if completed > 0 {
            var ids = Set<String>(); playlists = result.filter { ids.insert($0.id).inserted }; refreshedAt = .now
        }
    }
    func songs(in playlist: QQPlaylist, offset: Int = 0) async throws -> QQSongPage {
        let object: [String: Any]
        let detail: [String: Any]
        if playlist.id == "liked" {
            object = try await rpc(module: "music.srfDissInfo.DissInfo", method: "CgiGetDiss", params: ["disstid": 0, "dirid": 201, "tag": 1, "song_begin": offset, "song_num": 100, "userinfo": 1, "orderlist": 1])
            detail = (object["req_1"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
        } else {
            guard QQWire.identifier(playlist.id) else { throw ConnectionError.server("歌单标识不支持") }
            object = try await request("https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg", params: common.merging(["type": "1", "utf8": "1", "disstid": playlist.id, "song_begin": String(offset), "song_num": "100"]) { _, new in new })
            try checked(object)
            detail = (object["cdlist"] as? [[String: Any]])?.first ?? [:]
        }
        guard let rows = (detail["songlist"] ?? detail["songList"]) as? [[String: Any]] else { throw ConnectionError.server("这个歌单暂时无法读取，请在 QQ 音乐检查是否可见") }
        let total = max(offset + rows.count, QQWire.integer(detail["total_song_num"] ?? detail["totalSongNum"] ?? detail["songnum"] ?? playlist.count))
        let slice = rows.count > 100 ? Array(rows.dropFirst(offset).prefix(100)) : rows
        return QQSongPage(songs: slice.compactMap(QQWire.song), total: total, nextOffset: offset + slice.count,
                         upstreamHasMore: detail["hasmore"] == nil ? nil : QQWire.integer(detail["hasmore"]) != 0)
    }
    func search(_ text: String) async throws -> [ListeningTrack] {
        let query = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        guard !query.isEmpty else { return [] }
        let object = try await request("https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg", params: common.merging(["key": query]) { _, new in new }); try checked(object)
        let data = object["data"] as? [String: Any] ?? [:]
        let section = data["song"] as? [String: Any] ?? [:]
        return (section["itemlist"] as? [[String: Any]] ?? []).compactMap { row in
            var row = row
            row["songmid"] = row["mid"]; row["songname"] = row["name"]
            row["singer"] = [["name": QQWire.string(row["singer"])]]
            return QQWire.song(row)
        }
    }
    func playbackURL(_ track: ListeningTrack) async throws -> URL {
        guard let mid = track.qqMID, QQWire.identifier(mid) else { throw ConnectionError.server("歌曲标识不支持") }
        let media = track.mediaMID.flatMap { QQWire.identifier($0) ? $0 : nil } ?? mid
        let object = try await rpc(module: "vkey.GetVkeyServer", method: "CgiGetVkey", params: [
            "guid": String(UInt64.random(in: 10_000_000...99_999_999)), "songmid": [mid], "songtype": [0], "uin": accountID, "loginflag": 1, "platform": "20", "filename": ["M500" + media + ".mp3"]], clientType: 19)
        let data = (object["req_1"] as? [String: Any])?["data"] as? [String: Any] ?? [:]
        let info = (data["midurlinfo"] as? [[String: Any]])?.first ?? [:]
        let path = QQWire.string(info["purl"])
        guard !path.isEmpty, !path.hasPrefix("http"), !path.hasPrefix("//") else { throw ConnectionError.server("QQ 音乐没有为当前账号返回播放权限，可在官方 App 播放") }
        let bases = data["sip"] as? [String] ?? ["https://ws.stream.qqmusic.qq.com/"]
        for base in bases { if let url = QQWire.audioURL(base + path) { return url } }
        throw ConnectionError.server("QQ 音乐没有返回可用的安全音频地址")
    }
    func lyrics(_ track: ListeningTrack) async -> [TimedLyric] {
        guard let mid = track.qqMID else { return [] }
        guard let object = try? await rpc(module: "music.musichallSong.PlayLyricInfo", method: "GetPlayLyricInfo", params: ["songMID": mid]),
              let data = (object["req_1"] as? [String: Any])?["data"] as? [String: Any] else { return [] }
        let raw = QQWire.string(data["lyric"])
        let text = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        return TimedLyric.parse(text)
    }
}

struct QQMusicLoginView: View {
    @ObservedObject var account: QQMusicSpace
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在 QQ 音乐官网登录，完成后点下方同步。登录信息只保存在这台设备。").font(.caption).foregroundStyle(.secondary).padding()
                QQLoginWeb(account: account)
                if let error = account.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                Button(saving ? "正在同步…" : "完成登录并同步歌单") {
                    saving = true
                    Task { if await account.completeLogin() { dismiss() }; saving = false }
                }.buttonStyle(.borderedProminent).padding().disabled(saving).accessibilityIdentifier("qq-login-sync")
            }.navigationTitle("连接 QQ 音乐").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
private struct QQLoginWeb: UIViewRepresentable {
    let account: QQMusicSpace
    func makeCoordinator() -> Coordinator { Coordinator(account: account) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = account.webStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
        Task { await account.prepareWebSession(); view.load(URLRequest(url: URL(string: "https://y.qq.com/n/ryqq/profile")!)) }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let account: QQMusicSpace
        init(account: QQMusicSpace) { self.account = account }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Task { await account.inspectLogin() } }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
            if ["mqq", "mqqapi", "mqqopensdkapi", "qqmusic", "weixin"].contains(url.scheme ?? ""), action.navigationType == .linkActivated {
                UIApplication.shared.open(url); decisionHandler(.cancel); return
            }
            let host = url.host?.lowercased() ?? ""
            let trusted = ["qq.com", "tencent.com", "qqmusic.com", "gtimg.com", "qpic.cn"].contains { host == $0 || host.hasSuffix("." + $0) }
            decisionHandler(url.scheme == "https" && trusted ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Keep the official popup in the same isolated cookie store.
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }
    }
}
