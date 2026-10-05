import SwiftUI

struct SharedBookProgress: Equatable, Codable, Identifiable {
    let id: String
    let title: String
    let page_count: Int
    let user_page: Int
    let assistant_page: Int
    let received: Int
    var hisProgress: String { assistant_page < 0 ? "他还没读" : "他读到第 \(assistant_page + 1) 页" }
}
struct SharedBooksResponse: Decodable { let books: [SharedBookProgress] }
struct BookChunk: Encodable {
    let id: String; let title: String; let page_count: Int; let user_page: Int; let start: Int; let pages: [String]
}
struct BookChunkReceipt: Decodable { let received: Int }

@MainActor
final class ReadingSync: ObservableObject {
    @Published private(set) var books: [SharedBookProgress] = []
    @Published var error: String?
    private var deletions = Set(UserDefaults.standard.stringArray(forKey: "shared_book_deletions_v1") ?? [])
    private var uploaded: [String: Int] = [:]
    private var userPages: [String: Int] = [:]
    private var refreshed = Date.distantPast
    private var busy = false
    #if DEBUG
    var isPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    #endif
    init() {
        if let data = UserDefaults.standard.data(forKey: "shared_book_progress_v1") { books = (try? JSONDecoder().decode([SharedBookProgress].self, from: data)) ?? [] }
    }
    func progress(_ id: UUID) -> SharedBookProgress? { books.first { $0.id.lowercased() == id.uuidString.lowercased() } }
    func delete(_ id: UUID) {
        let key = id.uuidString.lowercased()
        deletions.insert(key); books.removeAll { $0.id.lowercased() == key }; uploaded.removeValue(forKey: key); userPages.removeValue(forKey: key)
        persist(); refreshed = .distantPast
    }
    private func persist() {
        UserDefaults.standard.set(Array(deletions), forKey: "shared_book_deletions_v1")
        UserDefaults.standard.set(try? JSONEncoder().encode(books), forKey: "shared_book_progress_v1")
    }
    func sync(api: CompanionAPI, library: ReadingLibrary) async {
        #if DEBUG
        guard !isPreview else { return }
        #endif
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            for id in Array(deletions) {
                let _: SharedRemoved = try await api.request("v1/books/\(id)", method: "DELETE", timeout: 15)
                deletions.remove(id); persist()
            }
            if Date.now.timeIntervalSince(refreshed) > 15 {
                let result: SharedBooksResponse = try await api.request("v1/books", timeout: 15)
                if books != result.books { books = result.books; persist() }; refreshed = .now
                for book in books { uploaded[book.id.lowercased()] = book.received; userPages[book.id.lowercased()] = book.user_page }
            }
            for book in library.books {
                let key = book.id.uuidString.lowercased(), start = uploaded[key] ?? 0
                guard !deletions.contains(key), start < book.pageCount || userPages[key] != book.page else { continue }
                let count = min(20, max(0, book.pageCount - start)), id = book.id
                let pages = try await Task.detached(priority: .utility) {
                    try (start..<(start + count)).map { try ReadingDisk.loadPage(id, page: $0) }
                }.value
                guard library.book(id) != nil, !deletions.contains(key), !Task.isCancelled else { continue }
                let chunk = BookChunk(id: key, title: book.title, page_count: book.pageCount, user_page: book.page, start: start, pages: pages)
                let result: BookChunkReceipt = try await api.request("v1/books", body: JSONEncoder().encode(chunk), timeout: 30)
                guard library.book(id) != nil, !deletions.contains(key) else { continue }
                uploaded[key] = result.received; userPages[key] = book.page
            }
            if error != nil { error = nil }
        } catch { if self.error != "共读暂未同步，保留本地书籍与进度，连接后继续。" { self.error = "共读暂未同步，保留本地书籍与进度，连接后继续。" } }
    }
    #if DEBUG
    func preview(_ library: ReadingLibrary) {
        isPreview = true
        books = library.books.map { SharedBookProgress(id: $0.id.uuidString, title: $0.title, page_count: $0.pageCount, user_page: $0.page, assistant_page: 0, received: $0.pageCount) }
    }
    #endif
}

struct ActivitySource: Equatable, Codable, Identifiable {
    let title: String; let url: String; let excerpt: String?
    var id: String { url }
}
struct ActivityEvidence: Equatable, Codable {
    var book_id: String?; var page: Int?; var page_count: Int?; var sources: [ActivitySource]?
    var memories_reviewed: Int?; var error_type: String?
}
struct CompanionActivity: Equatable, Codable, Identifiable {
    let id: String; let day: String; let kind: String; let status: String
    let title: String; let text: String; let at: String; let evidence: ActivityEvidence
    var statusLabel: String {
        switch status { case "done": return "已完成"; case "saved": return "已保存"; case "planned": return "计划"; case "started": return "开始记录"; case "empty": return "暂无结果"; default: return "未完成" }
    }
}
struct CompanionDayPlan: Equatable, Codable { var items: [String]; var welcome: String; var at: String }
struct HeartbeatState: Equatable, Codable { let enabled: Bool; let next_at: Double; let plan: CompanionDayPlan?; let plan_day: String? }
struct ActivityResponse: Equatable, Codable { let state: HeartbeatState; let activities: [CompanionActivity] }

