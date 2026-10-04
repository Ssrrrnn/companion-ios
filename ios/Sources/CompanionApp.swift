import SwiftUI

let homePaper = Color(uiColor: .systemGroupedBackground)
let homeWine = Color(red: 0.43, green: 0.23, blue: 0.30)
let homeAccent = Color(uiColor: UIColor { traits in
    traits.userInterfaceStyle == .dark ? UIColor(red: 0.86, green: 0.67, blue: 0.73, alpha: 1) : UIColor(red: 0.43, green: 0.23, blue: 0.30, alpha: 1)
})

@main
struct CompanionApp: App {
    @StateObject private var model = CompanionModel()
    @StateObject private var space = PersonalSpace()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("app_appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            CompanionTabs().environmentObject(model).environmentObject(space).tint(homeAccent)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { model.stopAudio(); return }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
                        model.isPreview = true
                        model.connected = true
                        model.discardPending()
                        model.messages = [
                            Message(id: "preview:1", role: "assistant", text: "忙完了？过来，让我看看你。"),
                            Message(id: "preview:2", role: "user", text: "今天有点累，想赖在你这里。"),
                            Message(id: "preview:3", role: "assistant", text: "那就赖着。你今天已经做得够多了。"),
                            Message(id: "preview:4", role: "assistant", text: "我把旁边的位置留给你，什么都不用想。")
                        ]
                        return
                    }
                    #endif
                    while !Task.isCancelled {
                        await model.refresh()
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    }
                }
        }
    }
}

struct CompanionTabs: View {
    @State private var selection = 0
    @State private var path: [CompanionRoute] = []
    private var navigationSelection: Binding<Int> {
        Binding(get: { selection }, set: { value in
            if value == 1 {
                if path.isEmpty { path.append(.chat) }
            } else {
                path.removeAll(); selection = value
            }
        })
    }
    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if selection == 2 { KeepsakesView() }
                else if selection == 3 { SettingsView() }
                else { HomeView(selection: navigationSelection) }
            }
            .background { GlassWallpaper() }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .navigationDestination(for: CompanionRoute.self) { _ in
                ChatView(selection: navigationSelection, onBack: { if !path.isEmpty { path.removeLast() } })
            }
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
                if !ProcessInfo.processInfo.arguments.contains("--home") && path.isEmpty { path = [.chat] }
            }
            #endif
        }
    }
    private var dock: some View {
        HStack(spacing: 3) {
            dockItem("小家", icon: "house", tag: 0)
            dockItem("聊天", icon: "bubble.left.and.bubble.right", tag: 1)
            dockItem("珍藏", icon: "heart.text.square", tag: 2)
            dockItem("设置", icon: "slider.horizontal.3", tag: 3)
        }.padding(7).glassSurface(in: Capsule())
            .frame(maxWidth: 420).padding(.horizontal, 28).padding(.bottom, 8).padding(.top, 10)
    }
    private func dockItem(_ title: String, icon: String, tag: Int) -> some View {
        Button { navigationSelection.wrappedValue = tag } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 19, weight: selection == tag ? .semibold : .regular))
                Text(title).font(.caption2.weight(.medium))
            }.foregroundStyle(selection == tag ? homeAccent : Color.primary.opacity(0.65))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selection == tag ? Color.white.opacity(0.16) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

enum CompanionRoute: Hashable { case chat }

