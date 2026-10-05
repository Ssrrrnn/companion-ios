import SwiftUI

struct PodcastShow: Decodable, Identifiable {
    let collectionId: Int
    let collectionName: String
    let artistName: String?
    let feedUrl: String?
    let artworkUrl100: String?
    var id: Int { collectionId }
}
struct PodcastSearchResult: Decodable { let results: [PodcastShow] }
struct PodcastDiscoveryView: View {
    @State private var query = ""
    @State private var shows: [PodcastShow] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                if shows.isEmpty { ContentUnavailableView("找一段想听的声音", systemImage: "mic", description: Text(error ?? "搜索节目名称，打开后选择一集。")) }
                if loading { ProgressView("正在查找节目") }
                ForEach(shows) { show in
                    if let feed = show.feedUrl, ListeningTrack.validURL(feed) != nil {
                        NavigationLink(destination: PodcastEpisodesView(title: show.collectionName, feed: feed)) {
                            HStack(spacing: 15) {
                                AsyncImage(url: URL(string: show.artworkUrl100 ?? "")) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "mic.fill").foregroundStyle(homeAccent) }.frame(width: 58, height: 58).clipShape(RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 6) { Text(show.collectionName).font(.headline).foregroundStyle(.primary); Text(show.artistName ?? "播客").font(.caption).foregroundStyle(.secondary) }
                                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                        }.buttonStyle(.plain)
                    }
                }
                Text("节目检索由 Apple iTunes 提供，音频来自节目公开 RSS。").font(.caption2).foregroundStyle(.secondary)
            }.padding(22)
        }.background { GlassWallpaper() }.navigationTitle("发现播客")
            .searchable(text: $query, prompt: "搜索播客名称")
            .onSubmit(of: .search) { Task { await search() } }
    }
    private func search() async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !loading else { return }
        loading = true; defer { loading = false }
        do {
            var endpoint = URLComponents(string: "https://itunes.apple.com/search")!
            endpoint.queryItems = [URLQueryItem(name: "term", value: query), URLQueryItem(name: "media", value: "podcast"), URLQueryItem(name: "entity", value: "podcast"), URLQueryItem(name: "country", value: "CN"), URLQueryItem(name: "limit", value: "20")]
            var request = URLRequest(url: endpoint.url!); request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.server("节目检索暂不可用") }
            shows = try JSONDecoder().decode(PodcastSearchResult.self, from: data).results
            error = shows.isEmpty ? "没找到节目，试试另一个名称" : nil
        } catch { self.error = "节目检索暂未完成，稍后重试" }
    }
}
struct PodcastEpisodesView: View {
    let title: String
    let feed: String
    @EnvironmentObject private var listening: ListeningSpace
    @State private var episodes: [ListeningTrack] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if episodes.isEmpty { ContentUnavailableView("节目列表", systemImage: "mic", description: Text(error ?? "正在读取节目源")) }
                ForEach(episodes) { episode in
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) { Text(episode.title).font(.headline); Text(episode.artist.isEmpty ? title : episode.artist).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button {
                            if !listening.queue.contains(where: { $0.url == episode.url }) { listening.add(episode) }
                            if let saved = listening.queue.first(where: { $0.url == episode.url }) { listening.play(saved) }
                        } label: { Image(systemName: "play.circle.fill").font(.title2) }.accessibilityLabel("播放 " + episode.title)
                    }.padding(20).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                }
                if let error = listening.error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }.padding(22)
        }.background { GlassWallpaper() }.navigationTitle(title).task { await refresh() }.refreshable { await refresh() }
    }
    private func refresh() async {
        do { episodes = try await listening.episodes(feed: feed); error = episodes.isEmpty ? "这个节目源没有 HTTPS 音频" : nil }
        catch { self.error = error.localizedDescription }
    }
}
