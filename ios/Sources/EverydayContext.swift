import SwiftUI
import UserNotifications
import HealthKit

@MainActor
final class MorrowNotifications: NSObject, ObservableObject, @preconcurrency UNUserNotificationCenterDelegate {
    @Published private(set) var status = "尚未申请"
    @Published private(set) var allowed = false
    @Published var reminders = UserDefaults.standard.bool(forKey: "daily_reminder") {
        didSet { UserDefaults.standard.set(reminders, forKey: "daily_reminder"); Task { await scheduleReminder() } }
    }
    private let center = UNUserNotificationCenter.current()
    override init() { super.init(); center.delegate = self }
    func reload() async {
        let settings = await center.notificationSettings()
        allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        status = allowed ? "系统通知已允许" : settings.authorizationStatus == .denied ? "系统通知已关闭" : "尚未申请"
    }
    func authorize() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .badge, .sound]); await reload(); await scheduleReminder() }
        catch { status = "通知授权未完成" }
    }
    func observe(_ messages: [Message]) {
        let defaults = UserDefaults.standard
        let latest = messages.compactMap { Int($0.id.split(separator: ":").first.map(String.init) ?? "") }.max() ?? 0
        guard latest > 0 else { return }
        let previous = defaults.integer(forKey: "notification_history_cursor")
        defaults.set(max(previous, latest), forKey: "notification_history_cursor")
        guard previous > 0, allowed else { return }
        let fresh = messages.filter { $0.role == "assistant" && (Int($0.id.split(separator: ":").first.map(String.init) ?? "") ?? 0) > previous }
        guard let message = fresh.last else { return }
        let content = UNMutableNotificationContent()
        content.title = UserDefaults.standard.string(forKey: "companion_name") ?? "Morrow"
        content.body = String(message.text.prefix(180)); content.sound = .default
        content.userInfo = ["destination": "chat"]
        center.add(UNNotificationRequest(identifier: "message-" + message.id, content: content, trigger: nil))
    }
    private func scheduleReminder() async {
        center.removePendingNotificationRequests(withIdentifiers: ["daily-journal"])
        guard allowed, reminders else { return }
        let content = UNMutableNotificationContent(); content.title = "把今天留在小家"
        content.body = "写一张纸条，或记下今天的心情。"; content.sound = .default
        var date = DateComponents(); date.hour = 21; date.minute = 0
        try? await center.add(UNNotificationRequest(identifier: "daily-journal", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: date, repeats: true)))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) { handler([.banner, .sound]) }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler handler: @escaping () -> Void) {
        Task { @MainActor in NotificationCenter.default.post(name: .morrowOpenChat, object: nil) }; handler()
    }
}
extension Notification.Name { static let morrowOpenChat = Notification.Name("morrow-open-chat") }

