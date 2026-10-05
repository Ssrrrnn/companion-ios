import SwiftUI

enum KeepsakeKind: String, CaseIterable, Identifiable {
    case diaries, favorites, moments, memories, notes, music
    var id: String { rawValue }
    var title: String {
        switch self { case .diaries: return "日记"; case .favorites: return "他的收藏"; case .moments: return "我收藏的"; case .memories: return "长期记忆"; case .notes: return "小纸条"; case .music: return "音乐收藏" }
    }
    var icon: String {
        switch self { case .diaries: return "book.closed"; case .favorites: return "heart.text.square"; case .moments: return "bookmark"; case .memories: return "sparkles"; case .notes: return "envelope.open"; case .music: return "music.note" }
    }
    var caption: String {
        switch self { case .diaries: return "把每一天，留成一页"; case .favorites: return "他舍不得忘记的话"; case .moments: return "我想反复读的片段"; case .memories: return "他一直记着的事情"; case .notes: return "写给彼此的小小心事"; case .music: return "把心情，放进旋律里" }
    }
    var remote: Bool { [.diaries, .favorites, .memories].contains(self) }
    var color: Color {
        switch self { case .diaries: return Color(red: 0.63, green: 0.44, blue: 0.28); case .favorites, .moments: return Color(red: 0.70, green: 0.39, blue: 0.46); case .memories: return Color(red: 0.48, green: 0.43, blue: 0.65); case .notes: return Color(red: 0.36, green: 0.54, blue: 0.45); case .music: return Color(red: 0.67, green: 0.34, blue: 0.41) }
    }
}

struct CabinetEntry: Identifiable {
    let sourceID: String
    let kind: KeepsakeKind
    let text: String
    let attribution: String
    var date: Date?
    var note: String? = nil
    var id: String { kind.rawValue + ":" + sourceID }
    var title: String {
        let content = MusicShareContent(text)
        if kind == .music, let song = content.shares.first { return song.title }
        let first = text.split(whereSeparator: { "。！？\n".contains($0) }).first.map(String.init) ?? text
        return first.isEmpty ? kind.title : String(first.prefix(32))
    }
    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || [text, attribution, note ?? "", kind.title].contains { $0.localizedStandardContains(term) }
    }
    static func sorted(_ entries: [CabinetEntry], pinned: Set<String>, query: String = "") -> [CabinetEntry] {
        entries.filter { $0.matches(query) }.sorted {
            if pinned.contains($0.id) != pinned.contains($1.id) { return pinned.contains($0.id) }
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.id < $1.id
        }
    }
}

