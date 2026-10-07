import SwiftUI

struct MusicShare: Codable, Identifiable, Equatable {
    let provider: String
    let identifier: String
    var title: String
    var artist: String = ""
    var id: String { provider + ":" + identifier }
    var providerName: String { provider == "qq" ? "QQ 音乐" : "网易云音乐" }
    var url: String {
        provider == "qq" ? "https://y.qq.com/n/ryqq/songDetail/" + identifier : "https://music.163.com/song?id=" + identifier
    }
    var track: ListeningTrack {
        ListeningTrack(id: id, title: title, url: url, kind: "music", artist: artist, qqMID: provider == "qq" ? identifier : nil)
    }
    var markdown: String {
        let label = title + (artist.isEmpty ? "" : " · " + artist)
        let clean = label.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
        return "[\(clean)](\(url))"
    }
    static func from(_ text: String, label: String = "") -> MusicShare? {
        guard let url = ListeningTrack.validURL(text), url.port == nil || url.port == 443, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = url.host?.lowercased() ?? ""
        let provider: String, identifier: String
        if host == "y.qq.com", url.path.hasPrefix("/n/ryqq/songDetail/") {
            let mid = String(url.path.dropFirst("/n/ryqq/songDetail/".count))
            guard QQWire.identifier(mid) else { return nil }
            provider = "qq"; identifier = mid
        } else if host == "music.163.com" || host == "y.music.163.com" {
            let fragment = parts.fragment.flatMap { URLComponents(string: "https://music.163.com/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
            guard url.path == "/song" || fragment?.path == "/song",
                  let value = (parts.queryItems ?? fragment?.queryItems ?? []).first(where: { $0.name == "id" })?.value,
                  !value.isEmpty, value.count <= 20, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            provider = "netease"; identifier = value
        } else { return nil }
        let names = label.components(separatedBy: " · ")
        let title = names.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return MusicShare(provider: provider, identifier: identifier,
                          title: title.isEmpty ? (provider == "qq" ? "QQ 音乐分享" : "网易云音乐分享") : String(title.prefix(200)),
                          artist: String(names.dropFirst().joined(separator: " · ").prefix(200)))
    }
}

struct MusicShareContent {
    let body: String
    let shares: [MusicShare]
    init(_ text: String) {
        let pattern = #"\[([^\]\n]{1,300})\]\((https://[^\s\)]+)\)|https://[^\s<>\[\]（）。，！？；\)]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { body = text; shares = []; return }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var found: [MusicShare] = [], removed: [NSRange] = [], ids = Set<String>()
        for match in matches {
            let linked = match.range(at: 2).location != NSNotFound
            guard let range = Range(linked ? match.range(at: 2) : match.range, in: text) else { continue }
            let label = linked ? Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? "" : ""
            guard let share = MusicShare.from(String(text[range]), label: label) else { continue }
            if ids.contains(share.id) { removed.append(match.range) }
            else if found.count < 6 { ids.insert(share.id); found.append(share); removed.append(match.range) }
        }
        let mutable = NSMutableString(string: text)
        for range in removed.reversed() { mutable.replaceCharacters(in: range, with: "") }
        body = (mutable as String).trimmingCharacters(in: .whitespacesAndNewlines); shares = found
    }
}

struct SavedMusic: Codable, Identifiable {
    var share: MusicShare
    var savedAt = Date.now
    var id: String { share.id }
}

struct MusicShareCard: View {
    let share: MusicShare
    @EnvironmentObject private var space: PersonalSpace
    @State private var detail = false
    var body: some View {
        Button { detail = true } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color(white: 0.12))
                        ForEach(0..<3) { i in Circle().stroke(.white.opacity(0.13), lineWidth: 1).padding(CGFloat(6 + i * 6)) }
                        Image(systemName: "music.note").font(.title3).foregroundStyle(Color(red: 0.89, green: 0.66, blue: 0.71))
                    }.frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(share.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text(share.artist.isEmpty ? share.providerName : share.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(homeAccent)
                }
                HStack {
                    Label("分享一首歌", systemImage: "headphones").font(.caption2)
                    Spacer()
                    if space.isMusicSaved(share.id) { Image(systemName: "heart.fill").accessibilityLabel("已收藏音乐") }
                    Text(share.providerName).font(.caption2)
                }.foregroundStyle(.secondary)
            }.foregroundStyle(.primary).padding(14).background(homeAccent.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(homeAccent.opacity(0.12)))
        }.buttonStyle(.plain).accessibilityLabel("音乐分享：" + share.title).accessibilityIdentifier("music-share-card")
            .sheet(isPresented: $detail) { MusicShareDetail(share: share) }
    }
}

struct MusicShareDetail: View {
    let share: MusicShare
    @EnvironmentObject private var listening: ListeningSpace
    @EnvironmentObject private var space: PersonalSpace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chat_draft_v1") private var draft = ""
    @State private var login = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "music.note").font(.system(size: 66, weight: .light)).foregroundStyle(homeAccent)
                        .frame(width: 180, height: 180).background(homeAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 38)).padding(.top, 24)
                    VStack(spacing: 8) { Text(share.title).font(.system(.title2, design: .serif)).multilineTextAlignment(.center); Text(share.artist).foregroundStyle(.secondary); Text(share.providerName).font(.caption).foregroundStyle(.secondary) }
                    if share.provider == "qq" {
                        Button(listening.qq.connected ? "放进一起听，播放这首" : "连接 QQ 音乐后播放") {
                            if listening.qq.connected { listening.add(share.track); listening.play(share.track); dismiss(); NotificationCenter.default.post(name: .morrowOpenListening, object: nil) }
                            else { login = true }
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("music-share-play")
                    }
                    Link("在\(share.providerName)打开", destination: URL(string: share.url)!).buttonStyle(.bordered)
                    HStack(spacing: 20) {
                        Button { space.toggleMusic(share) } label: { Label(space.isMusicSaved(share.id) ? "已收藏" : "收藏音乐", systemImage: space.isMusicSaved(share.id) ? "heart.fill" : "heart") }
                            .accessibilityIdentifier("save-shared-music")
                        ShareLink(item: URL(string: share.url)!) { Label("分享", systemImage: "square.and.arrow.up") }
                    }.font(.subheadline)
                    Button("拿这首和他聊聊") { draft = "听到这首歌，想和你聊聊。\n" + share.markdown; dismiss(); NotificationCenter.default.post(name: .morrowOpenChat, object: nil) }.font(.subheadline)
                    Text("歌曲按音乐账号的实际权限播放。").font(.caption).foregroundStyle(.secondary)
                }.padding(28).frame(maxWidth: 600).frame(maxWidth: .infinity)
            }.background { GlassWallpaper() }.navigationTitle("分享的音乐").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                .sheet(isPresented: $login) { QQMusicLoginView(account: listening.qq) }
        }
    }
}

extension Notification.Name { static let morrowOpenListening = Notification.Name("morrow-open-listening") }

struct SharedNoteContent: View {
    let text: String
    var body: some View {
        let content = MusicShareContent(text)
        VStack(alignment: .leading, spacing: 12) {
            if !content.body.isEmpty { Text(content.body).font(.subheadline).lineSpacing(5).textSelection(.enabled) }
            ForEach(content.shares) { MusicShareCard(share: $0) }
        }
    }
}
