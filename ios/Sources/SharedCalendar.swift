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
    @Published private(set) var syncing = false
    private var pending: [SharedEntry] = []
    private var deletions: Set<String> = []
    private var lastRefresh = Date.distantPast
    private var lastMonth = ""
    #if DEBUG
    var isPreview = false
    #endif
    init() {
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
            entries.removeAll { $0.day.hasPrefix(target) && !localIDs.contains($0.id) }
            entries.append(contentsOf: response.entries.filter { !localIDs.contains($0.id) && !deletions.contains($0.id) })
            lastMonth = target; lastRefresh = .now; error = nil; persist()
        } catch { self.error = "暂未同步；你的记录已留在手机，下次连接会继续。" }
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
    @EnvironmentObject private var shared: SharedSpace
    @EnvironmentObject private var model: CompanionModel
    @AppStorage("companion_name") private var name = "他"
    @State private var selected = Date.now
    @State private var editing = false
    @State private var editID: String?
    @State private var emoji = "🤍"
    @State private var note = ""
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
    private var records: [SharedEntry] { shared.on(selected) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("我们各自的一天").font(.system(.title2, design: .serif))
                        Text("心情、小记、日程，都在同一张日历里。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { editID = nil; emoji = "🤍"; note = ""; editing = true } label: {
                        Image(systemName: "plus").frame(width: 42, height: 42).glassSurface(in: Circle())
                    }.accessibilityLabel("记录我的心情")
                }
                VStack(spacing: 15) {
                    HStack {
                        Button { changeMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }.accessibilityLabel("上个月")
                        Spacer()
                        Text(shared.month, format: .dateTime.year().month()).font(.headline)
                        Spacer()
                        Button { changeMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }.accessibilityLabel("下个月")
                    }
                    HStack { ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) } }
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(Array(SharedDates.cells(shared.month).enumerated()), id: \.offset) { _, date in
                            if let date { cell(date) } else { Color.clear.frame(height: 58) }
                        }
                    }
                    HStack(spacing: 18) { legend("我", color: .pink); legend(name, color: .blue); Spacer(); Button("今天") { selected = .now; shared.month = .now }.font(.caption) }
                }.padding(16).glassSurface(in: RoundedRectangle(cornerRadius: 26))
                HStack {
                    Text(selected, format: .dateTime.month().day().weekday()).font(.headline)
                    Spacer(); Text("\(records.count) 条记录").font(.caption).foregroundStyle(.secondary)
                }
                if records.isEmpty {
                    Text("这一天还空着。你可以记自己的心情，他也可以留下他的。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(records) { entry in entryCard(entry) }
                if let error = shared.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text("保存记录会同步到两人的共享日历，供他读取，不会自动发成聊天消息。手机日程由授权的设备执行；待执行与失败会如实标注。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle("我们的日历").navigationBarTitleDisplayMode(.inline)
            .task(id: SharedDates.month(shared.month)) { if model.connected { await shared.sync(api: model.api, force: true) } }
            .refreshable { await shared.sync(api: model.api, force: true) }
            .sheet(isPresented: $editing) { editor }
    }
    private func changeMonth(_ direction: Int) {
        shared.month = SharedDates.calendar.date(byAdding: .month, value: direction, to: shared.month)!
        selected = shared.month
    }
    private func legend(_ title: String, color: Color) -> some View { HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(title).font(.caption2).foregroundStyle(.secondary) } }
    private func cell(_ date: Date) -> some View {
        let entries = shared.on(date)
        let current = SharedDates.key(date) == SharedDates.key(selected)
        return Button { selected = date } label: {
            VStack(spacing: 5) {
                Text("\(SharedDates.calendar.component(.day, from: date))").font(.subheadline.weight(current ? .semibold : .regular))
                HStack(spacing: 4) {
                    if entries.contains(where: { $0.actor == "user" }) { Circle().fill(.pink).frame(width: 5, height: 5) }
                    if entries.contains(where: { $0.actor == "assistant" }) { Circle().fill(.blue).frame(width: 5, height: 5) }
                    if entries.contains(where: { $0.kind == "event" }) { Image(systemName: "calendar").font(.system(size: 8)) }
                }.frame(height: 9)
            }.frame(maxWidth: .infinity, minHeight: 58).foregroundStyle(.primary)
                .background(current ? homeAccent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 13))
        }.buttonStyle(.plain).accessibilityLabel("\(SharedDates.key(date))，\(entries.count) 条记录")
    }
    private func entryCard(_ entry: SharedEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(entry.emoji.isEmpty ? entry.kind == "event" ? "🗓" : "📝" : entry.emoji).font(.title2)
                Text(entry.actor == "user" ? "我" : name).font(.subheadline.weight(.semibold))
                Spacer()
                Text(entry.kind == "event" ? "日程" : entry.kind == "mood" ? "心情" : "小记").font(.caption).foregroundStyle(.secondary)
            }
            if !entry.title.isEmpty { Text(entry.title).font(.headline) }
            if !entry.text.isEmpty { Text(entry.text).font(.subheadline).lineSpacing(4).textSelection(.enabled) }
            if let start = entry.start.flatMap(SharedDates.instant) { Text(start, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary) }
            if entry.status == "queued" { Label("待手机执行", systemImage: "clock").font(.caption).foregroundStyle(.secondary) }
            if entry.status == "failed" { Label("手机日历未写入", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
            if entry.status == "done" { Label("已写入手机日历", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
            if entry.status == "pending_sync" { Text("已保存在手机，等待同步").font(.caption).foregroundStyle(.secondary) }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).glassSurface(in: RoundedRectangle(cornerRadius: 24), tint: entry.actor == "user" ? .pink : .blue)
            .contextMenu {
                if entry.actor == "user" {
                    if entry.kind == "mood" {
                        Button("编辑这条记录") { editID = entry.id; emoji = entry.emoji; note = entry.text; selected = SharedDates.parse(entry.day) ?? selected; editing = true }
                    }
                    Button("删除", role: .destructive) { shared.delete(entry) }
                }
            }
    }
    private var editor: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("这一天", selection: $selected, displayedComponents: .date)
                    Picker("心情", selection: $emoji) { ForEach(["🤍", "🥰", "😊", "🥺", "😔", "😤", "😴"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                    TextField("只记录，也可以不用说出来", text: $note, axis: .vertical).lineLimit(3...8)
                } footer: { Text("这是你的记录。保存后会出现在双方共享日历里，他能读取；不会自动发送一条聊天消息，也不会替你判断心情。") }
            }.navigationTitle("记下我的一天").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editing = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存记录") { shared.saveMood(emoji: emoji, note: note, date: selected, id: editID); editing = false; Task { await shared.sync(api: model.api, force: true) } }
                            .accessibilityIdentifier("save-shared-mood")
                    }
                }
        }.presentationDetents([.medium, .large])
    }
}
