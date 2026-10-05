import SwiftUI

struct ListeningQueueView: View {
    @EnvironmentObject private var listening: ListeningSpace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing = false
    @State private var selected = Set<String>()
    @State private var clearing = false
    private var tracks: [ListeningTrack] {
        listening.queue.filter { query.isEmpty || $0.title.localizedStandardContains(query) || $0.artist.localizedStandardContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(listening.queue.count) 首 · 点一首直接播放，左滑可移除").font(.caption).foregroundStyle(.secondary)
                    if let error = listening.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if listening.queue.isEmpty { ContentUnavailableView("播放单还是空的", systemImage: "music.note.list", description: Text("搜索歌曲，或从 QQ 音乐歌单开始播放。")) }
                    ForEach(tracks) { track in
                        HStack(spacing: 12) {
                            if editing {
                                Button { if !selected.insert(track.id).inserted { selected.remove(track.id) } } label: { Image(systemName: selected.contains(track.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(homeAccent) }
                                    .buttonStyle(.borderless).accessibilityLabel("选择 " + track.title).accessibilityIdentifier("select-queue-" + track.id)
                            }
                            Button {
                                if editing { if !selected.insert(track.id).inserted { selected.remove(track.id) } }
                                else { listening.play(track) }
                            } label: {
                                HStack(spacing: 12) {
                                    MusicCover(url: track.artwork, size: 44, icon: track.kind == "podcast" ? "mic.fill" : "music.note")
                                    VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.subheadline).foregroundStyle(.primary).lineLimit(2); Text(track.artist.isEmpty ? (track.qqMID != nil ? "QQ 音乐" : "音频") : track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                    Spacer(minLength: 0)
                                    if listening.selectedTrackID == track.id {
                                        if listening.resolving { ProgressView() }
                                        else { Image(systemName: listening.playing && listening.current?.id == track.id ? "waveform" : "play.circle.fill").foregroundStyle(homeAccent) }
                                    }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.borderless).accessibilityLabel("播放 " + track.title).accessibilityIdentifier("queue-track-" + track.id)
                            if !editing { Menu { Button("移除这首", role: .destructive) { listening.remove(track) } } label: { Image(systemName: "ellipsis").frame(width: 30, height: 40) }.accessibilityLabel("管理 " + track.title) }
                        }.padding(.vertical, 5)
                    }.onDelete { offsets in listening.remove(ids: Set(offsets.map { tracks[$0].id })) }
                }
            }.scrollContentBackground(.hidden).background { GlassWallpaper() }
                .searchable(text: $query, prompt: "搜索播放单")
                .navigationTitle("我们的播放单").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button(editing ? "完成" : "批量管理") { editing.toggle(); selected.removeAll() }.disabled(listening.queue.isEmpty).accessibilityIdentifier("queue-edit") }
                    ToolbarItem(placement: .bottomBar) { if !editing { Button("清空播放单", role: .destructive) { clearing = true }.disabled(listening.queue.isEmpty).accessibilityIdentifier("queue-clear") } }
                }
                .safeAreaInset(edge: .bottom) {
                    if editing {
                        HStack {
                            Button(selected.isSuperset(of: Set(tracks.map(\.id))) ? "取消全选" : "全选") {
                                let ids = Set(tracks.map(\.id)); if selected.isSuperset(of: ids) { selected.subtract(ids) } else { selected.formUnion(ids) }
                            }.disabled(tracks.isEmpty).accessibilityIdentifier("queue-select-all")
                            Spacer()
                            Button("移除所选（\(selected.count)）", role: .destructive) { listening.remove(ids: selected); selected.removeAll() }
                                .disabled(selected.isEmpty).accessibilityIdentifier("queue-remove-selected")
                        }.font(.subheadline).padding(20).background(.regularMaterial)
                    }
                }
                .confirmationDialog("清空小家的播放单？正在播放的歌曲也会停止。", isPresented: $clearing, titleVisibility: .visible) { Button("清空", role: .destructive) { listening.clearQueue(); selected.removeAll() } }
        }
    }
}

struct MusicSearchView: View {
    @ObservedObject var account: QQMusicSpace
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var activeQuery = ""
    @State private var results: [ListeningTrack] = []
    @State private var busy = false
    @State private var more = false
    @State private var nextPage = 1
    @State private var error: String?
    @State private var requestID = UUID()
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜歌名或歌手", text: $query).submitLabel(.search).autocorrectionDisabled().onSubmit { search() }.accessibilityIdentifier("music-search-input")
                        Button("搜索") { search() }.disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("music-search-submit")
                    }.padding(15).glassSurface(in: RoundedRectangle(cornerRadius: 18))
                    Text("点歌曲直接播放；歌曲菜单可以加入播放单、收藏或分享。").font(.caption).foregroundStyle(.secondary)
                    if !account.connected { Text("可以先搜索歌曲，播放 QQ 音乐时需要连接你的账号。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(results) { track in QQSongRow(track: track) }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                    if busy { ProgressView().frame(maxWidth: .infinity) }
                    else if more { Button("加载更多歌曲") { search(more: true) }.buttonStyle(.bordered) }
                    else if !activeQuery.isEmpty && results.isEmpty && error == nil { ContentUnavailableView("暂未找到歌曲", systemImage: "music.note", description: Text("试试完整歌名或歌手。")) }
                    else if activeQuery.isEmpty { ContentUnavailableView("想听哪一首？", systemImage: "magnifyingglass", description: Text("从歌名、歌手，或此刻的心情开始。")) }
                }.padding(22)
            }.background { GlassWallpaper() }.navigationTitle("搜索歌曲").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .onDisappear { requestID = UUID() }
        }
    }
    private func search(more: Bool = false) {
        let text = more ? activeQuery : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !more || !busy else { return }
        if !more { activeQuery = text; results = []; nextPage = 1 }
        let pageNumber = nextPage, stamp = UUID(); requestID = stamp; busy = true; error = nil
        Task {
            do {
                let page = try await account.searchPage(text, page: pageNumber)
                guard requestID == stamp else { return }
                let previous = Set(results.map(\.id)), offset = (pageNumber - 1) * 30
                results = ListeningQueue.merged(results, page.songs)
                self.more = pageNumber < 50 && page.canContinue(after: previous, offset: offset)
                nextPage = pageNumber + 1
            } catch { if requestID == stamp { self.error = error.localizedDescription; self.more = false } }
            if requestID == stamp { busy = false }
        }
    }
}