struct KeepsakesView: View {
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var space: PersonalSpace
    @EnvironmentObject private var shared: SharedSpace
    @State private var query = ""
    @State private var writing = false
    private var entries: [CabinetEntry] { CabinetSource.entries(model: model, space: space, shared: shared) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 8) {
                    Text("Keepsakes").font(MorrowType.script(43)).foregroundStyle(homeAccent)
                    Text("珍藏").font(.system(.title2, design: .serif)).tracking(5)
                    Text("把舍不得忘记的，慢慢收好。").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 10)
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索已收好的片段", text: $query).autocorrectionDisabled().accessibilityIdentifier("keepsake-search"); if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空珍藏搜索") } }
                    .padding(15).glassSurface(in: RoundedRectangle(cornerRadius: 18))
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let recent = entries.filter({ $0.kind == .diaries }).first {
                        NavigationLink { CabinetDetail(entry: recent) } label: {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack { Label("最近的一页", systemImage: "book.pages").font(.caption); Spacer(); if let date = recent.date { Text(date, format: .dateTime.month().day()).font(.caption) } }
                                Text(recent.title).font(.system(.title3, design: .serif)).lineLimit(2)
                                Text(recent.text).font(.subheadline).lineSpacing(4).lineLimit(3).foregroundStyle(.secondary)
                                HStack { Text("展开这篇日记").font(.caption); Spacer(); Image(systemName: "arrow.up.right") }
                            }.foregroundStyle(.primary).padding(23).background(KeepsakeKind.diaries.color.opacity(0.09), in: RoundedRectangle(cornerRadius: 25)).overlay(RoundedRectangle(cornerRadius: 25).stroke(KeepsakeKind.diaries.color.opacity(0.15)))
                        }.buttonStyle(.plain)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                        ForEach(KeepsakeKind.allCases) { kind in
                            let count = entries.filter { $0.kind == kind }.count
                            NavigationLink { CabinetCollection(kind: kind) } label: {
                                VStack(alignment: .leading, spacing: 15) {
                                    Image(systemName: kind.icon).font(.title2.weight(.light)).foregroundStyle(kind.color).frame(width: 45, height: 45).background(kind.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                                    VStack(alignment: .leading, spacing: 6) { Text(kind.title).font(.headline); Text(kind.caption).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    HStack { Text(count == 0 ? "等下一段故事" : (kind.remote ? "最近 \(count) 段" : "\(count) 段珍藏")).font(.caption2).foregroundStyle(.secondary); Spacer(minLength: 2); Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(kind.color) }
                                }.foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 162, alignment: .topLeading).padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                            }.buttonStyle(.plain).accessibilityIdentifier("keepsake-" + kind.rawValue)
                        }
                    }
                    let pinned = CabinetEntry.sorted(entries.filter { space.pinned.contains($0.id) }, pinned: space.pinned)
                    if !pinned.isEmpty {
                        Label("常常想起的", systemImage: "pin").font(.headline)
                        ForEach(pinned.prefix(8)) { entry in CabinetRow(entry: entry) }
                    }
                    Button { writing = true } label: { Label("留一张小纸条", systemImage: "square.and.pencil").frame(maxWidth: .infinity).padding(17) }.buttonStyle(.plain).glassSurface(in: RoundedRectangle(cornerRadius: 20)).accessibilityIdentifier("write-keepsake-note")
                } else {
                    let matches = CabinetEntry.sorted(entries, pinned: space.pinned, query: query)
                    Text("已收好内容中的 \(matches.count) 个片段").font(.caption).foregroundStyle(.secondary)
                    if matches.isEmpty { ContentUnavailableView("暂时没找到", systemImage: "magnifyingglass", description: Text("试试另一段话。更早的日记、收藏和记忆可进入对应卡片继续加载。")) }
                    ForEach(matches) { entry in CabinetRow(entry: entry) }
                }
                ForEach(model.keepsakeErrors.keys.sorted(), id: \.self) { key in if let kind = KeepsakeKind(rawValue: key) { Text("\(kind.title)：\(model.keepsakeErrors[key] ?? "")").font(.caption).foregroundStyle(.secondary) } }
            }.padding(22).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle("留给我们的").navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.loadKeepsakes(); await shared.sync(api: model.api, force: true) }
            .task { if model.connected { await model.loadKeepsakes(); await shared.sync(api: model.api, force: true) } }
            .sheet(isPresented: $writing) { KeepsakeNoteEditor() }
    }
}

@MainActor enum CabinetSource {
    static func entries(model: CompanionModel, space: PersonalSpace, shared: SharedSpace) -> [CabinetEntry] {
        var result: [CabinetEntry] = []
        for kind in [KeepsakeKind.diaries, .favorites, .memories] {
            result += model.keepsakes(kind.rawValue).map { CabinetEntry(sourceID: $0.id, kind: kind, text: $0.text, attribution: kind == .diaries ? "他的日记" : kind == .favorites ? "他收好的话" : "他记着的事情", date: $0.at.flatMap(SharedDates.instant), note: $0.note) }
        }
        result += space.moments.map { CabinetEntry(sourceID: $0.id, kind: .moments, text: QuotedText($0.text).body, attribution: $0.role == "user" ? "我说的 · 本机收藏" : "他说的 · 本机收藏", date: $0.savedAt) }
        result += space.notes.map { CabinetEntry(sourceID: $0.id.uuidString, kind: .notes, text: $0.text, attribution: "我的纸条 · 本机", date: $0.date) }
        result += shared.entries.filter { $0.kind == "note" }.map { CabinetEntry(sourceID: $0.id, kind: .notes, text: $0.text, attribution: $0.actor == "user" ? "我的共享纸条" : "他留给我的纸条", date: SharedDates.parse($0.day)) }
        result += space.music.map { CabinetEntry(sourceID: $0.id, kind: .music, text: $0.share.markdown, attribution: $0.share.providerName, date: $0.savedAt) }
        return result
    }
}

