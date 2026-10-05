import SwiftUI

struct SharedBookProgress: Codable, Identifiable {
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
    var isPreview = false
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
                books = result.books; refreshed = .now
                for book in books { uploaded[book.id.lowercased()] = book.received; userPages[book.id.lowercased()] = book.user_page }
                persist()
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
            error = nil
        } catch { self.error = "共读暂未同步，保留本地书籍与进度，连接后继续。" }
    }
    #if DEBUG
    func preview(_ library: ReadingLibrary) {
        isPreview = true
        books = library.books.map { SharedBookProgress(id: $0.id.uuidString, title: $0.title, page_count: $0.pageCount, user_page: $0.page, assistant_page: 0, received: $0.pageCount) }
    }
    #endif
}

struct ActivitySource: Codable, Identifiable {
    let title: String; let url: String; let excerpt: String?
    var id: String { url }
}
struct ActivityEvidence: Codable {
    var book_id: String?; var page: Int?; var page_count: Int?; var sources: [ActivitySource]?
    var memories_reviewed: Int?; var error_type: String?
}
struct CompanionActivity: Codable, Identifiable {
    let id: String; let day: String; let kind: String; let status: String
    let title: String; let text: String; let at: String; let evidence: ActivityEvidence
    var statusLabel: String {
        switch status { case "done": return "已完成"; case "saved": return "已保存"; case "planned": return "计划"; case "started": return "开始记录"; case "empty": return "暂无结果"; default: return "未完成" }
    }
}
struct CompanionDayPlan: Codable { var items: [String]; var welcome: String; var at: String }
struct HeartbeatState: Codable { let enabled: Bool; let next_at: Double; let plan: CompanionDayPlan?; let plan_day: String? }
struct ActivityResponse: Codable { let state: HeartbeatState; let activities: [CompanionActivity] }

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
    var isPreview = false
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
            state = result.state; activities = result.activities; lastDay = day; refreshAt = .now; error = nil
            UserDefaults.standard.set(try JSONEncoder().encode(result), forKey: "companion_activity_v1")
        } catch { self.error = "暂未取得新的活动，下面保留最近同步的记录。" }
    }
    func setEnabled(_ enabled: Bool, api: CompanionAPI) async {
        do {
            let _: PhoneOK = try await api.request("v1/heartbeat", body: JSONSerialization.data(withJSONObject: ["enabled": enabled]), timeout: 15)
            await sync(api: api, force: true)
        } catch { self.error = "自主活动设置没有保存成功。" }
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
    @AppStorage("companion_name") private var name = "他"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("\(name)自己的时间").font(.system(.title2, design: .serif))
                Text("读书、探索、写随笔。看见计划，也看见实际做了什么。").font(.subheadline).foregroundStyle(.secondary)
                DatePicker("看哪一天", selection: $activity.selected, in: ...Date.now, displayedComponents: .date)
                if let state = activity.state {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("让他拥有自己的时间", isOn: Binding(get: { state.enabled }, set: { value in Task { await activity.setEnabled(value, api: model.api) } }))
                        if state.enabled {
                            (Text("下一次醒来：") + Text(Date(timeIntervalSince1970: state.next_at), format: .dateTime.month().day().hour().minute()))
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("自主活动已暂停").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("默认约50分钟一次，深夜约2小时；最近15分钟在聊天时让出时间。会使用现有模型的 API 额度。").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 22))
                    if state.plan_day == SharedDates.key(activity.selected), let plan = state.plan {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("今天想做的事").font(.headline)
                            ForEach(Array(plan.items.enumerated()), id: \.offset) { _, text in Label(text, systemImage: "circle") }
                            Text("这是计划；完成情况以底下的执行记录为准。").font(.caption).foregroundStyle(.secondary)
                        }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 22))
                    }
                }
                let mood = shared.on(activity.selected).last { $0.actor == "assistant" && $0.kind == "mood" }
                if let mood {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(mood.emoji) 他的心情").font(.headline); Text(mood.text).font(.subheadline)
                    }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 22))
                }
                Text("醒来之后").font(.headline)
                if let error = activity.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                if activity.activities.isEmpty { Text("还没有这一天的执行记录。等他醒来，做完的事会留在这里。").foregroundStyle(.secondary) }
                ForEach(activity.activities) { item in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(item.title).font(.headline); Spacer(); Text(item.statusLabel).font(.caption).foregroundStyle(item.status == "failed" ? .red : homeAccent) }
                        if let date = SharedDates.instant(item.at) { Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary) }
                        Text(item.text).font(.subheadline).textSelection(.enabled)
                        if let count = item.evidence.memories_reviewed { Text("实际查看了 \(count) 条记忆").font(.caption).foregroundStyle(.secondary) }
                        ForEach(item.evidence.sources ?? []) { source in
                            if let url = URL(string: source.url), url.scheme == "https" {
                                Link(source.title, destination: url).font(.subheadline)
                                if let excerpt = source.excerpt { Text(excerpt).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 22))
                }
            }.padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle("他的日常").navigationBarTitleDisplayMode(.inline)
            .task(id: SharedDates.key(activity.selected)) { await activity.sync(api: model.api, force: true) }
    }
}