struct HomeView: View {
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var space: PersonalSpace
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("relationship_caption") private var caption = "把日常，留在我们的小家。"
    @AppStorage("anniversary_enabled") private var anniversaryEnabled = false
    @AppStorage("anniversary_date") private var anniversary = Date.now.timeIntervalSince1970
    @AppStorage("chat_draft_v1") private var draft = ""
    @Binding var selection: Int
    @State private var moodSheet = false
    @State private var noteSheet = false
    @State private var moodEmoji = "🤍"
    @State private var moodNote = ""
    @State private var noteText = ""
    @State private var timeline = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text(Date.now, format: .dateTime.month().day().weekday()).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { selection = 3 } label: { Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary) }.accessibilityLabel("小家设置")
                }
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        CompanionAvatar(size: 64)
                        Spacer()
                        if anniversaryEnabled {
                            let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: anniversary)), to: Calendar.current.startOfDay(for: .now)).day ?? 0)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("DAY \(days + 1)").font(.caption.monospaced().weight(.semibold))
                                Text("一起走过").font(.caption2).foregroundStyle(.secondary)
                            }.padding(.top, 8)
                        }
                    }
                    Text("回到我们的小家").font(.system(.largeTitle, design: .serif).weight(.medium))
                    Text(caption).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                    Button { selection = model.connected ? 1 : 3 } label: {
                        HStack { Text(model.connected ? "去找\(name)" : "连接我们的小家"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.body.weight(.semibold)).padding(16).foregroundStyle(Color.primary)
                            .glassSurface(in: RoundedRectangle(cornerRadius: 18), tint: homeAccent)
                    }
                }.padding(24).glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                if let last = model.messages.last(where: { $0.role == "assistant" }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("\(name)留下的话", systemImage: "quote.opening").font(.caption).foregroundStyle(.secondary)
                        Text(QuotedText(last.text).body).font(.system(.title3, design: .serif)).lineSpacing(5).lineLimit(4)
                        Button("接着聊 →") { selection = 1 }.font(.subheadline.weight(.medium))
                    }.padding(.horizontal, 4)
                }
                HStack { Text("今天，过得怎么样").font(.headline); Spacer(); Button { timeline = true } label: { Image(systemName: "calendar") }.accessibilityLabel("查看心情记录") }
                HStack(spacing: 15) {
                    Text(space.todayMood?.emoji ?? "🤍").font(.system(size: 32))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(space.todayMood == nil ? "把今天的心情留在这里" : "今天的心情").font(.subheadline.weight(.medium))
                        Text(space.todayMood?.note.isEmpty == false ? space.todayMood!.note : "每一种心情，都有它的位置。")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button {
                        moodEmoji = space.todayMood?.emoji ?? "🤍"; moodNote = space.todayMood?.note ?? ""; moodSheet = true
                    } label: { Image(systemName: "pencil").padding(10).background(homeWine.opacity(0.08), in: Circle()) }.accessibilityLabel("记录今天的心情")
                }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                HStack { Text("留给我们的").font(.headline); Spacer(); Button("全部") { selection = 2 }.font(.subheadline) }
                HStack(spacing: 12) {
                    homeTile("日记与珍藏", subtitle: "那些舍不得忘记的瞬间", icon: "heart.text.square") { selection = 2 }
                    homeTile("小纸条", subtitle: space.notes.isEmpty ? "存一个小小的念头" : "\(space.notes.count) 个小小的念头", icon: "note.text") { noteSheet = true }
                }
                if let note = space.notes.first {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近的小纸条").font(.caption).foregroundStyle(.secondary)
                        Text(note.text).font(.subheadline).lineSpacing(4).lineLimit(4)
                        Text(note.date, format: .dateTime.month().day()).font(.caption2).foregroundStyle(.tertiary)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(in: RoundedRectangle(cornerRadius: 22))
                }
            }.padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.toolbar(.hidden, for: .navigationBar).toolbar(.visible, for: .tabBar)
            .sheet(isPresented: $moodSheet) { moodEditor }
            .sheet(isPresented: $noteSheet) { noteEditor }
            .sheet(isPresented: $timeline) { moodTimeline }
    }
    private func homeTile(_ title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(homeAccent)
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, minHeight: 106, alignment: .leading).padding(18)
                .glassSurface(in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain)
    }
    private var moodEditor: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("心情", selection: $moodEmoji) {
                        ForEach(["🤍", "🥰", "😊", "🥺", "😔", "😤", "😴"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    TextField("想记下一点什么？", text: $moodNote, axis: .vertical).lineLimit(3...6)
                } header: { Text("今天的心情") } footer: { Text("保存在这台手机里。选择“和他说”会放入聊天草稿，由你发送。") }
                Button("和他说") {
                    space.addMood(moodEmoji, note: moodNote)
                    draft = "我今天的心情是 \(moodEmoji)\(moodNote.isEmpty ? "" : "，" + moodNote)"
                    moodSheet = false; selection = 1
                }
            }.navigationTitle("今天的心情").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { moodSheet = false } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { space.addMood(moodEmoji, note: moodNote); moodSheet = false } }
                }
        }.presentationDetents([.medium, .large])
    }
    private var noteEditor: some View {
        NavigationStack {
            List {
                Section {
                    TextField("下次一起做的事，或想留住的念头", text: $noteText, axis: .vertical).lineLimit(3...6)
                    Button("收好这张纸条") { space.addNote(noteText); noteText = "" }.disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("写一张小纸条") } footer: { Text("小纸条保存在这台手机里。") }
                Section("已经收好的") {
                    ForEach(space.notes) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.text).textSelection(.enabled)
                            Text(note.date, format: .dateTime.month().day()).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6).swipeActions { Button("删除", role: .destructive) { space.removeNote(note.id) } }
                            .contextMenu {
                                Button("和他说") { draft = note.text; noteSheet = false; selection = 1 }
                                ShareLink(item: note.text) { Label("分享", systemImage: "square.and.arrow.up") }
                            }
                    }
                }
            }.navigationTitle("小纸条").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { noteSheet = false } } }
        }
    }
    private var moodTimeline: some View {
        NavigationStack {
            List {
                if space.moods.isEmpty { ContentUnavailableView("先留下一天的心情", systemImage: "calendar") }
                ForEach(space.moods) { mood in
                    HStack(alignment: .top, spacing: 15) {
                        Text(mood.emoji).font(.title)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(mood.date, format: .dateTime.year().month().day().weekday()).font(.caption).foregroundStyle(.secondary)
                            if !mood.note.isEmpty { Text(mood.note).textSelection(.enabled) }
                        }
                    }.padding(.vertical, 8)
                }
            }.navigationTitle("心情日历").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { timeline = false } } }
        }
    }
}