private struct CabinetCollection: View {
    let kind: KeepsakeKind
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var space: PersonalSpace
    @EnvironmentObject private var shared: SharedSpace
    @State private var query = ""
    @State private var writing = false
    private var entries: [CabinetEntry] { CabinetEntry.sorted(CabinetSource.entries(model: model, space: space, shared: shared).filter { $0.kind == kind }, pinned: space.pinned, query: query) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(kind.caption).font(.system(.title3, design: .serif)).padding(.vertical, 8)
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索这页珍藏", text: $query).autocorrectionDisabled() }.padding(14).glassSurface(in: RoundedRectangle(cornerRadius: 18))
                if kind == .notes {
                    HStack {
                        Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("纸条上个月")
                        Spacer(); Text(shared.month, format: .dateTime.year().month()); Spacer()
                        Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("纸条下个月")
                    }.font(.subheadline).padding(.vertical, 6)
                    Text("共享纸条按月份查看，本机纸条一直保留。").font(.caption).foregroundStyle(.secondary)
                    Button("写一张纸条") { writing = true }.buttonStyle(.bordered)
                }
                if entries.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "给下一段故事留个位置" : "这页暂未找到", systemImage: kind.icon, description: Text(kind == .memories ? "这里显示他真正保存的长期记忆。" : kind == .music ? "点开聊天里的音乐卡片，可以把歌收在这里。" : kind == .moments ? "长按聊天气泡，选择“收藏这句”。" : "新的片段会慢慢来到这里。"))
                }
                ForEach(entries) { entry in CabinetRow(entry: entry) }
                if let error = model.keepsakeErrors[kind.rawValue] { Text(error).font(.caption).foregroundStyle(.secondary) }
                if kind.remote, model.keepsakeMore.contains(kind.rawValue) {
                    Button(model.keepsakeLoading.contains(kind.rawValue) ? "正在翻页…" : "看看更早的") { Task { await model.loadKeepsakes(kind: kind.rawValue, more: true) } }
                        .buttonStyle(.bordered).disabled(model.keepsakeLoading.contains(kind.rawValue))
                }
                if kind.remote, !query.isEmpty { Text("搜索当前已加载的内容；可以继续翻阅更早的记录。").font(.caption).foregroundStyle(.secondary) }
            }.padding(22).frame(maxWidth: 700).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
            .refreshable { if kind.remote { await model.loadKeepsakes(kind: kind.rawValue) }; if kind == .notes { await shared.sync(api: model.api, force: true) } }
            .sheet(isPresented: $writing) { KeepsakeNoteEditor() }
    }
    private func changeMonth(_ direction: Int) {
        if let date = SharedDates.calendar.date(byAdding: .month, value: direction, to: shared.month) { shared.month = date; Task { await shared.sync(api: model.api, force: true) } }
    }
}

