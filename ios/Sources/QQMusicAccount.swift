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
    private var values: [String: String] { QQWire.cookieValues(cookies.filter(\.active).compactMap(\.native)) }
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
        let values = QQWire.cookieValues(raw)
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
        let values = QQWire.cookieValues(saved.compactMap(\.native))
        guard !QQWire.account(values).isEmpty, !QQWire.musicKey(values).isEmpty else {
            error = "还没有获得 QQ 音乐登录状态。请在官网完成登录，再点同步。"; return false
        }
        do {
            try QQCredentialStore.save(saved)
            let sameAccount = accountID == QQWire.account(values)
            generation = UUID(); busy = false; cookies = saved; membership = .unknown; error = nil
            if !sameAccount { playlists = []; nickname = "QQ 音乐"; avatar = ""; refreshedAt = nil }
            return await refresh()
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
    @discardableResult func refresh() async -> Bool {
        guard !busy else { return false }
        guard connected else {
            playlists = []; membership = .unknown; refreshedAt = nil; nickname = "QQ 音乐"; avatar = ""
            error = "QQ 音乐登录已失效，请重新登录"; return false
        }
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
        guard stamp == generation else { return false }
        var memberships: [QQMembership] = []
        for method in ["SRFVipQuery_V2", "SRFVipQuery"] {
            if let result = try? await rpc(module: "userInfo.VipQueryServer", method: method, params: ["uin_list": [uin]]) {
                memberships.append(QQWire.membership(result, account: uin))
            }
            guard stamp == generation else { return false }
        }
        if memberships.contains(.svip) { membership = .svip }
        else if memberships.contains(.vip) { membership = .vip }
        else if memberships.count == 2 && memberships.allSatisfy({ $0 == .ordinary }) { membership = .ordinary }
        var result = playlists
        var completed = 0
        for collected in [false, true] {
            var section: [QQPlaylist] = []
            do {
                for page in 0..<25 {
                    let start = page * 200
                    let parameters = collected
                        ? ["ct": "20", "cid": "205360956", "userid": uin, "reqtype": "3", "sin": String(start), "ein": String(start + 199)]
                        : ["hostUin": "0", "hostuin": uin, "sin": String(start), "size": "200"]
                    let endpoint = collected ? "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg" : "https://c.y.qq.com/rsc/fcgi-bin/fcg_user_created_diss"
                    let object = try await request(endpoint, params: common.merging(parameters) { _, new in new }); try checked(object)
                    guard let data = object["data"] as? [String: Any], let rows = data[collected ? "cdlist" : "disslist"] as? [[String: Any]] else { throw ConnectionError.server("这一组歌单暂未同步") }
                    section += rows.compactMap { QQWire.playlist($0, collected: collected) }
                    if rows.count < 200 { break }
                    if page == 24 { self.error = "已读取前 5000 个歌单" }
                }
                result = QQWire.replacingPlaylists(result, with: section, collected: collected); completed += 1
            } catch { if stamp == generation { self.error = collected ? "收藏歌单暂未同步，可稍后刷新" : "创建歌单暂未同步，请刷新或重新登录" } }
            guard stamp == generation else { return false }
        }
        if let page = try? await songs(in: QQPlaylist(id: "liked", title: "我喜欢", cover: "", count: 0)) {
            result.removeAll { $0.id == "liked" }
            result.insert(QQPlaylist(id: "liked", title: "我喜欢", cover: page.songs.first?.artwork ?? "", count: page.total), at: 0)
            completed += 1
        }
        guard stamp == generation else { return false }
        if completed > 0 {
            var ids = Set<String>(); playlists = result.filter { ids.insert($0.id).inserted }; refreshedAt = .now
            return true
        }
        error = "登录信息已保存在本机，但歌单尚未同步成功。请重试，或在官网重新登录。"
        return false
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
        let total = max(rows.count > 100 ? rows.count : offset + rows.count, QQWire.integer(detail["total_song_num"] ?? detail["totalSongNum"] ?? detail["songnum"] ?? playlist.count))
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var saving = false
    @State private var loading = true
    @State private var webError: String?
    @State private var reloadID = 0
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("在 QQ 音乐官网登录，完成后点下方同步。登录信息只保存在这台设备。").font(.caption).foregroundStyle(.secondary).padding()
                HStack {
                    if loading { ProgressView().controlSize(.small) }
                    Text(account.loginReady ? "已检测到音乐登录，点下方同步" : "等待官网完成登录")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("qq-login-status")
                    Spacer()
                    Button("重新载入") { reloadID += 1 }.font(.caption).disabled(saving)
                }.padding(.horizontal).padding(.bottom, 8)
                QQLoginWeb(account: account, loading: $loading, webError: $webError, reloadID: reloadID)
                if let webError { Text(webError).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                if let error = account.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                Button(saving ? "正在同步…" : "完成登录并同步歌单") {
                    saving = true
                    Task { if await account.completeLogin() { dismiss() }; saving = false }
                }.buttonStyle(.borderedProminent).padding().disabled(saving || account.busy).accessibilityIdentifier("qq-login-sync")
            }.navigationTitle("连接 QQ 音乐").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await account.inspectLogin() } } }
    }
}
private struct QQLoginWeb: UIViewRepresentable {
    let account: QQMusicSpace
    @Binding var loading: Bool
    @Binding var webError: String?
    let reloadID: Int
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> QQLoginContainer {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = account.webStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/18.0 Safari/605.1.15"
        let container = QQLoginContainer(main: view)
        context.coordinator.container = container
        context.coordinator.lastReload = reloadID
        account.webStore.httpCookieStore.add(context.coordinator)
        let coordinator = context.coordinator
        coordinator.preparation = Task {
            await account.prepareWebSession()
            guard !Task.isCancelled, coordinator.active else { return }
            view.load(URLRequest(url: URL(string: "https://y.qq.com/n/ryqq/profile")!))
            await account.inspectLogin()
        }
        return container
    }
    func updateUIView(_ view: QQLoginContainer, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastReload != reloadID {
            context.coordinator.lastReload = reloadID
            if let url = view.top.url, url.scheme == "https" { view.top.reload() }
            else { view.top.load(URLRequest(url: URL(string: "https://y.qq.com/n/ryqq/profile")!)) }
        }
    }
    static func dismantleUIView(_ view: QQLoginContainer, coordinator: Coordinator) {
        coordinator.active = false; coordinator.preparation?.cancel()
        coordinator.parent.account.webStore.httpCookieStore.remove(coordinator)
        view.stop()
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var parent: QQLoginWeb
        weak var container: QQLoginContainer?
        var lastReload = 0
        var active = true
        var preparation: Task<Void, Never>?
        init(parent: QQLoginWeb) { self.parent = parent }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { guard active else { return }; await parent.account.inspectLogin() }
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard active else { return }; parent.loading = true; parent.webError = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard active else { return }; parent.loading = false
            Task { await parent.account.inspectLogin() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard active else { return }; parent.loading = false; parent.webError = "登录网页已停止响应，请重新载入。"
        }
        private func failed(_ error: Error) {
            guard active, (error as NSError).code != NSURLErrorCancelled else { return }
            parent.loading = false; parent.webError = "登录网页未能加载，请检查网络后重新载入。"
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            let origin = action.sourceFrame.securityOrigin
            switch QQWire.loginNavigation(url, sourceHost: origin.host, sourceScheme: origin.protocol) {
            case .webpage: decisionHandler(.allow)
            case .app:
                decisionHandler(.cancel)
                UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                    Task { @MainActor in
                        guard let self, self.active else { return }
                        self.parent.loading = false
                        if !opened { self.parent.webError = "这台手机未能打开登录 App，请在官网选择其他登录方式。" }
                    }
                }
            case .blocked: decisionHandler(.cancel)
            }
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard active, action.targetFrame == nil, let container, let url = action.request.url,
                  QQWire.loginNavigation(url, sourceHost: action.sourceFrame.securityOrigin.host, sourceScheme: action.sourceFrame.securityOrigin.protocol) == .webpage,
                  QQWire.loginHost(action.sourceFrame.securityOrigin.host), container.popups.count < 3 else { return nil }
            // Preserve WebKit's supplied configuration and opener for the auth callback.
            let popup = WKWebView(frame: .zero, configuration: configuration)
            popup.customUserAgent = webView.customUserAgent; popup.navigationDelegate = self; popup.uiDelegate = self
            container.present(popup); return popup
        }
        func webViewDidClose(_ webView: WKWebView) {
            container?.close(webView); parent.loading = false
            Task { await parent.account.inspectLogin() }
        }
    }
}
private final class QQLoginContainer: UIView {
    let main: WKWebView
    private(set) var popups: [WKWebView] = []
    var top: WKWebView { popups.last ?? main }
    private let closeButton = UIButton(type: .system)
    init(main: WKWebView) {
        self.main = main; super.init(frame: .zero)
        addSubview(main)
        closeButton.setTitle("返回 QQ 音乐", for: .normal)
        closeButton.backgroundColor = .secondarySystemBackground
        closeButton.layer.cornerRadius = 12
        closeButton.accessibilityIdentifier = "qq-login-popup-back"
        closeButton.addAction(UIAction { [weak self] _ in if let self, let popup = self.popups.last { self.close(popup) } }, for: .touchUpInside)
        addSubview(closeButton); closeButton.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews(); main.frame = bounds
        for popup in popups { popup.frame = CGRect(x: 0, y: 48, width: bounds.width, height: max(0, bounds.height - 48)) }
        closeButton.frame = CGRect(x: 12, y: 4, width: max(0, min(180, bounds.width - 24)), height: 40)
    }
    func present(_ popup: WKWebView) {
        popups.append(popup); addSubview(popup); bringSubviewToFront(closeButton)
        closeButton.isHidden = false; setNeedsLayout()
    }
    func close(_ popup: WKWebView) {
        guard let index = popups.firstIndex(where: { $0 === popup }) else { return }
        for view in popups[index...] { view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil; view.removeFromSuperview() }
        popups.removeSubrange(index...); closeButton.isHidden = popups.isEmpty
    }
    func stop() {
        main.stopLoading(); main.navigationDelegate = nil; main.uiDelegate = nil
        if let popup = popups.first { close(popup) }
    }
}
