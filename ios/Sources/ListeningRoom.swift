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
    var qqMID: String? = nil
    var mediaMID: String? = nil
    var artwork: String? = nil
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
    let qq = QQMusicSpace()
    @Published private(set) var queue: [ListeningTrack] = []
    @Published private(set) var current: ListeningTrack?
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var resolving = false
    @Published private(set) var lyrics: [TimedLyric] = []
    @Published private(set) var sharedAt: Date?
    @Published private(set) var listenedSeconds: Double = UserDefaults.standard.double(forKey: "listening_seconds")
    @Published var mode = 0
    @Published var error: String?
    @Published var sharing = UserDefaults.standard.bool(forKey: "listening_share") { didSet { UserDefaults.standard.set(sharing, forKey: "listening_share"); lastSync = .distantPast } }
    private let player = AVPlayer()
    private var observer: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var lastSync = Date.distantPast
    private var lastPayload: String?
    private var pauseListener: AnyCancellable?
    private var endListener: AnyCancellable?
    private var playRequest = UUID()
    private var resolvingTrackID: String?
    private var itemRequest = UUID()
    private var artworkImage: UIImage?
    private var lastTick = Date.now
    init() {
        if let data = UserDefaults.standard.data(forKey: "listening_queue"), let items = try? JSONDecoder().decode([ListeningTrack].self, from: data) { queue = items }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let length = self.player.currentItem?.duration.seconds ?? 0
                self.duration = length.isFinite ? max(0, length) : 0
                let elapsed = Date.now.timeIntervalSince(self.lastTick); self.lastTick = .now
                if self.playing && elapsed > 0 && elapsed < 3 {
                    self.listenedSeconds += elapsed
                    UserDefaults.standard.set(self.listenedSeconds, forKey: "listening_seconds")
                }
                self.nowPlaying()
            }
        }
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.playing = (self?.player.rate ?? 0) > 0; self?.nowPlaying() } }
        pauseListener = NotificationCenter.default.publisher(for: .morrowPauseListening).sink { [weak self] _ in Task { @MainActor in self?.pause() } }
        endListener = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).sink { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                if self.mode == 1 { self.seek(0); self.resume() } else { self.next() }
            }
        }
        let remote = MPRemoteCommandCenter.shared()
        remote.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        remote.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        remote.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        remote.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        remote.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
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
    func add(_ track: ListeningTrack) {
        guard ListeningTrack.validURL(track.url) != nil, !queue.contains(where: { $0.url == track.url }), queue.count < 300 else { return }
        queue.append(track); persist(); error = nil
    }
    func remove(_ track: ListeningTrack) {
        if resolvingTrackID == track.id { playRequest = UUID(); resolving = false; resolvingTrackID = nil }
        if current?.id == track.id { pause(); itemRequest = UUID(); statusObserver = nil; player.replaceCurrentItem(with: nil); current = nil; lyrics = []; sharedAt = nil; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; position = 0; duration = 0 }
        queue.removeAll { $0.id == track.id }; persist()
    }
    private func persist() { if let data = try? JSONEncoder().encode(queue) { UserDefaults.standard.set(data, forKey: "listening_queue") } }
    func play(_ track: ListeningTrack) {
        let stamp = UUID(); playRequest = stamp; resolving = false; resolvingTrackID = nil
        if track.qqMID != nil {
            resolving = true; resolvingTrackID = track.id; error = nil
            Task {
                do {
                    let url = try await qq.playbackURL(track)
                    guard self.playRequest == stamp else { return }
                    self.resolving = false; self.resolvingTrackID = nil; self.start(track, url: url)
                    let metadataStamp = self.itemRequest
                    let lyrics = await qq.lyrics(track)
                    if self.itemRequest == metadataStamp, self.current?.id == track.id { self.lyrics = lyrics }
                } catch {
                    if self.playRequest == stamp { self.resolving = false; self.resolvingTrackID = nil; self.error = error is CancellationError ? nil : error.localizedDescription }
                }
            }
            return
        }
        guard let url = ListeningTrack.validURL(track.url) else { error = "播放地址不正确"; return }
        if track.external {
            // A catalog link opens the authorized provider; it is not a playable audio URL.
            UIApplication.shared.open(url); error = "已打开\(ListeningTrack.provider(url.host ?? "") ?? "音乐平台")。外部 App 的实际播放状态无法由 Morrow 读取。"; return
        }
        start(track, url: url)
    }
    private func start(_ track: ListeningTrack, url: URL) {
        do {
            NotificationCenter.default.post(name: .morrowStopVoice, object: nil)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url); current = track; position = 0; duration = 0; error = nil; lyrics = []; sharedAt = nil; artworkImage = nil; lastTick = .now
            itemRequest = UUID()
            statusObserver = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                Task { @MainActor in if let self, let item, item === self.player.currentItem, item.status == .failed { self.error = track.qqMID == nil ? "音频未能播放，请检查音频地址" : "QQ 音乐音频暂未能播放，请重新登录或在官方 App 播放"; self.pause() } }
            }
            player.replaceCurrentItem(with: item); player.play(); nowPlaying(); lastSync = .distantPast
            if let artwork = track.artwork, let cover = QQWire.imageURL(artwork) {
                let stamp = itemRequest
                Task {
                    if let (data, _) = try? await URLSession.shared.data(from: cover), data.count < 3_000_000,
                       let image = UIImage(data: data), self.itemRequest == stamp { self.artworkImage = image; self.nowPlaying() }
                }
            }
        } catch { self.error = "音频会话未启动" }
    }
    func resume() { guard current != nil, player.currentItem != nil else { return }; try? AVAudioSession.sharedInstance().setActive(true); player.play() }
    func pause() { player.pause(); playRequest = UUID(); resolving = false; resolvingTrackID = nil; nowPlaying(); lastSync = .distantPast }
    func toggle() { playing ? pause() : resume() }
    func seek(_ value: Double) { guard value.isFinite else { return }; let target = max(0, min(duration > 0 ? duration : value, value)); player.seek(to: CMTime(seconds: target, preferredTimescale: 600)); position = target; nowPlaying(); lastSync = .distantPast }
    func next() {
        if mode == 2, let track = queue.filter({ (!$0.external || $0.qqMID != nil) && $0.id != current?.id }).randomElement() { play(track); return }
        guard let current, let index = queue.firstIndex(where: { $0.id == current.id }), index + 1 < queue.count else { pause(); return }
        for track in queue[(index + 1)...] where !track.external || track.qqMID != nil { play(track); return }; pause()
    }
    func previous() {
        if position > 3 { seek(0); return }
        guard let current, let index = queue.firstIndex(where: { $0.id == current.id }), index > 0 else { seek(0); return }
        for track in queue[..<index].reversed() where !track.external || track.qqMID != nil { play(track); return }
    }
    func disconnectQQ() async {
        if current?.qqMID != nil, let current { remove(current) }
        playRequest = UUID(); resolving = false; resolvingTrackID = nil
        queue.removeAll { $0.qqMID != nil }; persist(); await qq.disconnect()
    }
    private func nowPlaying() {
        guard let current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist.isEmpty ? "Morrow · 一起听" : current.artist, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: player.rate]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let image = artworkImage { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
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
            let trackID = current?.id
            let _: PhoneOK = try await api.request("v1/context/listening", body: data)
            lastPayload = payload
            sharedAt = sharing && trackID != nil && current?.id == trackID ? .now : nil
        } catch { self.error = "播放信息暂未同步给他" }
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