private struct CabinetRow: View {
    let entry: CabinetEntry
    @EnvironmentObject private var space: PersonalSpace
    var body: some View {
        NavigationLink { CabinetDetail(entry: entry) } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack { Label(entry.attribution, systemImage: entry.kind.icon).font(.caption).foregroundStyle(.secondary); Spacer(); if space.pinned.contains(entry.id) { Image(systemName: "pin.fill").font(.caption).foregroundStyle(entry.kind.color) } }
                Text(entry.title).font(.system(.headline, design: .serif)).lineLimit(2)
                if entry.kind != .music { Text(entry.text).font(.subheadline).lineSpacing(4).foregroundStyle(.secondary).lineLimit(3) }
                HStack { if let date = entry.date { Text(date, format: .dateTime.year().month().day()).font(.caption2).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(entry.kind.color) }
            }.foregroundStyle(.primary).padding(20).glassSurface(in: RoundedRectangle(cornerRadius: 23))
        }.buttonStyle(.plain).contextMenu { Button { space.togglePin(entry.id) } label: { Label(space.pinned.contains(entry.id) ? "取消置顶" : "置顶珍藏", systemImage: "pin") }; ShareLink(item: entry.text) { Label("分享", systemImage: "square.and.arrow.up") } }
    }
}

private struct CabinetDetail: View {
    let entry: CabinetEntry
    @EnvironmentObject private var space: PersonalSpace
    @EnvironmentObject private var shared: SharedSpace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("chat_draft_v1") private var draft = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label(entry.attribution, systemImage: entry.kind.icon).font(.caption).foregroundStyle(entry.kind.color)
                Text(entry.title).font(.system(.title2, design: .serif)).lineSpacing(5)
                if let date = entry.date { Text(date, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary) }
                Divider().overlay(entry.kind.color.opacity(0.12))
                let content = MusicShareContent(entry.text)
                if !content.body.isEmpty { Text(content.body).font(.body).lineSpacing(8).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(content.shares) { MusicShareCard(share: $0) }
                if let note = entry.note, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 10) { Label("收藏的缘由", systemImage: "heart").font(.caption); Text(note).font(.subheadline).lineSpacing(6) }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(entry.kind.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                }
                HStack {
                    Button { space.togglePin(entry.id) } label: { Label(space.pinned.contains(entry.id) ? "已置顶" : "置顶", systemImage: space.pinned.contains(entry.id) ? "pin.fill" : "pin") }.accessibilityIdentifier("pin-keepsake")
                    Spacer(); ShareLink(item: entry.text) { Label("分享", systemImage: "square.and.arrow.up") }
                }.font(.subheadline)
                Button("拿这条和他聊聊") { openChat("看到这段，想和你聊聊。") }.buttonStyle(.borderedProminent).accessibilityIdentifier("discuss-keepsake")
                if entry.kind == .memories { Button("这条记忆需要更新") { openChat("这条记忆需要更新，先和我确认应该怎么改：") }.font(.subheadline) }
                if entry.kind == .moments { Button("取消这条收藏", role: .destructive) { space.removeMoment(entry.sourceID); dismiss() }.font(.caption) }
            }.padding(28).frame(maxWidth: 650).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle(entry.kind.title).navigationBarTitleDisplayMode(.inline)
    }
    private func openChat(_ introduction: String) { draft = introduction + "\n" + String(entry.text.prefix(3500)); NotificationCenter.default.post(name: .morrowOpenChat, object: nil) }
}

private struct KeepsakeNoteEditor: View {
    @EnvironmentObject private var space: PersonalSpace
    @EnvironmentObject private var shared: SharedSpace
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var sharing = true
    var body: some View {
        NavigationStack {
            Form {
                Section("写下想留下的话") { TextEditor(text: $text).frame(minHeight: 200).accessibilityIdentifier("keepsake-note-text") }
                Section { Toggle("放进共享日历，让他也能读到", isOn: $sharing); Text(sharing ? "保存后同步到小家；离线时先留在手机，连接后继续同步。" : "这张纸条只保存在手机，想告诉他时再拿去聊聊。").font(.caption).foregroundStyle(.secondary) }
                Section { Button("收好这张纸条") {
                    let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
                    if sharing { shared.month = .now; shared.save(SharedEntry(id: UUID().uuidString, actor: "user", kind: "note", day: SharedDates.key(.now), title: "留给我们的小纸条", text: value, emoji: "💌")) }
                    else { space.addNote(value) }
                    dismiss()
                }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-keepsake-note") }
            }.navigationTitle("留一张纸条").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}
