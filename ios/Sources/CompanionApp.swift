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
    @StateObject private var library = ReadingLibrary()
    @StateObject private var device = DeviceContext()
    @StateObject private var shared = SharedSpace()
    @StateObject private var phone = PhoneBridge()
    @StateObject private var reading = ReadingSync()
    @StateObject private var activity = ActivitySpace()
    @StateObject private var location = LocationContext()
    @StateObject private var notifications = MorrowNotifications()
    @StateObject private var weather = WeatherSpace()
    @StateObject private var listening = ListeningSpace()
    @StateObject private var radio = RadioSpace()
    @StateObject private var call = CallSpace()
    @StateObject private var health = HealthSpace()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("app_appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            CompanionTabs().environmentObject(model).environmentObject(space).tint(homeAccent)
                .environmentObject(library).environmentObject(device)
                .environmentObject(shared).environmentObject(phone)
                .environmentObject(reading).environmentObject(activity).environmentObject(location)
                .environmentObject(notifications).environmentObject(weather).environmentObject(listening).environmentObject(health).environmentObject(radio).environmentObject(call)
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .environment(\.calendar, SharedDates.calendar)
                .environment(\.timeZone, SharedDates.calendar.timeZone)
                .onChange(of: model.api) { _, api in radio.attach(listening, api: api); call.attach(api: api) }
                .onReceive(NotificationCenter.default.publisher(for: .morrowStopVoice)) { _ in model.stopAudio() }
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task(id: scenePhase) {
                    device.setActive(scenePhase == .active)
                    if scenePhase == .active { await notifications.reload() }
                    guard scenePhase == .active else { if scenePhase == .background { call.end() }; model.stopAudio(); location.background(); return }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
                        if ProcessInfo.processInfo.arguments.contains("--reset-draft") { UserDefaults.standard.removeObject(forKey: "chat_draft_v1") }
                        if ProcessInfo.processInfo.arguments.contains("--books") { library.addPreviewBook() }
                        model.isPreview = true
                        listening.clearQueue()
                        if ProcessInfo.processInfo.arguments.contains("--queue-preview") {
                            for index in 1...12 { listening.add(ListeningTrack(id: "preview-queue-\(index)", title: "第\(index)首预览歌曲", url: "https://y.qq.com/n/ryqq/songDetail/PreviewQueue\(index)", kind: "music", artist: "预览歌手", qqMID: "PreviewQueue\(index)")) }
                        }
                        if ProcessInfo.processInfo.arguments.contains("--radio") { radio.preview() }
                        if ProcessInfo.processInfo.arguments.contains("--call") { call.preview() }
                        shared.preview()
                        reading.preview(library); activity.preview(); weather.preview()
                        model.connected = true
                        let previewAt = ISO8601DateFormatter().string(from: .now)
                        model.diaries = [Keepsake(id: "preview-diary", text: "把今天留成一页\n读到一段喜欢的话，想起你说过，平淡的日子也值得记住。今天没有赶着做什么，只把这点安静好好收了起来。", at: previewAt)]
                        model.favorites = [Keepsake(id: "preview-favorite", text: "慢慢来，我一直在这里。", at: previewAt, note: "想把这份安心，留给以后的我们。")]
                        model.memories = [Keepsake(id: "preview-memory", text: "喜欢把日常留在两个人的小家里，也喜欢一起读书、听歌。", at: previewAt)]
                        model.discardPending()
                        model.messages = [
                            Message(id: "preview:1", role: "assistant", text: "忙完了？过来，让我看看你。"),
                            Message(id: "preview:2", role: "user", text: "今天有点累，想赖在你这里。"),
                            Message(id: "preview:3", role: "assistant", text: "那就赖着。你今天已经做得够多了。"),
                            Message(id: "preview:4", role: "assistant", text: "我把旁边的位置留给你，什么都不用想。")
                        ]
                        if ProcessInfo.processInfo.arguments.contains("--music-card") {
                            model.messages.append(Message(id: "preview:music", role: "assistant", text: "想把这首歌留给今晚，也留给你。\n[示例音乐 · 预览歌手](https://y.qq.com/n/ryqq/songDetail/Preview001)"))
                        }
                        if ProcessInfo.processInfo.arguments.contains("--long-chat") {
                            let history = (0..<1000).map { Message(id: "history:\($0)", role: $0.isMultiple(of: 2) ? "assistant" : "user", text: "第\($0)段回忆。慢慢说，我一直在。") }
                            model.messages = history + model.messages
                        }
                        return
                    }
                    #endif
                    while !Task.isCancelled {
                        await model.refresh()
                        notifications.observe(model.messages)
                        do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    }
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    #if DEBUG
                    guard !ProcessInfo.processInfo.arguments.contains("--ui-preview") else { return }
                    #endif
                    shared.migrate(space.moods)
                    while !Task.isCancelled {
                        if model.connected {
                            await phone.tick(api: model.api, device: device, location: location)
                            await shared.sync(api: model.api)
                            await listening.sync(api: model.api)
                        }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    }
                }
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    #if DEBUG
                    guard !ProcessInfo.processInfo.arguments.contains("--ui-preview") else { return }
                    #endif
                    while !Task.isCancelled {
                        if model.connected {
                            await reading.sync(api: model.api, library: library)
                            await activity.sync(api: model.api)
                        }
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    }
                }
        }
    }
}