struct WeatherResponse: Decodable {
    struct Current: Decodable { let temperature_2m: Double; let apparent_temperature: Double; let weather_code: Int; let wind_speed_10m: Double }
    let current: Current
}
@MainActor
final class WeatherSpace: ObservableObject {
    @Published private(set) var current: WeatherResponse.Current?
    @Published private(set) var updated: Date?
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published var enabled = UserDefaults.standard.bool(forKey: "weather_enabled") { didSet { UserDefaults.standard.set(enabled, forKey: "weather_enabled"); if !enabled { current = nil; updated = nil } } }
    #if DEBUG
    func preview() { current = WeatherResponse.Current(temperature_2m: 22, apparent_temperature: 21, weather_code: 2, wind_speed_10m: 6); updated = .now }
    #endif
    func refresh(location: LocationContext, force: Bool = false) async {
        guard enabled, !loading, force || updated == nil || Date.now.timeIntervalSince(updated!) > 1800 else { return }
        loading = true; defer { loading = false }
        guard let position = await location.request() else { error = location.error ?? "请允许定位后刷新天气"; return }
        do {
            var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            // Coarse coordinates are sufficient for forecast lookup.
            url.queryItems = [URLQueryItem(name: "latitude", value: String(format: "%.2f", position.latitude)), URLQueryItem(name: "longitude", value: String(format: "%.2f", position.longitude)), URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,wind_speed_10m"), URLQueryItem(name: "timezone", value: "auto")]
            var request = URLRequest(url: url.url!); request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ConnectionError.server("天气服务暂未返回") }
            let result = try JSONDecoder().decode(WeatherResponse.self, from: data)
            guard enabled else { return }; current = result.current; updated = .now; error = nil
        } catch { self.error = "天气暂未刷新，稍后重试" }
    }
    nonisolated static func description(_ code: Int) -> (String, String) {
        switch code {
        case 0: return ("晴", "sun.max.fill")
        case 1...3: return ("多云", "cloud.sun.fill")
        case 45, 48: return ("雾", "cloud.fog.fill")
        case 51...67, 80...82: return ("雨", "cloud.rain.fill")
        case 71...77, 85, 86: return ("雪", "cloud.snow.fill")
        case 95...99: return ("雷雨", "cloud.bolt.rain.fill")
        default: return ("天气", "cloud.fill")
        }
    }
}
struct WeatherCard: View {
    @EnvironmentObject private var weather: WeatherSpace
    @EnvironmentObject private var location: LocationContext
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("窗外的天气", systemImage: "location.circle").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await weather.refresh(location: location, force: true) } } label: { Image(systemName: "arrow.clockwise") }.disabled(weather.loading || !weather.enabled).accessibilityLabel("刷新天气")
            }
            if let value = weather.current {
                let description = WeatherSpace.description(value.weather_code)
                HStack(alignment: .center) {
                    Image(systemName: description.1).symbolRenderingMode(.multicolor).font(.system(size: 35))
                    Text("\(Int(value.temperature_2m.rounded()))°").font(.system(size: 38, weight: .light, design: .rounded))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(description.0).font(.headline)
                        Text("体感 \(Int(value.apparent_temperature.rounded()))° · 风速 \(Int(value.wind_speed_10m)) km/h").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(weather.enabled ? weather.error ?? "等一阵来自窗外的风" : "打开定位天气，让今天多一点温度").font(.subheadline).foregroundStyle(.secondary)
                if !weather.enabled { Button("开启定位天气") { weather.enabled = true; location.enabled = true }.font(.caption) }
            }
            HStack {
                Link("Open-Meteo", destination: URL(string: "https://open-meteo.com/")!).font(.caption2)
                Spacer()
                if let updated = weather.updated { Text(updated, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.tertiary) }
            }
            if weather.current != nil, let error = weather.error { Text(error).font(.caption2).foregroundStyle(.secondary) }
        }.padding(20).glassSurface(in: RoundedRectangle(cornerRadius: 25))
            .task(id: location.authorized) { await weather.refresh(location: location) }
            .onChange(of: weather.enabled) { _, value in if value { Task { await weather.refresh(location: location) } } }
    }
}

