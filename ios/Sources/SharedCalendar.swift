import SwiftUI

enum SharedDates {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!; calendar.firstWeekday = 2
        return calendar
    }
    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    static func month(_ date: Date) -> String { String(key(date).prefix(7)) }
    static func parse(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
    static func instant(_ value: String) -> Date? {
        let format = ISO8601DateFormatter()
        if let date = format.date(from: value) { return date }
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.date(from: value)
    }
    static func cells(_ month: Date) -> [Date?] {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: month))!
        let count = calendar.range(of: .day, in: .month, for: start)!.count
        let offset = (calendar.component(.weekday, from: start) + 5) % 7
        var cells: [Date?] = Array(repeating: nil, count: offset)
        cells += (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }
}

struct SharedEntry: Codable, Identifiable, Equatable {
    let id: String
    let actor: String
    let kind: String
    let day: String
    var title: String
    var text: String
    var emoji: String
    var start: String?
    var end: String?
    var status: String = "saved"
}
struct SharedCollection: Decodable { let entries: [SharedEntry] }
struct SharedSave: Decodable { let entry: SharedEntry }
struct SharedRemoved: Decodable { let removed: Bool }

@MainActor
final class SharedSpace: ObservableObject {
    @Published private(set) var entries: [SharedEntry] = []
    @Published var month = Date.now
    @Published var error: String?
    private(set) var syncing = false
    private var pending: [SharedEntry] = []
    private var deletions: Set<String> = []
    private var lastRefresh = Date.distantPast
    private var lastMonth = ""
    #if DEBUG
    var isPreview = false
    #endif
    init() {
        #if DEBUG
        // Seed before a sheet's onAppear reads the note, rather than in the
        // scene task after cached edits from a previous test have been loaded.
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            preview(); return
        }
        #endif
        entries = Self.read("shared_calendar_cache_v1") ?? []
        pending = Self.read("shared_calendar_pending_v1") ?? []
        deletions = Set(Self.read("shared_calendar_deletions_v1") as [String]? ?? [])
    }
    private static func read<T: Decodable>(_ key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "shared_calendar_cache_v1")
        UserDefaults.standard.set(try? JSONEncoder().encode(pending), forKey: "shared_calendar_pending_v1")
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(deletions)), forKey: "shared_calendar_deletions_v1")
    }
    func on(_ day: Date) -> [SharedEntry] { entries.filter { $0.day == SharedDates.key(day) } }
    func saveMood(emoji: String, note: String, date: Date, id: String? = nil) {
        save(SharedEntry(id: id ?? UUID().uuidString, actor: "user", kind: "mood", day: SharedDates.key(date), title: "", text: String(note.prefix(2000)), emoji: emoji))
    }
    func save(_ entry: SharedEntry) {
        guard entry.actor == "user" else { return }
        var local = entry; local.status = "pending_sync"
        pending.removeAll { $0.id == entry.id }; pending.append(entry)
        entries.removeAll { $0.id == entry.id }; entries.append(local)
        deletions.remove(entry.id); persist(); lastRefresh = .distantPast
    }
    func delete(_ entry: SharedEntry) {
        guard entry.actor == "user" else { return }
        pending.removeAll { $0.id == entry.id }; entries.removeAll { $0.id == entry.id }
        deletions.insert(entry.id); persist(); lastRefresh = .distantPast
    }
    func migrate(_ moods: [MoodEntry]) {
        guard !UserDefaults.standard.bool(forKey: "shared_moods_migrated_v1") else { return }
        for mood in moods {
            saveMood(emoji: mood.emoji, note: mood.note, date: mood.date, id: mood.id.uuidString)
        }
        UserDefaults.standard.set(true, forKey: "shared_moods_migrated_v1")
    }
    func sync(api: CompanionAPI, force: Bool = false) async {
        #if DEBUG
        guard !isPreview else { return }
        #endif
        guard !syncing else { return }
        let target = SharedDates.month(month)
        guard force || lastMonth != target || Date.now.timeIntervalSince(lastRefresh) > 15 || !pending.isEmpty || !deletions.isEmpty else { return }
        syncing = true; defer { syncing = false }
        do {
            for identifier in Array(deletions) {
                let _: SharedRemoved = try await api.request("v1/shared/\(identifier)", method: "DELETE", timeout: 15)
                deletions.remove(identifier); persist()
            }
            for entry in pending {
                let response: SharedSave = try await api.request("v1/shared", body: JSONEncoder().encode(entry), timeout: 15)
                // An edit while the POST was in flight must remain queued.
                if pending.first(where: { $0.id == entry.id }) == entry {
                    pending.removeAll { $0.id == entry.id }
                    entries.removeAll { $0.id == entry.id }; entries.append(response.entry); persist()
                }
            }
            let response: SharedCollection = try await api.request("v1/shared?month=\(target)", timeout: 15)
            let localIDs = Set(pending.map(\.id))
            var merged = entries.filter { !$0.day.hasPrefix(target) || localIDs.contains($0.id) }
            merged.append(contentsOf: response.entries.filter { !localIDs.contains($0.id) && !deletions.contains($0.id) })
            if merged != entries { entries = merged; persist() }
            lastMonth = target; lastRefresh = .now; if error != nil { error = nil }
        } catch { if self.error != "暂未同步；你的记录已留在手机，下次连接会继续。" { self.error = "暂未同步；你的记录已留在手机，下次连接会继续。" } }
    }
    #if DEBUG
    func preview() {
        isPreview = true; month = .now
        let day = SharedDates.key(.now)
        entries = [SharedEntry(id: "preview-user", actor: "user", kind: "mood", day: day, title: "", text: "今天想慢一点，把心情留在这里。", emoji: "🤍"),
                   SharedEntry(id: "preview-him", actor: "assistant", kind: "mood", day: day, title: "翻到一页喜欢的话", text: "把那句话抄了下来。今天有点想念，也有自己的安静。", emoji: "📖")]
    }
    #endif
}

