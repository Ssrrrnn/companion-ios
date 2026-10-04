import SwiftUI
import EventKit

struct PhoneCalendar: Identifiable, Sendable { let id: String; let title: String; let writable: Bool }
struct PhoneEvent: Codable, Sendable { let title: String; let start: String; let end: String; let calendar: String }
struct PhoneBattery: Encodable { let level: Int; let charging: Bool; let low_power: Bool }
struct PhoneSnapshot: Encodable {
    let device_id: String
    let battery: PhoneBattery?
    let calendar_read: Bool
    let calendar_write: Bool
    let events: [PhoneEvent]
}
struct PhoneAction: Codable, Identifiable, Sendable {
    let id: String
    let kind: String
    let title: String
    let start: String
    let end: String
    let note: String?
    let alarm_minutes: Int?
}
struct PhoneActions: Decodable { let actions: [PhoneAction] }
struct PhoneOK: Decodable { let ok: Bool }
struct PhoneReceipt: Codable, Sendable {
    let device_id: String
    let success: Bool
    let event_id: String
    let message: String
}
struct PhoneReceiptResponse: Decodable { let result: PhoneReceiptResult }
struct PhoneReceiptResult: Decodable { let success: Bool; let event_id: String; let message: String }

enum PhoneRules {
    static func validate(_ action: PhoneAction, now: Date = .now) throws -> (Date, Date) {
        guard UUID(uuidString: action.id) != nil, action.kind == "create_calendar_event",
              !action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action.title.count <= 150,
              (action.note?.count ?? 0) <= 1000,
              let start = SharedDates.instant(action.start), let end = SharedDates.instant(action.end),
              start < end, end.timeIntervalSince(start) <= 7 * 86400,
              start >= now.addingTimeInterval(-300), start <= now.addingTimeInterval(366 * 86400),
              action.alarm_minutes == nil || (0...1440).contains(action.alarm_minutes!) else {
            throw ConnectionError.server("日程内容或时间不正确，这次没有写入。")
        }
        return (start, end)
    }
}

/// All EventKit I/O stays outside the main actor and returns plain values.
actor PhoneCalendarIO {
    private let store = EKEventStore()
    func authorize() async throws -> Bool { try await store.requestFullAccessToEvents() }
    func choices() -> [PhoneCalendar] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return store.calendars(for: .event).map { PhoneCalendar(id: $0.calendarIdentifier, title: $0.title, writable: $0.allowsContentModifications) }
    }
    func defaultID() -> String? { store.defaultCalendarForNewEvents?.calendarIdentifier }
    func events(selected: Set<String>) -> [PhoneEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess, !selected.isEmpty else { return [] }
        let calendars = store.calendars(for: .event).filter { selected.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let start = SharedDates.calendar.startOfDay(for: .now)
        let end = SharedDates.calendar.date(byAdding: .day, value: 30, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let format = ISO8601DateFormatter()
        return store.events(matching: predicate).sorted { $0.startDate < $1.startDate }.prefix(150).map {
            PhoneEvent(title: String(($0.title ?? "日程").prefix(150)), start: format.string(from: $0.startDate), end: format.string(from: $0.endDate), calendar: String($0.calendar.title.prefix(100)))
        }
    }
    func create(_ action: PhoneAction, calendarID: String) throws -> String {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
            throw ConnectionError.server("没有获准写入这个日历。")
        }
        let (start, end) = try PhoneRules.validate(action)
        let marker = URL(string: "xiaojia://calendar/\(action.id)")!
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-86400), end: end.addingTimeInterval(86400), calendars: [calendar])
        // Survives termination between EventKit save and receipt persistence.
        if let previous = store.events(matching: predicate).first(where: { $0.url == marker }), let id = previous.eventIdentifier { return id }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar; event.title = action.title; event.startDate = start; event.endDate = end
        event.timeZone = SharedDates.calendar.timeZone; event.notes = action.note; event.url = marker
        if let minutes = action.alarm_minutes { event.addAlarm(EKAlarm(relativeOffset: -Double(minutes * 60))) }
        try store.save(event, span: .thisEvent, commit: true)
        guard let identifier = event.eventIdentifier else { throw ConnectionError.server("保存回执未返回，暂未确认成功。") }
        return identifier
    }
}