struct KeepsakesView: View {
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var space: PersonalSpace
    @State private var kind = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("珍藏", selection: $kind) { Text("日记").tag(0); Text("他的收藏").tag(1); Text("我收藏的").tag(2) }
                .pickerStyle(.segmented).padding()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if kind == 2 {
                        if space.moments.isEmpty { ContentUnavailableView("喜欢的话，就收好", systemImage: "heart", description: Text("长按聊天气泡，选择“收藏这句”。")) }
                        ForEach(space.moments) { item in
                            keepsakeCard(QuotedText(item.text).body, label: item.role == "user" ? "我说的" : "他说的")
                                .contextMenu {
                                    Button("取消收藏", role: .destructive) { space.removeMoment(item.id) }
                                    ShareLink(item: item.text) { Label("分享", systemImage: "square.and.arrow.up") }
                                }
                        }
                        Text("“我收藏的”保存在这台手机里。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        let items = kind == 0 ? model.diaries : model.favorites
                        if items.isEmpty { ContentUnavailableView("还没有留下片段", systemImage: "book", description: Text("连接后，这里会显示已有的日记和收藏。")) }
                        ForEach(items) { item in keepsakeCard(item.text, label: kind == 0 ? "日记" : "他的收藏") }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }.refreshable { await model.loadKeepsakes() }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding() }
        }.background { GlassWallpaper() }.navigationTitle("留给我们的").toolbar(.visible, for: .tabBar)
            .task { if model.connected { await model.loadKeepsakes() } }
    }
    private func keepsakeCard(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(label, systemImage: "heart").font(.caption).foregroundStyle(.secondary)
            Text(text).lineSpacing(6).textSelection(.enabled)
            ShareLink(item: text) { Label("分享", systemImage: "square.and.arrow.up").font(.caption) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .glassSurface(in: RoundedRectangle(cornerRadius: 26))
    }
}