struct BrowsingEntry: Decodable, Identifiable { let id: String; let url: String; let title: String; let excerpt: String; let status: String; let at: String }
struct BrowsingResult: Decodable { let items: [BrowsingEntry] }
struct BrowsingLogView: View {
    @EnvironmentObject private var model: CompanionModel
    @State private var items: [BrowsingEntry] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("他实际读过的网页，留在这里。只读公开页面，不登录账号。").font(.subheadline).foregroundStyle(.secondary)
                if items.isEmpty { ContentUnavailableView("还没有浏览记录", systemImage: "globe", description: Text(error ?? "他查询兴趣话题或读取网页后，会留下记录。")) }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack { Image(systemName: item.status == "read" ? "globe" : "exclamationmark.circle"); Text(item.status == "read" ? "已读取" : "未读取成功").font(.caption); Spacer(); Text(SharedDates.instant(item.at) ?? .distantPast, format: .dateTime.month().day().hour().minute()).font(.caption2) }.foregroundStyle(.secondary)
                        Text(item.title).font(.headline)
                        if let url = URL(string: item.url), url.scheme == "https" { Link(url.host ?? "打开网页", destination: url).font(.caption) }
                        Text(item.excerpt).font(.subheadline).foregroundStyle(.secondary).lineLimit(8).textSelection(.enabled)
                    }.padding(20).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                }
                if !items.isEmpty, let error { Text(error).font(.caption).foregroundStyle(.secondary) }
            }.padding(22)
        }.background { GlassWallpaper() }.navigationTitle("网上散步").task { await refresh() }.refreshable { await refresh() }
    }
    private func refresh() async {
        guard model.connected else { error = "连接小家后再刷新"; return }
        do { let result: BrowsingResult = try await model.api.request("v1/browsing"); items = result.items; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class HealthSpace: ObservableObject {
    @Published var steps = ""
    @Published var sleep = ""
    @Published var status: String?
    @Published var busy = false
    @Published private(set) var source = "manual"
    private let health = HKHealthStore()
    var nativeEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "MorrowHealthKitEnabled") as? Bool == true }
    func readNative() async {
        guard nativeEnabled, HKHealthStore.isHealthDataAvailable() else { status = "当前免费签名版本未启用健康读取。可手动分享概要。"; return }
        busy = true; defer { busy = false }
        do {
            let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount)!
            try await health.requestAuthorization(toShare: [], read: [stepType])
            let start = Calendar.current.startOfDay(for: .now)
            let predicate = HKQuery.predicateForSamples(withStart: start, end: .now, options: .strictStartDate)
            let count: Double? = try await withCheckedThrowingContinuation { continuation in
                let query = HKStatisticsQuery(quantityType: stepType, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, result, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: .count())) }
                }; health.execute(query)
            }
            steps = count.map { String(Int($0)) } ?? ""; source = "healthkit"
            status = "已查询今日步数。空白可能是没有记录或未获读取许可。"
        } catch { status = "健康读取未完成，请检查签名能力和系统授权。" }
    }
    func share(api: CompanionAPI) async {
        busy = true; defer { busy = false }
        var data: [String: Any] = ["source": source]
        if !steps.isEmpty { guard let value = Int(steps), (0...200000).contains(value) else { status = "步数格式不正确"; return }; data["steps"] = value }
        if !sleep.isEmpty { guard let value = Double(sleep), (0...24).contains(value) else { status = "睡眠小时格式不正确"; return }; data["sleep_hours"] = value }
        guard data.count > 1 else { status = "先填写要分享的概要"; return }
        do { let _: PhoneOK = try await api.request("v1/context/health", body: JSONSerialization.data(withJSONObject: data)); status = "概要已分享给他" }
        catch { status = error.localizedDescription }
    }
    func clear(api: CompanionAPI) async {
        do { let _: PhoneOK = try await api.request("v1/context/health", body: Data("null".utf8)); steps = ""; sleep = ""; status = "已移除服务器上的健康概要" }
        catch { status = error.localizedDescription }
    }
    func edited() { source = "manual" }
}
struct EverydayPermissionsView: View {
    @EnvironmentObject private var notifications: MorrowNotifications
    @EnvironmentObject private var weather: WeatherSpace
    @EnvironmentObject private var location: LocationContext
    @EnvironmentObject private var health: HealthSpace
    @EnvironmentObject private var model: CompanionModel
    var body: some View {
        Form {
            Section("消息通知") {
                Label(notifications.status, systemImage: "bell")
                Button("允许 Morrow 通知") { Task { await notifications.authorize() } }
                Toggle("每天 21:00 提醒记下今天", isOn: $notifications.reminders)
                Text("主动消息直接保存在 Morrow。当前免费 AltStore 版本打开 App 后同步消息；关闭 App 后无法接收服务器推送。日常提醒是手机本地通知。").font(.footnote).foregroundStyle(.secondary)
                Button("打开系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Section("窗外天气") {
                Toggle("使用定位查询天气", isOn: $weather.enabled).onChange(of: weather.enabled) { _, enabled in if enabled { location.enabled = true } }
                Text("天气坐标会以约一公里精度发送给 Open-Meteo。定位分享开关在手机权限中，可随时关闭。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("健康概要") {
                if health.nativeEnabled { Button("申请健康读取并查询今日步数") { Task { await health.readNative() } }.disabled(health.busy) }
                else { Text("当前免费签名版本不能直接读取健康 App。可以自愿填写步数和睡眠概要，让他知道你的近况。").font(.footnote).foregroundStyle(.secondary) }
                TextField("今日步数（可留空）", text: Binding(get: { health.steps }, set: { health.steps = $0; health.edited() })).keyboardType(.numberPad)
                TextField("昨晚睡眠小时（可留空）", text: Binding(get: { health.sleep }, set: { health.sleep = $0; health.edited() })).keyboardType(.decimalPad)
                Button("只分享这份概要") { Task { await health.share(api: model.api) } }.disabled(health.busy || !model.connected)
                Button("移除已分享的健康概要", role: .destructive) { Task { await health.clear(api: model.api) } }.disabled(!model.connected)
                if let status = health.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }.scrollContentBackground(.hidden).background { GlassWallpaper() }.navigationTitle("通知与日常权限").task { await notifications.reload() }
    }
}