@MainActor
final class PhoneBridge: ObservableObject {
    @Published var shareCalendar = UserDefaults.standard.bool(forKey: "phone_calendar_read_v1") { didSet { changed() } }
    @Published var allowCalendarWrites = UserDefaults.standard.bool(forKey: "phone_calendar_write_v1") { didSet { changed() } }
    @Published var selectedCalendars = Set(UserDefaults.standard.stringArray(forKey: "phone_calendar_ids_v1") ?? []) { didSet { changed() } }
    @Published var writeCalendar = UserDefaults.standard.string(forKey: "phone_write_calendar_v1") ?? "" { didSet { changed() } }
    @Published private(set) var calendars: [PhoneCalendar] = []
    @Published private(set) var authorized = false
    @Published private(set) var authorizing = false
    @Published private(set) var syncedAt: Date?
    @Published var error: String?
    let deviceID: String
    private let calendarIO = PhoneCalendarIO()
    private var receipts: [String: PhoneReceipt] = [:]
    private var busy = false
    private var lastSnapshot = Date.distantPast
    private var lastChoices = Date.distantPast
    private var revision = 0
    init() {
        if let id = UserDefaults.standard.string(forKey: "phone_installation_v1") { deviceID = id }
        else { deviceID = UUID().uuidString; UserDefaults.standard.set(deviceID, forKey: "phone_installation_v1") }
        if let data = UserDefaults.standard.data(forKey: "phone_receipts_v1") { receipts = (try? JSONDecoder().decode([String: PhoneReceipt].self, from: data)) ?? [:] }
    }
    private func changed() {
        revision += 1; lastSnapshot = .distantPast
        UserDefaults.standard.set(shareCalendar, forKey: "phone_calendar_read_v1")
        UserDefaults.standard.set(allowCalendarWrites, forKey: "phone_calendar_write_v1")
        UserDefaults.standard.set(Array(selectedCalendars), forKey: "phone_calendar_ids_v1")
        UserDefaults.standard.set(writeCalendar, forKey: "phone_write_calendar_v1")
    }
    func reloadCalendars() async {
        authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        calendars = await calendarIO.choices()
        if authorized && writeCalendar.isEmpty { writeCalendar = await calendarIO.defaultID() ?? calendars.first(where: \.writable)?.id ?? "" }
        lastChoices = .now
    }
    func authorize() async {
        guard !authorizing else { return }
        authorizing = true; defer { authorizing = false }
        do {
            let granted = try await calendarIO.authorize()
            await reloadCalendars()
            if !granted { error = "日历权限未获准，可以在系统设置中修改。" }
            else { error = nil }
        } catch { self.error = "系统没有授予日历访问权限。" }
    }
    func tick(api: CompanionAPI, device: DeviceContext) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            if Date.now.timeIntervalSince(lastChoices) > 30 { await reloadCalendars() }
            device.refresh()
            if Date.now.timeIntervalSince(lastSnapshot) > 20 {
                let version = revision
                let events = shareCalendar && authorized ? await calendarIO.events(selected: selectedCalendars) : []
                // Don't upload a fetch completed after the user revoked sharing.
                guard version == revision else { return }
                let snapshot = PhoneSnapshot(device_id: deviceID,
                    battery: device.enabled && device.level != nil ? PhoneBattery(level: device.level!, charging: device.charging, low_power: device.lowPower) : nil,
                    calendar_read: shareCalendar && authorized && !selectedCalendars.isEmpty,
                    calendar_write: allowCalendarWrites && authorized && calendars.contains(where: { $0.id == writeCalendar && $0.writable }), events: events)
                let encoded = try JSONEncoder().encode(snapshot)
                let _: PhoneOK = try await api.request("v1/phone/context", body: encoded, timeout: 15)
                lastSnapshot = .now; syncedAt = .now
            }
            let result: PhoneActions = try await api.request("v1/phone/actions?device_id=\(deviceID)", timeout: 15)
            for action in result.actions {
                guard !Task.isCancelled else { return }
                let receipt: PhoneReceipt
                if let previous = receipts[action.id] { receipt = previous }
                else {
                    do {
                        guard allowCalendarWrites, authorized else { throw ConnectionError.server("自动添加日程未授权，已停止这次操作。") }
                        try Task.checkCancellation()
                        let eventID = try await calendarIO.create(action, calendarID: writeCalendar)
                        receipt = PhoneReceipt(device_id: deviceID, success: true, event_id: eventID, message: "已通过手机日历保存。")
                    } catch {
                        receipt = PhoneReceipt(device_id: deviceID, success: false, event_id: "", message: "日程没有写入，请检查日历权限、目标日历和时间。")
                    }
                    receipts[action.id] = receipt
                    UserDefaults.standard.set(try JSONEncoder().encode(receipts), forKey: "phone_receipts_v1")
                }
                let _: PhoneReceiptResponse = try await api.request("v1/phone/actions/\(action.id)/receipt", body: JSONEncoder().encode(receipt), timeout: 15)
            }
            error = nil
        } catch { self.error = "手机能力暂未同步，请检查小家连接。" }
    }
    func batterySettingChanged() { lastSnapshot = .distantPast }
}

