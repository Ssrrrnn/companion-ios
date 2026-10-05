import SwiftUI

struct ListeningRoomView: View {
    @EnvironmentObject private var listening: ListeningSpace
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("companion_name") private var companionName = "他"
    @State private var login = false
    @State private var library = false
    @State private var adding = false
    @State private var showLyrics = false
    @State private var disconnect = false
    private let accent = Color(red: 0.73, green: 0.25, blue: 0.34)
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack(spacing: 16) {
                    CompanionAvatar(size: 44, user: true)
                    VStack(spacing: 4) {
                        Image(systemName: "waveform.path").foregroundStyle(accent)
                        Text(listening.sharing ? (listening.sharedAt == nil ? "等待分享播放信息" : "播放信息已分享") : "开启分享，让他知道你在听什么")
                            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity)
                    CompanionAvatar(size: 44)
                }.padding(.horizontal, 24)
                VStack(spacing: 7) {
                    Text(listening.current?.title ?? "这一首，想和你一起听").font(.system(.title2, design: .serif)).multilineTextAlignment(.center).lineLimit(2)
                    Text(listening.current?.artist.isEmpty == false ? listening.current!.artist : "让喜欢的旋律，留在我们的小家")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Button { showLyrics.toggle() } label: {
                    if showLyrics { lyricStage.frame(height: 272) }
                    else { record.frame(height: 272) }
                }.buttonStyle(.plain).accessibilityLabel(showLyrics ? "显示唱片" : "显示歌词")
                Text(showLyrics ? "轻点返回唱片" : "轻点唱片查看歌词").font(.caption2).foregroundStyle(.secondary)
                VStack(spacing: 8) {
                    Slider(value: Binding(get: { min(listening.duration, listening.position) }, set: { listening.seek($0) }), in: 0...max(1, listening.duration))
                        .tint(accent).disabled(listening.duration <= 0).accessibilityLabel("播放进度")
                    HStack { Text(time(listening.position)); Spacer(); Text(time(listening.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    HStack(spacing: 26) {
                        Button { listening.mode = (listening.mode + 1) % 3 } label: { Image(systemName: ["repeat", "repeat.1", "shuffle"][listening.mode]) }
                            .accessibilityLabel(["顺序播放", "单曲循环", "随机播放"][listening.mode])
                        Button { listening.previous() } label: { Image(systemName: "backward.end.fill").font(.title2) }.disabled(listening.current == nil).accessibilityLabel("上一首")
                        Button { listening.toggle() } label: {
                            Group {
                                if listening.resolving { ProgressView().tint(accent) }
                                else { Image(systemName: listening.playing ? "pause.fill" : "play.fill").font(.title) }
                            }.frame(width: 66, height: 66).background(accent.opacity(0.12), in: Circle()).overlay(Circle().stroke(accent.opacity(0.2)))
                        }.disabled(listening.current == nil || listening.resolving).accessibilityLabel(listening.playing ? "暂停" : "播放")
                        Button { listening.next() } label: { Image(systemName: "forward.end.fill").font(.title2) }.disabled(listening.current == nil).accessibilityLabel("下一首")
                        Button { library = true } label: { Image(systemName: "music.note.list") }.accessibilityLabel("我的 QQ 音乐歌单")
                    }.foregroundStyle(accent).padding(.top, 10)
                }.padding(.horizontal, 12)
                HStack {
                    Label("在小家听了 \(Int(listening.listenedSeconds / 60)) 分钟", systemImage: "headphones").font(.caption)
                    Spacer()
                    Toggle("分享给他", isOn: $listening.sharing).labelsHidden().tint(accent).accessibilityLabel("把播放信息分享给他")
                }.foregroundStyle(.secondary)
                if listening.sharing {
                    Text("\(companionName)可以看到分享的歌曲和进度，也可以在聊天里回应。")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                QQAccountCard(account: listening.qq, onLogin: { login = true }, onLibrary: { library = true }, onDisconnect: { disconnect = true })
                HStack {
                    Text("我们的播放单").font(.headline)
                    Spacer()
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("添加音乐或播客")
                }
                if listening.queue.isEmpty {
                    Text("连接 QQ 音乐，选择歌单里的一首歌，或者把播客放进来。")
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVStack(spacing: 10) {
                    ForEach(listening.queue) { track in
                        HStack(spacing: 12) {
                            MusicCover(url: track.artwork, size: 44, icon: track.kind == "podcast" ? "mic.fill" : "music.note")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.title).font(.subheadline).lineLimit(1)
                                Text(track.artist.isEmpty ? (track.qqMID != nil ? "QQ 音乐" : track.kind == "podcast" ? "播客" : "音频") : track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button { listening.play(track) } label: { Image(systemName: listening.current?.id == track.id && listening.playing ? "waveform" : "play.circle") }.accessibilityLabel("播放 " + track.title)
                        }.padding(14).glassSurface(in: RoundedRectangle(cornerRadius: 20))
                            .contextMenu {
                                Button("移除", role: .destructive) { listening.remove(track) }
                                if track.qqMID != nil { Link("在 QQ 音乐打开", destination: URL(string: track.url)!) }
                            }
                    }
                }
                if let error = listening.error { Text(error).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                NavigationLink(value: CompanionRoute.podcasts) {
                    HStack { Label("发现播客", systemImage: "mic"); Spacer(); Image(systemName: "arrow.up.right") }.font(.subheadline).padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 20))
                }.buttonStyle(.plain)
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity)
        }.background {
            ZStack {
                GlassWallpaper()
                LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.18 : 0.09), .clear], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            }
        }.navigationTitle("一起听").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $login) { QQMusicLoginView(account: listening.qq) }
            .sheet(isPresented: $library) { QQMusicLibraryView(account: listening.qq, onConnect: { library = false; login = true }) }
            .sheet(isPresented: $adding) { AddListeningView() }
            .confirmationDialog("断开 QQ 音乐？本机登录信息和 QQ 播放单会被清除。", isPresented: $disconnect, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) { Task { await listening.disconnectQQ() } }
            }
            .task { if !ProcessInfo.processInfo.arguments.contains("--ui-preview"), listening.qq.connected, listening.qq.refreshedAt == nil { await listening.qq.refresh() } }
    }
    private var record: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !listening.playing || reduceMotion)) { context in
            ZStack {
                Circle().fill(accent.opacity(0.08)).frame(width: 272, height: 272)
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(white: 0.20), .black, Color(white: 0.14)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    ForEach(0..<9) { index in Circle().stroke(.white.opacity(0.055), lineWidth: 1).padding(CGFloat(9 + index * 8)) }
                    MusicCover(url: listening.current?.artwork, size: 146, icon: listening.current?.kind == "podcast" ? "mic.fill" : "music.note").clipShape(Circle())
                    Circle().fill(.black.opacity(0.85)).frame(width: 14, height: 14).overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 2))
                }.frame(width: 248, height: 248)
                    .rotationEffect(.degrees(listening.playing && !reduceMotion ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 20) * 18 : 0))
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 12)
            }.frame(maxWidth: .infinity)
        }
    }
    private var lyricStage: some View {
        VStack(spacing: 16) {
            if listening.lyrics.isEmpty {
                Image(systemName: "text.quote").font(.largeTitle).foregroundStyle(accent.opacity(0.5))
                Text(listening.current == nil ? "选一首歌，歌词会在这里展开" : "这首歌暂时没有可用歌词").font(.subheadline).foregroundStyle(.secondary)
            } else {
                let index = listening.lyrics.lastIndex(where: { $0.time <= listening.position }) ?? 0
                ForEach(max(0, index - 2)..<min(listening.lyrics.count, index + 3), id: \.self) { line in
                    Text(listening.lyrics[line].text).font(line == index ? .headline : .subheadline)
                        .foregroundStyle(line == index ? accent : .secondary).multilineTextAlignment(.center).lineLimit(2)
                }
            }
        }.frame(maxWidth: .infinity)
    }
    private func time(_ value: Double) -> String { let seconds = Int(max(0, value)); return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

struct MusicCover: View {
    let url: String?
    var size: CGFloat = 52
    var icon = "music.note"
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(homeAccent.opacity(0.14))
            Image(systemName: icon).font(.system(size: size * 0.32)).foregroundStyle(homeAccent)
            if let url, let safe = QQWire.imageURL(url) {
                AsyncImage(url: safe) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
private struct QQAccountCard: View {
    @ObservedObject var account: QQMusicSpace
    let onLogin: () -> Void
    let onLibrary: () -> Void
    let onDisconnect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MusicCover(url: account.avatar, size: 42, icon: "person.crop.circle")
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.connected ? account.nickname : "连接 QQ 音乐").font(.subheadline.weight(.semibold))
                    Text(account.connected ? (account.refreshedAt == nil ? "已保存登录，歌单待同步" : account.membership.label) : "把你的歌单带进小家").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.busy { ProgressView() }
                else if account.connected { Button { Task { await account.refresh() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("刷新 QQ 音乐账号") }
            }
            if account.connected {
                HStack {
                    Button("我的歌单", action: onLibrary).buttonStyle(.borderedProminent).accessibilityIdentifier("qq-library")
                    Spacer()
                    Menu { Button("重新登录", action: onLogin); Button("断开连接", role: .destructive, action: onDisconnect) } label: { Image(systemName: "ellipsis") }.accessibilityLabel("QQ 音乐账号设置")
                }
                if let date = account.refreshedAt { Text("歌单更新于 \(date.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
            } else {
                Button("登录并同步歌单", action: onLogin).buttonStyle(.borderedProminent).accessibilityIdentifier("qq-connect")
            }
            if let error = account.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
    }
}

struct QQMusicLibraryView: View {
    @ObservedObject var account: QQMusicSpace
    @EnvironmentObject private var listening: ListeningSpace
    @Environment(\.dismiss) private var dismiss
    let onConnect: () -> Void
    @State private var query = ""
    @State private var results: [ListeningTrack] = []
    @State private var searching = false
    @State private var searchError: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        TextField("搜索 QQ 音乐歌曲", text: $query).submitLabel(.search).onSubmit { search() }
                        Button { search() } label: { if searching { ProgressView() } else { Image(systemName: "magnifyingglass") } }.disabled(searching || !account.connected).accessibilityLabel("搜索歌曲")
                    }.padding(14).glassSurface(in: RoundedRectangle(cornerRadius: 18))
                    if let searchError { Text(searchError).font(.caption).foregroundStyle(.secondary) }
                    ForEach(results) { track in QQSongRow(track: track) }
                    if !account.connected { Button("连接 QQ 音乐账号", action: onConnect).buttonStyle(.borderedProminent) }
                    else if account.playlists.isEmpty {
                        Text(account.busy ? "正在读取你的歌单…" : "暂时没有同步到歌单，可以刷新或重新登录。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(account.playlists) { playlist in
                        NavigationLink {
                            QQPlaylistView(account: account, playlist: playlist)
                        } label: {
                            HStack(spacing: 14) {
                                MusicCover(url: playlist.cover, size: 58, icon: playlist.id == "liked" ? "heart.fill" : "music.note.list")
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(playlist.title.isEmpty ? "QQ 音乐歌单" : playlist.title).font(.subheadline).foregroundStyle(.primary)
                                    Text("\(playlist.count) 首 · \(playlist.collected ? "收藏" : "创建")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(14).glassSurface(in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain)
                    }
                    if let error = account.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.padding(20)
            }.background { GlassWallpaper() }.navigationTitle("我的 QQ 音乐")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button { Task { await account.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(account.busy || !account.connected).accessibilityLabel("刷新歌单") }
                }
        }
    }
    private func search() {
        let text = query; searching = true; searchError = nil
        Task {
            do { results = try await account.search(text); if results.isEmpty { searchError = "暂未找到歌曲，试试歌名和歌手" } }
            catch { searchError = error.localizedDescription }
            searching = false
        }
    }
}
private struct QQPlaylistView: View {
    @ObservedObject var account: QQMusicSpace
    let playlist: QQPlaylist
    @EnvironmentObject private var listening: ListeningSpace
    @State private var songs: [ListeningTrack] = []
    @State private var offset = 0
    @State private var more = true
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) { MusicCover(url: playlist.cover, size: 90); VStack(alignment: .leading, spacing: 8) { Text(playlist.title).font(.headline); Text("\(playlist.count) 首歌曲").font(.caption).foregroundStyle(.secondary) } }
                Button("将已加载歌曲加入播放单") { for song in songs { listening.add(song) } }.buttonStyle(.bordered).disabled(songs.isEmpty)
                ForEach(songs) { track in QQSongRow(track: track) }
                if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if more { Button(busy ? "读取中…" : songs.isEmpty ? "读取歌曲" : "加载更多") { load() }.disabled(busy) }
                if !more && songs.isEmpty { Text("这个歌单还没有歌曲").foregroundStyle(.secondary) }
            }.padding(20)
        }.background { GlassWallpaper() }.navigationTitle(playlist.title).navigationBarTitleDisplayMode(.inline).task { if songs.isEmpty { load() } }
    }
    private func load() {
        guard !busy else { return }; busy = true; error = nil
        Task {
            do {
                let page = try await account.songs(in: playlist, offset: offset)
                let existingIDs = Set(songs.map(\.id))
                let canContinue = page.canContinue(after: existingIDs, offset: offset)
                var ids = existingIDs; songs += page.songs.filter { ids.insert($0.id).inserted }
                if page.hasMore && !canContinue { error = "QQ 音乐没有返回下一页新歌曲，已保留加载的内容。" }
                offset = page.nextOffset; more = canContinue
            } catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}
private struct QQSongRow: View {
    let track: ListeningTrack
    @EnvironmentObject private var listening: ListeningSpace
    var body: some View {
        HStack(spacing: 12) {
            MusicCover(url: track.artwork, size: 44)
            VStack(alignment: .leading, spacing: 4) { Text(track.title).font(.subheadline).lineLimit(1); Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Button { listening.add(track); listening.play(track) } label: { Image(systemName: "play.circle.fill").font(.title2) }.accessibilityLabel("播放 " + track.title)
        }.padding(12).glassSurface(in: RoundedRectangle(cornerRadius: 18))
            .contextMenu { Button("加入播放单") { listening.add(track) }; Link("在 QQ 音乐打开", destination: URL(string: track.url)!) }
    }
}
private struct AddListeningView: View {
    @EnvironmentObject private var listening: ListeningSpace
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var url = ""
    @State private var feed = ""
    @State private var kind = "music"
    @State private var importing = false
    @State private var episodes: [ListeningTrack] = []
    var body: some View {
        NavigationStack {
            Form {
                Section("歌曲或音频") {
                    TextField("名称", text: $title)
                    TextField("HTTPS 音频或音乐平台链接", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("类型", selection: $kind) { Text("音乐").tag("music"); Text("播客").tag("podcast") }
                    Button("加入播放单") { if listening.add(title: title, url: url, kind: kind) { dismiss() } }
                    Text("QQ 音乐歌曲请从账号歌单选择；其他平台链接会在官方平台打开。").font(.caption).foregroundStyle(.secondary)
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
            }.navigationTitle("收一段声音").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
