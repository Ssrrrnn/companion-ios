import SwiftUI
import AVFoundation
import MediaPlayer
import Combine

struct ListeningTrack: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    let title: String
    let url: String
    let kind: String
    var artist: String = ""
    var external: Bool { Self.provider(URL(string: url)?.host ?? "") != nil }
    static func provider(_ host: String) -> String? {
        let host = host.lowercased()
        if host == "music.163.com" || host.hasSuffix(".music.163.com") || host == "163cn.tv" { return "网易云音乐" }
        if host == "y.qq.com" || host.hasSuffix(".y.qq.com") || host == "c6.y.qq.com" { return "QQ 音乐" }
        return nil
    }
    static func validURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
final class PodcastFeed: NSObject, XMLParserDelegate {
    private var title = "", enclosure = "", author = "", element = "", text = "", inItem = false
    private(set) var episodes: [ListeningTrack] = []
    func parse(_ data: Data) throws -> [ListeningTrack] {
        guard data.count <= 2_000_000, !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw ConnectionError.server("播客源过大或格式不支持") }
        let parser = XMLParser(data: data); parser.delegate = self; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw ConnectionError.server("播客 RSS 解析未完成") }
        return episodes
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        element = name; text = ""
        if name == "item" { inItem = true; title = ""; enclosure = ""; author = "" }
        if inItem && name == "enclosure", let url = attributes["url"], ListeningTrack.validURL(url) != nil { enclosure = url }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if inItem {
            if name == "title" { title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if name == "itunes:author" { author = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            if name == "item" {
                if !enclosure.isEmpty && episodes.count < 100 { episodes.append(ListeningTrack(title: String(title.prefix(200)), url: enclosure, kind: "podcast", artist: String(author.prefix(150)))) }
                inItem = false
            }
        }
        text = ""
    }
}
@MainActor
final class ListeningSpace: ObservableObject {
    @Published private(set) var queue: [ListeningTrack] = []
    @Published private(set) var current: ListeningTrack?
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var error: String?
    @Published var sharing = UserDefaults.standard.bool(forKey: "listening_share") { didSet { UserDefaults.standard.set(sharing, forKey: "listening_share"); lastSync = .distantPast } }
    private let player = AVPlayer()
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var lastSync = Date.distantPast
    private var lastPayload: String?
    private var pauseListener: AnyCancellable?
    init() {
        if let data = UserDefaults.standard.data(forKey: "listening_queue"), let items = try? JSONDecoder().decode([ListeningTrack].self, from: data) { queue = items }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let length = self.player.currentItem?.duration.seconds ?? 0
                self.duration = length.isFinite ? max(0, length) : 0
                self.nowPlaying()
            }
        }
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.playing = (self?.player.rate ?? 0) > 0; self?.nowPlaying() } }
        pauseListener = NotificationCenter.default.publisher(for: .morrowPauseListening).sink { [weak self] _ in Task { @MainActor in self?.pause() } }
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        }
        remote.skipForwardCommand.preferredIntervals = [15]
        remote.skipBackwardCommand.preferredIntervals = [15]
        remote.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in if let self { self.seek(self.position + 15) } }; return .success }
        remote.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in if let self { self.seek(self.position - 15) } }; return .success }
    }
    func add(title: String, url: String, kind: String) -> Bool {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ListeningTrack.validURL(url) != nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, queue.count < 300 else { error = "填写名称和 HTTPS 链接，最多保存 300 条"; return false }
        guard !queue.contains(where: { $0.url == url }) else { error = "这条已经在歌单里"; return false }
        queue.append(ListeningTrack(title: String(title.prefix(200)), url: url, kind: kind)); persist(); error = nil; return true
    }
    func add(_ track: ListeningTrack) { _ = add(title: track.title, url: track.url, kind: track.kind) }
    func remove(_ track: ListeningTrack) {
        if current?.id == track.id { pause(); player.replaceCurrentItem(with: nil); current = nil; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; position = 0; duration = 0 }
        queue.removeAll { $0.id == track.id }; persist()
    }
    private func persist() { if let data = try? JSONEncoder().encode(queue) { UserDefaults.standard.set(data, forKey: "listening_queue") } }
    func play(_ track: ListeningTrack) {
        guard let url = ListeningTrack.validURL(track.url) else { error = "播放地址不正确"; return }
        if track.external {
            // A catalog link opens the authorized provider; it is not a playable audio URL.
            UIApplication.shared.open(url); error = "已打开\(ListeningTrack.provider(url.host ?? "") ?? "音乐平台")。外部 App 的实际播放状态无法由 Morrow 读取。"; return
        }
        do {
            NotificationCenter.default.post(name: .morrowStopVoice, object: nil)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url); current = track; position = 0; duration = 0; error = nil
            statusObserver = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                Task { @MainActor in if item?.status == .failed { self?.error = "音频未能播放，请使用可直接播放的音频地址"; self?.pause() } }
            }
            player.replaceCurrentItem(with: item); player.play(); nowPlaying(); lastSync = .distantPast
        } catch { self.error = "音频会话未启动" }
    }
    func resume() { guard current != nil, player.currentItem != nil else { return }; try? AVAudioSession.sharedInstance().setActive(true); player.play() }
    func pause() { player.pause(); nowPlaying(); lastSync = .distantPast }
    func toggle() { playing ? pause() : resume() }
    func seek(_ value: Double) { guard value.isFinite else { return }; player.seek(to: CMTime(seconds: max(0, min(duration > 0 ? duration : value, value)), preferredTimescale: 600)); position = max(0, value); nowPlaying() }
    func next() {
        guard let current, let index = queue.firstIndex(where: { $0.id == current.id }), index + 1 < queue.count else { pause(); return }
        for track in queue[(index + 1)...] where !track.external { play(track); return }; pause()
    }
    private func nowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist.isEmpty ? "Morrow · 一起听" : current.artist, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: player.rate]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }
    func sync(api: CompanionAPI) async {
        guard Date.now.timeIntervalSince(lastSync) > 20 else { return }
        lastSync = .now
        do {
            let data: Data
            if sharing, let current { data = try JSONSerialization.data(withJSONObject: ["title": current.title, "url": current.url, "kind": current.kind, "playing": playing, "position": max(0, min(86400, position))]) }
            else { data = Data("null".utf8) }
            let payload = String(decoding: data, as: UTF8.self)
            guard payload != lastPayload else { return }
            let _: PhoneOK = try await api.request("v1/context/listening", body: data)
            lastPayload = payload
        } catch { error = "播放信息暂未同步给他" }
    }
    func episodes(feed: String) async throws -> [ListeningTrack] {
        guard let url = ListeningTrack.validURL(feed) else { throw ConnectionError.server("填写 HTTPS 播客 RSS 地址") }
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.server("播客源未返回内容") }
        var data = Data()
        for try await byte in bytes { data.append(byte); if data.count > 2_000_000 { throw ConnectionError.server("播客源过大") } }
        return try PodcastFeed().parse(data)
    }
}
extension Notification.Name {
    static let morrowPauseListening = Notification.Name("morrow-pause-listening")
    static let morrowStopVoice = Notification.Name("morrow-stop-voice")
}
struct ListeningHomeCard: View {
    @EnvironmentObject private var listening: ListeningSpace
    var body: some View {
        NavigationLink(value: CompanionRoute.listening) {
            HStack(spacing: 16) {
                ZStack { Circle().fill(homeAccent.opacity(0.10)); Circle().stroke(homeAccent.opacity(0.15), lineWidth: 8).padding(10); Image(systemName: listening.playing ? "waveform" : "music.note").font(.title3).foregroundStyle(homeAccent) }.frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 6) {
                    Text("一起听").font(.system(.title3, design: .serif)).foregroundStyle(.primary)
                    Text(listening.current?.title ?? "给两个人，留一段声音").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
            }.padding(20).glassSurface(in: RoundedRectangle(cornerRadius: 25))
        }.buttonStyle(.plain).accessibilityIdentifier("home-listening")
    }
}
struct ListeningRoomView: View {
    @EnvironmentObject private var listening: ListeningSpace
    @State private var title = "", url = "", feed = "", kind = "music"
    @State private var adding = false, importing = false
    @State private var episodes: [ListeningTrack] = []
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 20) {
                    ZStack {
                        Circle().fill(.black.opacity(0.85)).frame(width: 200, height: 200)
                        ForEach(0..<5) { index in Circle().stroke(.white.opacity(0.08), lineWidth: 1).frame(width: CGFloat(180 - index * 20), height: CGFloat(180 - index * 20)) }
                        Circle().fill(homeAccent).frame(width: 68, height: 68)
                        Image(systemName: listening.current?.kind == "podcast" ? "mic.fill" : "music.note").foregroundStyle(.white).font(.title2)
                    }.shadow(color: .black.opacity(0.12), radius: 15, y: 8)
                    VStack(spacing: 6) {
                        Text(listening.current?.title ?? "把喜欢的声音放进来").font(.system(.title3, design: .serif)).multilineTextAlignment(.center)
                        Text(listening.current?.artist.isEmpty == false ? listening.current!.artist : "Morrow · 一起听").font(.caption).foregroundStyle(.secondary)
                    }
                    if listening.duration > 0 {
                        Slider(value: Binding(get: { min(listening.duration, listening.position) }, set: { listening.seek($0) }), in: 0...max(1, listening.duration)).accessibilityLabel("播放进度")
                        HStack { Text(time(listening.position)); Spacer(); Text(time(listening.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 32) {
                        Button { listening.seek(listening.position - 15) } label: { Image(systemName: "gobackward.15") }
                        Button { listening.toggle() } label: { Image(systemName: listening.playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 62, height: 62).background(homeAccent.opacity(0.12), in: Circle()) }.accessibilityLabel(listening.playing ? "暂停" : "播放")
                        Button { listening.next() } label: { Image(systemName: "forward.end.fill") }
                    }.font(.title3).disabled(listening.current == nil)
                    Toggle("把播放信息分享给他", isOn: $listening.sharing).font(.subheadline)
                    Text("Morrow 音频支持锁屏、控制中心和后台播放。他能读取你分享的歌曲与进度；双端同步播放尚未接入。").font(.caption).foregroundStyle(.secondary)
                }.padding(24).glassSurface(in: RoundedRectangle(cornerRadius: 30))
                HStack(spacing: 12) {
                    Link(destination: URL(string: "https://music.163.com/")!) { Label("网易云音乐", systemImage: "music.note.list").frame(maxWidth: .infinity).padding(14).glassSurface(in: RoundedRectangle(cornerRadius: 18)) }
                    Link(destination: URL(string: "https://y.qq.com/")!) { Label("QQ 音乐", systemImage: "music.note").frame(maxWidth: .infinity).padding(14).glassSurface(in: RoundedRectangle(cornerRadius: 18)) }
                }.font(.caption)
                HStack { Text("我们的播放单").font(.headline); Spacer(); Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加音乐或播客") }
                if listening.queue.isEmpty { Text("添加音频直链、播客 RSS，或收藏 QQ／网易云的歌曲链接。平台歌曲在对应 App 播放。").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(listening.queue) { track in
                    HStack(spacing: 14) {
                        Image(systemName: track.external ? "arrow.up.right.square" : track.kind == "podcast" ? "mic" : "music.note").foregroundStyle(homeAccent)
                        VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.subheadline); Text(track.external ? "在音乐平台打开" : track.kind == "podcast" ? "播客" : "音频").font(.caption2).foregroundStyle(.secondary) }
                        Spacer(); Button { listening.play(track) } label: { Image(systemName: track.external ? "arrow.up.right" : "play.circle") }.accessibilityLabel("播放 " + track.title)
                    }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 20)).contextMenu { Button("移除", role: .destructive) { listening.remove(track) } }
                }
                if let error = listening.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }.padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle("一起听").sheet(isPresented: $adding) {
            NavigationStack {
                Form {
                    Section("歌曲或音频") {
                        TextField("名称", text: $title)
                        TextField("HTTPS 音频或音乐平台链接", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("类型", selection: $kind) { Text("音乐").tag("music"); Text("播客").tag("podcast") }
                        Button("加入播放单") { if listening.add(title: title, url: url, kind: kind) { title = ""; url = ""; adding = false } }
                        Text("QQ／网易云链接用于打开平台；Morrow 内播放需要可直接访问的音频地址。").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("导入播客") {
                        TextField("HTTPS RSS 订阅地址", text: $feed).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button(importing ? "读取中" : "读取节目") {
                            importing = true
                            Task { do { episodes = try await listening.episodes(feed: feed); if episodes.isEmpty { listening.error = "这个源没有可播放的 HTTPS 节目" } } catch { listening.error = error.localizedDescription }; importing = false }
                        }.disabled(importing)
                        ForEach(episodes) { episode in Button { listening.add(episode) } label: { Label(episode.title, systemImage: "plus.circle") } }
                    }
                    if let error = listening.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.navigationTitle("收一段声音").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { adding = false } } }
            }
        }
    }
    private func time(_ value: Double) -> String { let seconds = Int(max(0, value)); return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}
