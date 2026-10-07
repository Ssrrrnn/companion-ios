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
    @Published private(set) var selectedTrackID: String?
    @Published private(set) var loadingPlaylist: String?
    @Published private(set) var playing = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var resolving = false
    @Published private(set) var lyrics: [TimedLyric] = []
    @Published private(set) var sharedAt: Date?
    @Published private(set) var listenedSeconds: Double = 0
    @Published var mode = 0
    @Published var error: String?
    @Published var sharing = false { didSet { defaults.set(sharing, forKey: "listening_share"); lastSync = .distantPast } }
    private let defaults: UserDefaults
    private let playbackResolver: ((ListeningTrack) async throws -> URL)?
    private(set) var queueGeneration = UUID()
    private var playlistTask: Task<Void, Never>?
    private var activePlaylistID: String?
    var radioFinished: (() -> Void)?
    var radioNext: (() -> Void)?
    var radioPrevious: (() -> Void)?
    var radioToggle: (() -> Void)?
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
    init(defaults: UserDefaults = .standard, playbackResolver: ((ListeningTrack) async throws -> URL)? = nil, systemControls: Bool = true) {
        self.defaults = defaults; self.playbackResolver = playbackResolver
        listenedSeconds = defaults.double(forKey: "listening_seconds"); sharing = defaults.bool(forKey: "listening_share")
        if let data = defaults.data(forKey: "listening_queue"), let items = try? JSONDecoder().decode([ListeningTrack].self, from: data) { queue = ListeningQueue.merged([], items) }
        guard systemControls else { return }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let length = self.player.currentItem?.duration.seconds ?? 0
                self.duration = length.isFinite ? max(0, length) : 0
                let elapsed = Date.now.timeIntervalSince(self.lastTick); self.lastTick = .now
                if self.playing && elapsed > 0 && elapsed < 3 {
                    self.listenedSeconds += elapsed
                    self.defaults.set(self.listenedSeconds, forKey: "listening_seconds")
                }
                self.nowPlaying()
            }
        }
        rateObserver = player.observe(\.rate, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.playing = (self?.player.rate ?? 0) > 0; self?.nowPlaying() } }
        pauseListener = NotificationCenter.default.publisher(for: .morrowPauseListening).sink { [weak self] _ in Task { @MainActor in self?.pause() } }
        endListener = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime).sink { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
                if self.current?.kind == "radio" { self.radioFinished?(); return }
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
        guard ListeningTrack.validURL(url) != nil, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { error = "填写名称和 HTTPS 链接"; return false }
        guard !queue.contains(where: { $0.url == url }) else { error = "这条已经在歌单里"; return false }
        return add(ListeningTrack(title: String(title.prefix(200)), url: url, kind: kind))
    }
    @discardableResult func add(_ track: ListeningTrack) -> Bool {
        let track = ListeningQueue.normalized(track)
        guard ListeningTrack.validURL(track.url) != nil else { error = "歌曲链接不支持"; return false }
        if queue.contains(where: { ListeningQueue.key($0) == ListeningQueue.key(track) }) { return true }
        guard queue.count < ListeningQueue.limit else { error = "播放单已达到 5000 首，请先移除一些歌曲"; return false }
        queueChanged(); queue = ListeningQueue.merged(queue, [track]); persist(); error = nil; return true
    }
    func remove(_ track: ListeningTrack) {
        remove(ids: [track.id])
    }
    func remove(ids: Set<String>) {
        if let id = resolvingTrackID, ids.contains(id) { playRequest = UUID(); resolving = false; resolvingTrackID = nil }
        if let id = current?.id, ids.contains(id) { pause(); itemRequest = UUID(); statusObserver = nil; player.replaceCurrentItem(with: nil); current = nil; lyrics = []; sharedAt = nil; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; position = 0; duration = 0 }
        if let id = selectedTrackID, ids.contains(id) { selectedTrackID = nil; error = nil }
        queueChanged(); queue.removeAll { ids.contains($0.id) }; persist()
    }
    func clearQueue() {
        var ids = Set(queue.map(\.id))
        if let id = current?.id { ids.insert(id) }
        if let id = selectedTrackID { ids.insert(id) }
        remove(ids: ids); error = nil
    }
    @discardableResult func replaceQueue(_ tracks: [ListeningTrack], startingAt selected: ListeningTrack) -> UUID? {
        let items = ListeningQueue.merged([], tracks)
        guard let track = items.first(where: { ListeningQueue.key($0) == ListeningQueue.key(ListeningQueue.normalized(selected)) }) else { error = "这首歌尚未加载到播放单"; return nil }
        queueChanged(); queue = items; persist(); play(track); return queueGeneration
    }
    @discardableResult func appendPlaylistTracks(_ tracks: [ListeningTrack], generation: UUID) -> Bool {
        guard generation == queueGeneration else { return false }
        queue = ListeningQueue.merged(queue, tracks); persist()
        if queue.count >= ListeningQueue.limit { error = "已加入前 5000 首歌曲"; return false }
        return true
    }
    private func queueChanged() { queueGeneration = UUID(); playlistTask?.cancel(); playlistTask = nil; loadingPlaylist = nil; activePlaylistID = nil }
    func playPlaylist(_ playlist: QQPlaylist, songs: [ListeningTrack], from selected: ListeningTrack, offset: Int, more: Bool) {
        if activePlaylistID == playlist.id, queue.contains(where: { ListeningQueue.key($0) == ListeningQueue.key(selected) }) { play(selected); return }
        guard let stamp = replaceQueue(songs, startingAt: selected) else { return }
        activePlaylistID = playlist.id
        guard more else { return }
        loadingPlaylist = playlist.title
        playlistTask = Task {
            var offset = offset, more = more
            do {
                for _ in 0..<50 {
                    guard !Task.isCancelled, stamp == queueGeneration, more else { break }
                    let page = try await qq.songs(in: playlist, offset: offset)
                    guard !Task.isCancelled, stamp == queueGeneration else { return }
                    let canContinue = page.canContinue(after: Set(queue.map(\.id)), offset: offset)
                    guard appendPlaylistTracks(page.songs, generation: stamp) else { break }
                    if page.hasMore && !canContinue { throw ConnectionError.server("QQ 音乐未返回后续新歌曲") }
                    offset = page.nextOffset; more = canContinue
                }
            } catch {
                if !Task.isCancelled, stamp == queueGeneration { self.error = "已载入 \(queue.count) 首，后续歌曲暂未读完：" + error.localizedDescription }
            }
            if stamp == queueGeneration { loadingPlaylist = nil; playlistTask = nil }
        }
    }
    private func persist() { if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: "listening_queue") } }
    func play(_ track: ListeningTrack) {
        NotificationCenter.default.post(name: .morrowStopRadio, object: nil)
        NotificationCenter.default.post(name: .morrowStopCall, object: nil)
        let normalized = ListeningQueue.normalized(track)
        guard add(normalized), let track = queue.first(where: { ListeningQueue.key($0) == ListeningQueue.key(normalized) }) else { return }
        selectedTrackID = track.id
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") { error = "预览歌曲不会请求音乐服务"; return }
        #endif
        let stamp = UUID(); playRequest = stamp; resolving = false; resolvingTrackID = nil
        if track.qqMID != nil {
            player.pause()
            resolving = true; resolvingTrackID = track.id; error = nil
            Task {
                do {
                    let url: URL
                    if let resolver = self.playbackResolver { url = try await resolver(track) }
                    else { url = try await qq.playbackURL(track) }
                    guard self.playRequest == stamp else { return }
                    self.resolving = false; self.resolvingTrackID = nil; self.start(track, url: url)
                    let metadataStamp = self.itemRequest
                    let lyrics = await qq.lyrics(track)
                    if self.itemRequest == metadataStamp, self.current?.id == track.id { self.lyrics = lyrics }
                } catch {
                    if self.playRequest == stamp { self.resolving = false; self.resolvingTrackID = nil; self.error = error is CancellationError ? nil : "「\(track.title)」：" + error.localizedDescription }
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
    func prepareForRadio() {
        pause(); itemRequest = UUID(); statusObserver = nil; player.replaceCurrentItem(with: nil)
        current = nil; selectedTrackID = nil; position = 0; duration = 0; lyrics = []; sharedAt = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func playRadio(title: String, programID: UUID, part: Int, url: URL) {
        guard url.isFileURL else { return }
        playRequest = UUID(); resolving = false; resolvingTrackID = nil; selectedTrackID = nil
        let track = ListeningTrack(id: "radio-\(programID)-\(part)", title: title, url: "", kind: "radio", artist: "Morrow · 他的电台")
        start(track, url: url)
    }
    func stopRadio() {
        guard current?.kind == "radio" else { return }
        pause(); itemRequest = UUID(); statusObserver = nil; player.replaceCurrentItem(with: nil)
        current = nil; position = 0; duration = 0; lyrics = []; sharedAt = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    private func start(_ track: ListeningTrack, url: URL) {
        do {
            NotificationCenter.default.post(name: .morrowStopCall, object: nil)
            NotificationCenter.default.post(name: .morrowStopVoice, object: nil)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url); current = track; position = 0; duration = 0; error = nil; lyrics = []; sharedAt = nil; artworkImage = nil; lastTick = .now
            itemRequest = UUID()
            statusObserver = item.observe(\.status, options: [.new]) { [weak self, weak item] _, _ in
                Task { @MainActor in if let self, let item, item === self.player.currentItem, item.status == .failed { self.error = track.kind == "radio" ? "这段电台音频未能播放，请重新准备节目。" : track.qqMID == nil ? "音频未能播放，请检查音频地址" : "QQ 音乐音频暂未能播放，请重新登录或在官方 App 播放"; self.pause() } }
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
    func resume() {
        guard let current, player.currentItem != nil else { return }
        NotificationCenter.default.post(name: .morrowStopCall, object: nil)
        NotificationCenter.default.post(name: .morrowStopVoice, object: nil)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: current.kind == "radio" ? .spokenAudio : .default)
            try AVAudioSession.sharedInstance().setActive(true)
            player.play()
        } catch { error = "音频会话未启动" }
    }
    func pause() { player.pause(); playRequest = UUID(); resolving = false; resolvingTrackID = nil; nowPlaying(); lastSync = .distantPast }
    func toggle() {
        if current?.kind == "radio", let radioToggle { radioToggle(); return }
        if let selected = queue.first(where: { $0.id == selectedTrackID }), selected.id != current?.id { play(selected) }
        else if current == nil, let first = ListeningQueue.candidate(in: queue, selectedID: nil, forward: true) { play(first) }
        else { playing ? pause() : resume() }
    }
    func seek(_ value: Double) { guard value.isFinite else { return }; let target = max(0, min(duration > 0 ? duration : value, value)); player.seek(to: CMTime(seconds: target, preferredTimescale: 600)); position = target; nowPlaying(); lastSync = .distantPast }
    func next() {
        if current?.kind == "radio" { radioNext?(); return }
        if mode == 2, let track = queue.filter({ (!$0.external || $0.qqMID != nil) && $0.id != selectedTrackID }).randomElement() { play(track); return }
        if let track = ListeningQueue.candidate(in: queue, selectedID: selectedTrackID ?? current?.id, forward: true) { play(track) } else { pause() }
    }
    func previous() {
        if current?.kind == "radio" { if position > 3 { seek(0) } else { radioPrevious?() }; return }
        if selectedTrackID == current?.id, position > 3 { seek(0); return }
        if let track = ListeningQueue.candidate(in: queue, selectedID: selectedTrackID ?? current?.id, forward: false) { play(track) } else { seek(0) }
    }
    func disconnectQQ() async {
        if current?.qqMID != nil, let current { remove(current) }
        playRequest = UUID(); resolving = false; resolvingTrackID = nil
        remove(ids: Set(queue.filter { $0.qqMID != nil }.map(\.id))); await qq.disconnect()
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
            if sharing, let current, current.kind != "radio" { data = try JSONSerialization.data(withJSONObject: ["title": current.title, "url": current.url, "kind": current.kind, "playing": playing, "position": max(0, min(86400, position))]) }
            else { data = Data("null".utf8) }
            let payload = String(decoding: data, as: UTF8.self)
            guard payload != lastPayload else { return }
            let trackID = current?.id
            let _: PhoneOK = try await api.request("v1/context/listening", body: data)
            lastPayload = payload
            sharedAt = sharing && current?.kind != "radio" && trackID != nil && current?.id == trackID ? .now : nil
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
    static let morrowStopRadio = Notification.Name("morrow-stop-radio")
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