struct SharedCalendarView: View {
    var editOnOpen = false
    @EnvironmentObject private var shared: SharedSpace
    @EnvironmentObject private var model: CompanionModel
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("user_name") private var userName = "我"
    @State private var selected = Date.now
    @State private var sheet: MoodSheet?
    @State private var editID: String?
    @State private var emoji = "😊"
    @State private var note = ""
    @State private var section = 0
    @State private var confirmDelete = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private var records: [SharedEntry] { shared.on(selected) }
    private var monthly: [SharedEntry] { shared.entries.filter { $0.day.hasPrefix(SharedDates.month(shared.month)) } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    CompanionAvatar(size: 32)
                    Text("Our days").font(MorrowType.script(30))
                    Spacer()
                    Text(userName + " & " + name).font(MorrowType.editorial(15)).foregroundStyle(.secondary).lineLimit(1)
                }
                Picker("日历内容", selection: $section) {
                    Text("心情").tag(0); Text("日程与小记").tag(1)
                }.pickerStyle(.segmented)
                calendarCard
                HStack(spacing: 7) {
                    MoodBadge(emoji: nil, user: true, size: 12); Text(userName)
                    MoodBadge(emoji: nil, user: false, size: 12); Text(name)
                    Spacer(); Text("点日期查看详情")
                }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 13).padding(.vertical, 11)
                    .glassSurface(in: Capsule())
                Button { selected = .now; shared.month = .now; beginEditing() } label: {
                    Text("记录今日心情").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 15)
                        .foregroundStyle(.white).background(moodInk, in: Capsule())
                }.buttonStyle(.plain).accessibilityLabel("记录我的心情")
                if section == 0 {
                    MoodStatistics(title: userName + " 的心情", user: true, entries: monthly)
                    MoodStatistics(title: name + " 的心情", user: false, entries: monthly)
                } else {
                    Text(selected, format: .dateTime.month().day().weekday()).font(.headline)
                    let notes = records.filter { $0.kind != "mood" }
                    if notes.isEmpty { Text("这一天还没有日程或小记。").font(.subheadline).foregroundStyle(.secondary) }
                    ForEach(notes) { entry in entryCard(entry) }
                }
                if let error = shared.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text("各自记录，各自的心情。保存后彼此可见，不会自动发送聊天消息。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4).padding(.bottom, 20)
            }.padding(20).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle("我们的日历").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .task(id: SharedDates.month(shared.month)) { if model.connected { await shared.sync(api: model.api, force: true) } }
            .refreshable { await shared.sync(api: model.api, force: true) }
            .onAppear {
                if editOnOpen && sheet == nil { beginEditing() }
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--mood-editor") { beginEditing() }
                #endif
            }
            .sheet(item: $sheet) { value in
                if value == .editor { editor } else { details }
            }
    }
    private var calendarCard: some View {
        VStack(spacing: 14) {
            HStack {
                Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").font(.caption).frame(width: 36, height: 36).overlay(Circle().stroke(Color.secondary.opacity(0.25))) }.accessibilityLabel("上个月")
                Spacer()
                VStack(spacing: 1) {
                    Text(String(SharedDates.calendar.component(.year, from: shared.month))).font(.caption).foregroundStyle(.secondary)
                    Text(shared.month, format: .dateTime.month(.wide)).font(.system(.title2, design: .serif))
                }
                Spacer()
                Button { changeMonth(1) } label: { Image(systemName: "chevron.right").font(.caption).frame(width: 36, height: 36).overlay(Circle().stroke(Color.secondary.opacity(0.25))) }.accessibilityLabel("下个月")
            }.padding(.bottom, 6)
            HStack { ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
            LazyVGrid(columns: columns, spacing: 5) {
                ForEach(Array(SharedDates.cells(shared.month).enumerated()), id: \.offset) { _, date in
                    if let date { cell(date) } else { Color.clear.frame(height: 57) }
                }
            }
            Button("回到今天") { selected = .now; shared.month = .now }.font(.caption).foregroundStyle(.secondary)
        }.padding(15).glassSurface(in: RoundedRectangle(cornerRadius: 28))
    }
    private func cell(_ date: Date) -> some View {
        let entries = shared.on(date)
        let current = SharedDates.key(date) == SharedDates.key(selected)
        let mine = entries.last { $0.actor == "user" && $0.kind == "mood" }
        let his = entries.last { $0.actor == "assistant" && $0.kind == "mood" }
        return Button { selected = date; sheet = .details } label: {
            VStack(spacing: 3) {
                Text("\(SharedDates.calendar.component(.day, from: date))").font(.system(size: 11, weight: current ? .semibold : .regular, design: .serif))
                    .frame(width: 22, height: 22).background(current ? moodInk : .clear, in: Circle()).foregroundStyle(current ? Color.white : Color.primary)
                if section == 0 {
                    HStack(spacing: 3) {
                        MoodBadge(emoji: mine?.emoji, user: true, size: 14)
                        MoodBadge(emoji: his?.emoji, user: false, size: 14)
                    }
                } else {
                    HStack(spacing: 3) {
                        if entries.contains(where: { $0.kind == "event" }) { Image(systemName: "calendar").font(.system(size: 11)) }
                        if entries.contains(where: { $0.kind == "note" }) { Image(systemName: "note.text").font(.system(size: 11)) }
                    }.frame(height: 14)
                }
            }.frame(maxWidth: .infinity, minHeight: 57)
                .background(current ? moodInk.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? moodInk.opacity(0.65) : .clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(SharedDates.key(date))，\(entries.count) 条记录")
            .accessibilityIdentifier(current ? "mood-selected-day" : "mood-day-" + SharedDates.key(date))
    }
    private func changeMonth(_ direction: Int) {
        shared.month = SharedDates.calendar.date(byAdding: .month, value: direction, to: shared.month)!
        selected = shared.month
    }
    private func beginEditing() {
        let existing = records.last { $0.actor == "user" && $0.kind == "mood" }
        editID = existing?.id; emoji = existing?.emoji ?? "😊"; note = existing?.text ?? ""; sheet = .editor
    }
    private var details: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text(selected, format: .dateTime.year().month().day()).font(MorrowType.editorial(27))
                    Text("两个人的一天").font(.caption).foregroundStyle(.secondary)
                    if records.isEmpty { Text("这一天还没有记录。").foregroundStyle(.secondary).padding(.vertical, 20) }
                    ForEach(records) { entry in entryCard(entry) }
                    HStack {
                        Button("记录我的心情") { beginEditing() }.buttonStyle(.borderedProminent).tint(moodInk)
                        if records.contains(where: { $0.actor == "user" && $0.kind == "mood" }) {
                            Button("删除我的心情", role: .destructive) { confirmDelete = true }.buttonStyle(.bordered)
                        }
                    }
                }.padding(24)
            }.background { GlassWallpaper() }.navigationTitle("当天心情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { sheet = nil } } }
                .confirmationDialog("删除这一天我的心情记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除我的心情", role: .destructive) {
                        for entry in records where entry.actor == "user" && entry.kind == "mood" { shared.delete(entry) }
                        Task { await shared.sync(api: model.api, force: true) }
                    }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    private func entryCard(_ entry: SharedEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MoodBadge(emoji: entry.emoji.isEmpty ? nil : entry.emoji, user: entry.actor == "user", size: 30)
                Text((entry.actor == "user" ? userName : name) + " · " + (entry.kind == "mood" ? MoodStyle.label(entry.emoji) : entry.kind == "event" ? "日程" : "小记"))
                    .font(.subheadline.weight(.semibold))
            }
            if !entry.title.isEmpty { Text(entry.title).font(.headline) }
            if !entry.text.isEmpty { Text(entry.text).font(.subheadline).lineSpacing(5).textSelection(.enabled) }
            if let start = entry.start.flatMap(SharedDates.instant) { Text(start, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary) }
            if entry.status == "queued" { Label("待手机执行", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            if entry.status == "failed" { Label("手机日历未写入", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
            if entry.status == "done" { Label("已写入手机日历", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            if entry.status == "pending_sync" { Text("已保存在手机，等待同步").font(.caption).foregroundStyle(.secondary) }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).glassSurface(in: RoundedRectangle(cornerRadius: 22))
            .contextMenu {
                if entry.actor == "user" {
                    if entry.kind == "mood" { Button("编辑这条记录") { editID = entry.id; emoji = entry.emoji; note = entry.text; selected = SharedDates.parse(entry.day) ?? selected; sheet = .editor } }
                    Button("删除", role: .destructive) { shared.delete(entry) }
                }
            }
    }
    private var editor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("How do you feel?").font(MorrowType.script(34)).foregroundStyle(homeAccent)
                    DatePicker("这一天", selection: $selected, in: ...Date.now, displayedComponents: .date)
                    HStack { CompanionAvatar(size: 28, user: true); Text(userName).font(.headline); Spacer(); Text("记录自己的心情").font(.caption).foregroundStyle(.secondary) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 10) {
                        ForEach(MoodStyle.choices, id: \.emoji) { mood in
                            Button { emoji = mood.emoji } label: {
                                VStack(spacing: 7) {
                                    MoodBadge(emoji: mood.emoji, user: true, size: 33)
                                    Text(mood.title).font(.caption2).foregroundStyle(.primary)
                                }.frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .background(emoji == mood.emoji ? moodInk.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 15))
                                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(emoji == mood.emoji ? moodInk : .clear, lineWidth: 1.5))
                            }.buttonStyle(.plain).accessibilityLabel(mood.title).accessibilityAddTraits(emoji == mood.emoji ? .isSelected : [])
                        }
                    }
                    TextField("只记录，也可以不用说出来", text: $note, axis: .vertical).lineLimit(3...6)
                        .accessibilityIdentifier("mood-note")
                        .padding(16).glassSurface(in: RoundedRectangle(cornerRadius: 18))
                    Button {
                        let existing = records.last { $0.actor == "user" && $0.kind == "mood" }
                        let sameDayID = editID.flatMap { id in shared.entries.first(where: { $0.id == id && $0.day == SharedDates.key(selected) })?.id }
                        shared.saveMood(emoji: emoji, note: note, date: selected, id: sameDayID ?? existing?.id)
                        shared.month = selected; sheet = .details
                        Task { await shared.sync(api: model.api, force: true) }
                    } label: {
                        Text("保存心情").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(15).foregroundStyle(.white).background(moodInk, in: Capsule())
                    }.buttonStyle(.plain).accessibilityIdentifier("save-shared-mood")
                    Text("他的心情由他自己记录；你的记录会同步给他查看，不会发成聊天消息。").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }.background { GlassWallpaper() }.navigationTitle("记录心情").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { sheet = nil } } }
        }.presentationDetents([.large]).presentationDragIndicator(.visible)
    }
}
private enum MoodSheet: String, Identifiable { case details, editor; var id: String { rawValue } }