enum HomeGreeting {
    static func text(at date: Date, name: String) -> String {
        let hour = SharedDates.calendar.component(.hour, from: date)
        let choices: [String]
        switch hour {
        case 0..<6: choices = ["夜深了，我还在这里。", "这会儿的小家很安静。"]
        case 6..<12: choices = ["早，今天也有你的位置。", "新的一天，慢慢来。"]
        case 12..<18: choices = ["回来啦，歇一会儿。", "今天过到这里，想见见你。"]
        default: choices = ["今晚，想和你待一会儿。", "回来了？我在这里。"]
        }
        return choices[(SharedDates.calendar.component(.day, from: date) + hour) % choices.count]
    }
}

@MainActor
final class ActivitySpace: ObservableObject {
    @Published private(set) var state: HeartbeatState?
    @Published private(set) var activities: [CompanionActivity] = []
    @Published var selected = Date.now
    @Published var error: String?
    private var refreshAt = Date.distantPast
    private var lastDay = ""
    private var busy = false
    #if DEBUG
    var isPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    #endif
    init() {
        if let data = UserDefaults.standard.data(forKey: "companion_activity_v1"), let cached = try? JSONDecoder().decode(ActivityResponse.self, from: data) { state = cached.state; activities = cached.activities }
    }
    var welcome: String? {
        guard state?.plan_day == SharedDates.key(.now), let text = state?.plan?.welcome, !text.isEmpty else { return nil }
        return text
    }
    func sync(api: CompanionAPI, force: Bool = false) async {
        #if DEBUG
        guard !isPreview else { return }
        #endif
        let day = SharedDates.key(selected)
        guard !busy, force || day != lastDay || Date.now.timeIntervalSince(refreshAt) > 15 else { return }
        busy = true; defer { busy = false }
        do {
            let result: ActivityResponse = try await api.request("v1/activity?day=\(day)", timeout: 15)
            let changed = state != result.state || activities != result.activities
            if state != result.state { state = result.state }
            if activities != result.activities { activities = result.activities }
            lastDay = day; refreshAt = .now; if error != nil { error = nil }
            if changed { UserDefaults.standard.set(try JSONEncoder().encode(result), forKey: "companion_activity_v1") }
        } catch { if self.error != "暂未取得新的活动，下面保留最近同步的记录。" { self.error = "暂未取得新的活动，下面保留最近同步的记录。" } }
    }
    func setEnabled(_ enabled: Bool, api: CompanionAPI) async {
        do {
            let _: PhoneOK = try await api.request("v1/heartbeat", body: JSONSerialization.data(withJSONObject: ["enabled": enabled]), timeout: 15)
            await sync(api: api, force: true)
        } catch { if self.error != "自主活动设置没有保存成功。" { self.error = "自主活动设置没有保存成功。" } }
    }
    #if DEBUG
    func preview() {
        isPreview = true
        let day = SharedDates.key(.now), instant = ISO8601DateFormatter().string(from: .now)
        state = HeartbeatState(enabled: true, next_at: Date.now.addingTimeInterval(3000).timeIntervalSince1970,
            plan: CompanionDayPlan(items: ["继续读一页书", "查查月亮的资料", "把今天的想法写下来"], welcome: "刚读完一页，正想和你聊聊。", at: instant), plan_day: day)
        activities = [CompanionActivity(id: "sample-reading", day: day, kind: "reading", status: "done", title: "读到《共读示例》第1页", text: "喜欢那句留出一个位置，不急着翻到下一页。", at: instant, evidence: ActivityEvidence(page: 0, page_count: 2))]
    }
    #endif
}