struct PhonePermissionsView: View {
    @EnvironmentObject private var bridge: PhoneBridge
    @EnvironmentObject private var device: DeviceContext
    var body: some View {
        Form {
            Section {
                Toggle("允许他读取电量与充电状态", isOn: $device.enabled)
                    .onChange(of: device.enabled) { _, _ in bridge.batterySettingChanged() }
                if device.enabled { Label(device.summary, systemImage: "battery.100percent") }
                if let date = bridge.syncedAt { Text("最近同步：\(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            } footer: { Text("开启后，App 在前台自动同步这些状态。他可以调用读取工具，快照附带同步时间，不需要你发聊天消息。") }
            Section {
                if !bridge.authorized {
                    Button(bridge.authorizing ? "等待系统授权" : "授权手机日历访问") { Task { await bridge.authorize() } }.disabled(bridge.authorizing)
                }
                Toggle("允许他读取所选日历", isOn: $bridge.shareCalendar).disabled(!bridge.authorized)
                if bridge.shareCalendar && bridge.authorized {
                    ForEach(bridge.calendars) { calendar in
                        Toggle(calendar.title, isOn: Binding(get: { bridge.selectedCalendars.contains(calendar.id) }, set: { value in
                            if value { bridge.selectedCalendars.insert(calendar.id) } else { bridge.selectedCalendars.remove(calendar.id) }
                        }))
                    }
                }
                Toggle("允许他自动添加日程", isOn: $bridge.allowCalendarWrites).disabled(!bridge.authorized)
                if bridge.allowCalendarWrites && bridge.authorized {
                    Picker("日程写入这里", selection: $bridge.writeCalendar) {
                        ForEach(bridge.calendars.filter(\.writable)) { calendar in Text(calendar.title).tag(calendar.id) }
                    }
                }
            } header: { Text("手机日历") }
              footer: { Text("只分享所选日历未来 30 天的标题、时间和日历名称，不分享备注、地点或参与者。开启自动添加后，他可在你选定的日历创建日程；没有删除或改动旧日程的工具。") }
            Section {
                Text("App 前台会接收操作并回传真实结果。手机离线、App 关闭或系统暂停时，日程会等待执行；双方月历会标出结果，不能保证锁屏后即时执行。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = bridge.error { Text(error).font(.caption).foregroundStyle(.red) }
                Button("打开系统权限设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            } header: { Text("连接与执行") }
            Section("尚未授权的功能") {
                Text("健康、相册、通讯录、定位、屏幕内容和其他 App 的私聊尚未接入。他不能通过日历权限读取这些内容。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background { GlassWallpaper() }
            .navigationTitle("他的手机权限").navigationBarTitleDisplayMode(.inline)
            .task { await bridge.reloadCalendars() }
    }
}