struct CompanionTabs: View {
    @State private var selection = 0
    @State private var path: [CompanionRoute] = []
    @State private var drawer = false
    private var navigationSelection: Binding<Int> {
        Binding(get: { selection }, set: { value in
            if value == 1 {
                path = [.chat]
            } else if value == 3 {
                path = [.settings]
            } else if value == 4 {
                path = [.listening]
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
                else { HomeView(selection: navigationSelection, onMenu: { withAnimation(.easeOut(duration: 0.2)) { drawer = true } }) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .navigationDestination(for: CompanionRoute.self) { route in
                switch route {
                case .chat:
                    ChatView(selection: navigationSelection, onBack: { if !path.isEmpty { path.removeLast() } })
                case .books:
                    BookshelfView(openChat: { path = [.chat] })
                case .device:
                    PhonePermissionsView()
                case .calendar:
                    SharedCalendarView()
                case .activity:
                    CompanionActivityView()
                case .settings: SettingsView()
                case .permissions: EverydayPermissionsView()
                case .listening: ListeningRoomView()
                case .browsing: BrowsingLogView()
                case .podcasts: PodcastDiscoveryView()
                case .radio: RadioView()
                case .call: CompanionCallView()
                }
            }
        }
        .overlay(alignment: .trailing) {
            if drawer {
                GeometryReader { geometry in
                    ZStack(alignment: .trailing) {
                        Color.black.opacity(0.42).ignoresSafeArea().onTapGesture { closeDrawer() }
                        HomeSidebar(close: closeDrawer, open: { route in closeDrawer(); path = [route] })
                            .frame(width: min(360, geometry.size.width * 0.88))
                            .shadow(color: .black.opacity(0.2), radius: 24, x: -8)
                            .transition(.move(edge: .trailing))
                    }
                }.transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .morrowOpenChat)) { _ in path = [.chat] }
        .onReceive(NotificationCenter.default.publisher(for: .morrowOpenListening)) { _ in path = [.listening] }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
                if ProcessInfo.processInfo.arguments.contains("--sidebar") { drawer = true }
                else if ProcessInfo.processInfo.arguments.contains("--settings") { path = [.settings] }
                else if ProcessInfo.processInfo.arguments.contains("--radio") { path = [.radio] }
                else if ProcessInfo.processInfo.arguments.contains("--call") { path = [.call] }
                else if ProcessInfo.processInfo.arguments.contains("--activity") && path.isEmpty { path = [.activity] }
                else if ProcessInfo.processInfo.arguments.contains("--calendar") && path.isEmpty { path = [.calendar] }
                else if ProcessInfo.processInfo.arguments.contains("--books") && path.isEmpty { path = [.books] }
                else if ProcessInfo.processInfo.arguments.contains("--listening") { path = [.listening] }
                else if ProcessInfo.processInfo.arguments.contains("--keepsakes") { selection = 2; path = [] }
                else if !ProcessInfo.processInfo.arguments.contains("--home") && path.isEmpty { path = [.chat] }
            }
            #endif
        }
    }
    private func closeDrawer() { withAnimation(.easeOut(duration: 0.22)) { drawer = false } }
    private var dock: some View {
        HStack(spacing: 3) {
            dockItem("小家", icon: "house", tag: 0)
            dockItem("聊天", icon: "bubble.left.and.bubble.right", tag: 1)
            dockItem("珍藏", icon: "heart.text.square", tag: 2)
            dockItem("一起听", icon: "music.note", tag: 4)
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

enum CompanionRoute: Hashable { case chat, books, device, calendar, activity, settings, permissions, listening, browsing, podcasts, radio, call }

struct HomeView: View {
    @EnvironmentObject private var activity: ActivitySpace
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var space: PersonalSpace
    @EnvironmentObject private var library: ReadingLibrary
    @EnvironmentObject private var device: DeviceContext
    @EnvironmentObject private var shared: SharedSpace
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("relationship_caption") private var caption = "把日常，留在我们的小家。"
    @AppStorage("anniversary_enabled") private var anniversaryEnabled = false
    @AppStorage("anniversary_date") private var anniversary = Date.now.timeIntervalSince1970
    @AppStorage("chat_draft_v1") private var draft = ""
    @Binding var selection: Int
    var onMenu: () -> Void = {}
    @State private var moodSheet = false
    @State private var noteSheet = false
    @State private var moodEmoji = "🤍"
    @State private var moodNote = ""
    @State private var moodID: String?
    @State private var noteText = ""
    @State private var timeline = false
    private var todayMood: SharedEntry? { shared.on(.now).last { $0.actor == "user" && $0.kind == "mood" } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Morrow").font(MorrowType.script(43)).foregroundStyle(homeAccent)
                        Text("A LITTLE WORLD, WITH YOU").font(.system(size: 9, weight: .medium)).tracking(2.2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: onMenu) { Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).padding(10) }.accessibilityLabel("打开侧边栏")
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        CompanionAvatar(size: 64)
                        Spacer()
                        if anniversaryEnabled {
                            let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date(timeIntervalSince1970: anniversary)), to: Calendar.current.startOfDay(for: .now)).day ?? 0)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text("相恋 \(days + 1) 天").font(.caption.monospaced().weight(.semibold))
                                Text("从这一天开始").font(.caption2).foregroundStyle(.secondary)
                            }.padding(.top, 8)
                        } else {
                            Button { selection = 3 } label: { Label("记住第一天", systemImage: "heart").font(.caption) }.padding(.top, 8)
                        }
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(activity.welcome ?? HomeGreeting.text(at: context.date, name: name)).font(.system(.title, design: .serif).weight(.medium))
                    }
                    Text(caption).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                    Button { selection = model.connected ? 1 : 3 } label: {
                        HStack { Text(model.connected ? "去找\(name)" : "连接我们的小家"); Spacer(); Image(systemName: "arrow.up.right") }
                            .font(.body.weight(.semibold)).padding(16).foregroundStyle(Color.primary)
                            .glassSurface(in: RoundedRectangle(cornerRadius: 18), tint: homeAccent)
                    }
                }.padding(24).glassSurface(in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                WeatherCard()
                CallHomeCard()
                ListeningHomeCard()
                RadioHomeCard()
                NavigationLink(value: CompanionRoute.activity) {
                    HStack(spacing: 16) {
                        Image(systemName: "pawprint").font(.title2).foregroundStyle(homeAccent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("印记").font(.system(.title3, design: .serif)).foregroundStyle(.primary)
                            Text("他醒来后，留下的日常").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain).accessibilityIdentifier("home-activity")
                NavigationLink(value: CompanionRoute.calendar) {
                    HStack(spacing: 16) {
                        Image(systemName: "calendar").font(.title2).foregroundStyle(homeAccent)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("我们的日历").font(.headline).foregroundStyle(.primary)
                            Text("看见彼此的心情、小记与日程").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain).accessibilityIdentifier("home-calendar")
                NavigationLink(value: CompanionRoute.books) {
                    HStack(spacing: 16) {
                        Image(systemName: "books.vertical").font(.title2).foregroundStyle(homeAccent)
                            .frame(width: 54, height: 62).background(homeAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                        VStack(alignment: .leading, spacing: 7) {
                            Text("一起读书").font(.headline).foregroundStyle(.primary)
                            Text(library.books.isEmpty ? "把一本书，放在两个人中间。" : "\(library.books.count) 本书 · 留住读到这里的想法")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                }.buttonStyle(.plain).accessibilityIdentifier("home-reading")
                HStack { Text("今天，过得怎么样").font(.headline); Spacer(); Button { timeline = true } label: { Image(systemName: "calendar") }.accessibilityLabel("查看心情记录") }
                HStack(spacing: 15) {
                    Text(todayMood?.emoji ?? "🤍").font(.system(size: 32))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(todayMood == nil ? "把今天的心情留在这里" : "今天的心情").font(.subheadline.weight(.medium))
                        Text(todayMood?.text.isEmpty == false ? todayMood!.text : "每一种心情，都有它的位置。")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button {
                        moodEmoji = todayMood?.emoji ?? "🤍"; moodNote = todayMood?.text ?? ""; moodID = todayMood?.id; moodSheet = true
                    } label: { Image(systemName: "pencil").padding(10).background(homeWine.opacity(0.08), in: Circle()) }.accessibilityLabel("记录今天的心情")
                }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                HStack { Text("留给我们的").font(.headline); Spacer(); Button("全部") { selection = 2 }.font(.subheadline) }
                HStack(spacing: 12) {
                    homeTile("日记与珍藏", subtitle: "那些舍不得忘记的瞬间", icon: "heart.text.square") { selection = 2 }
                    homeTile("小纸条", subtitle: space.notes.isEmpty ? "存一个小小的念头" : "\(space.notes.count) 个小小的念头", icon: "note.text") { noteSheet = true }
                }
                NavigationLink(value: CompanionRoute.device) {
                    HStack(spacing: 12) {
                        Image(systemName: "iphone").foregroundStyle(homeAccent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("他的手机权限").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text(device.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(17).glassSurface(in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain)
                if let note = shared.entries.last(where: { $0.kind == "note" && $0.actor == "assistant" }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("他留给你的纸条", systemImage: "envelope.open").font(.caption).foregroundStyle(homeAccent)
                        SharedNoteContent(text: note.text)
                        Text(note.day).font(.caption2).foregroundStyle(.tertiary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).glassSurface(in: RoundedRectangle(cornerRadius: 24))
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
        }.simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
            if HomeSwipe.opens(x: value.translation.width, y: value.translation.height) { onMenu() }
        }).accessibilityIdentifier("home-scroll").background { GlassWallpaper() }.navigationTitle("小家").toolbar(.hidden, for: .navigationBar).toolbar(.visible, for: .tabBar)
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
            SharedCalendarView(editOnOpen: true)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { moodSheet = false } } }
        }
    }
    private var noteEditor: some View {
        NavigationStack {
            List {
                Section {
                    TextField("下次一起做的事，或想留住的念头", text: $noteText, axis: .vertical).lineLimit(3...6)
                    Button("收好这张纸条") { shared.save(SharedEntry(id: UUID().uuidString, actor: "user", kind: "note", day: SharedDates.key(.now), title: "小纸条", text: String(noteText.prefix(2000)), emoji: "")); noteText = "" }.disabled(noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("写一张小纸条") } footer: { Text("新纸条同步到双方的小家，旧纸条仍保留在手机里。") }
                Section("两个人的小纸条") {
                    ForEach(shared.entries.filter { $0.kind == "note" }.reversed()) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.actor == "assistant" ? "他留给你的" : "我留下的").font(.caption).foregroundStyle(.secondary)
                            SharedNoteContent(text: note.text)
                            Text(note.day).font(.caption2).foregroundStyle(.tertiary)
                        }.padding(.vertical, 6)
                    }
                }
                Section("手机里原来的纸条") {
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
            SharedCalendarView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { timeline = false } } }
        }
    }
}