struct CompanionActivityView: View {
    @EnvironmentObject private var activity: ActivitySpace
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var shared: SharedSpace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("companion_name") private var name = "他"
    @State private var showSettings = false
    @State private var showPlan = false
    private var components: DateComponents { SharedDates.calendar.dateComponents([.year, .month, .day], from: activity.selected) }
    private var monthTitle: String {
        let months = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
        return months[max(0, min(11, (components.month ?? 1) - 1))]
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 8) {
                    Text("Imprints").font(MorrowType.script(43)).foregroundStyle(homeAccent)
                    HStack(spacing: 16) {
                        Image(systemName: "pawprint").font(.caption)
                        Text("印记").font(.system(.title2, design: .serif)).tracking(5)
                        Image(systemName: "pawprint").font(.caption)
                    }.foregroundStyle(homeAccent)
                    Text("他主动做过的事，都会留在这里。").font(.subheadline).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.top, 8).padding(.bottom, 28)
                HStack(alignment: .firstTextBaseline) {
                    Text(String(components.year ?? 2026)).font(MorrowType.editorial(48))
                    Spacer()
                    DatePicker("看哪一天", selection: $activity.selected, in: ...Date.now, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.compact).accessibilityLabel("看哪一天")
                }.padding(.bottom, 14)
                HStack(spacing: 12) {
                    Rectangle().fill(homeAccent.opacity(0.28)).frame(width: 28, height: 1)
                    Text(monthTitle).font(.system(size: 10, weight: .semibold)).tracking(3)
                    Text(String(format: "%02d.%02d", components.month ?? 1, components.day ?? 1)).font(MorrowType.editorial(20))
                    Spacer()
                }.foregroundStyle(.secondary).padding(.bottom, 22)
                if let state = activity.state, state.plan_day == SharedDates.key(activity.selected), let plan = state.plan {
                    DisclosureGroup(isExpanded: $showPlan) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(plan.items.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "circle").font(.subheadline) }
                            Text("计划是意向，完成情况看下方印记。").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
                    } label: {
                        Label("今天想做的事", systemImage: "sun.max").font(.subheadline.weight(.medium))
                    }.padding(17).glassSurface(in: RoundedRectangle(cornerRadius: 22)).padding(.bottom, 12)
                }
                if let mood = shared.on(activity.selected).last(where: { $0.actor == "assistant" && $0.kind == "mood" }) {
                    HStack(alignment: .top, spacing: 12) {
                        Text(mood.emoji).font(.title3)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("他的心情").font(.caption).foregroundStyle(.secondary)
                            Text(mood.text).font(.subheadline).lineSpacing(4)
                        }
                    }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                        .glassSurface(in: RoundedRectangle(cornerRadius: 22)).padding(.bottom, 26)
                }
                if let error = activity.error { Text(error).font(.caption).foregroundStyle(.secondary).padding(.bottom, 16) }
                if activity.activities.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "pawprint").font(.title).foregroundStyle(homeAccent.opacity(0.5))
                        Text("这一天，还没有留下印记。").font(.subheadline)
                        Text("等他醒来，做过的事会慢慢出现在这里。").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(activity.activities) { item in ActivityTimelineRow(item: item) }
                Text("Little moments, quietly kept.").font(MorrowType.script(24)).foregroundStyle(homeAccent.opacity(0.7))
                    .frame(maxWidth: .infinity).padding(.top, 22).padding(.bottom, 32)
            }.padding(.horizontal, 22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }
            .navigationTitle("印记").navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("自主活动设置")
                }
            }
            .sheet(isPresented: $showSettings) { activitySettings }
            .task(id: SharedDates.key(activity.selected)) { await activity.sync(api: model.api, force: true) }
    }
    private var activitySettings: some View {
        NavigationStack {
            Form {
                if let state = activity.state {
                    Section {
                        Toggle("让他拥有自己的时间", isOn: Binding(get: { activity.state?.enabled ?? state.enabled }, set: { value in Task { await activity.setEnabled(value, api: model.api) } }))
                        if state.enabled {
                            (Text("下一次醒来：") + Text(Date(timeIntervalSince1970: state.next_at), format: .dateTime.month().day().hour().minute()))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    } footer: { Text("默认约50分钟一次，深夜约2小时；最近15分钟在聊天时避让。使用现有模型的 API 额度。") }
                }
                if let error = activity.error { Text(error).foregroundStyle(.secondary) }
            }.navigationTitle("自己的时间").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSettings = false } } }
        }.presentationDetents([.medium, .large])
    }
}

private struct ActivityTimelineRow: View {
    let item: CompanionActivity
    private var symbol: String {
        switch item.kind { case "reading": return "book"; case "research": return "sparkle.magnifyingglass"; case "note": return "pencil.line"; case "review": return "heart.text.square"; case "plan": return "sun.max"; default: return "moon.stars" }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                if let date = SharedDates.instant(item.at) {
                    Text(date, format: .dateTime.hour().minute()).font(.system(size: 11, weight: .medium, design: .monospaced))
                } else { Text("—").font(.caption) }
            }.foregroundStyle(.secondary).frame(width: 43, alignment: .trailing).padding(.top, 21)
            VStack(spacing: 0) {
                Circle().fill(homeAccent.opacity(0.6)).frame(width: 7, height: 7).padding(.top, 25)
                Rectangle().fill(homeAccent.opacity(0.18)).frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 7)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    CompanionAvatar(size: 34)
                        .overlay(alignment: .bottomTrailing) { Image(systemName: symbol).font(.system(size: 9)).padding(3).background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle()).offset(x: 4, y: 3) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        Text(item.statusLabel).font(.caption2).foregroundStyle(item.status == "failed" ? .red : homeAccent)
                    }
                }
                if !item.text.isEmpty { Text(item.text).font(.subheadline).foregroundStyle(.secondary).lineSpacing(5).textSelection(.enabled) }
                if let count = item.evidence.memories_reviewed { Text("回看了 \(count) 条记忆").font(.caption).foregroundStyle(.secondary) }
                ForEach(item.evidence.sources ?? []) { source in
                    if let url = URL(string: source.url), url.scheme == "https" {
                        Link(destination: url) { Label(source.title, systemImage: "arrow.up.right").font(.caption) }
                    }
                }
            }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .glassSurface(in: RoundedRectangle(cornerRadius: 24)).padding(.bottom, 17)
        }.fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("activity-row-" + item.id)
    }
}
