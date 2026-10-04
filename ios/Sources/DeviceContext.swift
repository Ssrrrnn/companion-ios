import SwiftUI
import UIKit

/// Opt-in, foreground-only local sampling. No background tracker or upload.
@MainActor
final class DeviceContext: NSObject, ObservableObject {
    @Published var enabled = UserDefaults.standard.bool(forKey: "device_battery_enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "device_battery_enabled"); configure() }
    }
    @Published private(set) var level: Int?
    @Published private(set) var charging = false
    @Published private(set) var lowPower = false
    @Published private(set) var sampledAt: Date?
    private var active = false
    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sample), name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(sample), name: UIDevice.batteryStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(sample), name: .NSProcessInfoPowerStateDidChange, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    func setActive(_ value: Bool) { active = value; configure() }
    func refresh() { sample() }
    private func configure() {
        UIDevice.current.isBatteryMonitoringEnabled = enabled && active
        if enabled && active { sample() }
        else { level = nil; sampledAt = nil; charging = false; lowPower = false }
    }
    @objc private func sample() {
        guard enabled, active else { return }
        let value = UIDevice.current.batteryLevel
        level = value < 0 ? nil : Int((value * 100).rounded())
        charging = [.charging, .full].contains(UIDevice.current.batteryState)
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        sampledAt = level == nil ? nil : .now
    }
    var summary: String {
        guard enabled else { return "尚未开启设备状态" }
        guard let level else { return "电量暂不可读取" }
        return "\(level)% · \(charging ? "正在充电" : lowPower ? "低电量模式" : "未在充电")"
    }
    var sharedDraft: String? {
        guard let level, let sampledAt else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "这是我手机刚读取的状态（北京时间 \(formatter.string(from: sampledAt))）：电量 \(level)%，\(charging ? "正在充电" : "没有充电")，低电量模式\(lowPower ? "已开启" : "未开启")。这是这次打开 App 时的状态，不代表之后一直不变。"
    }
}

struct DeviceContextView: View {
    @EnvironmentObject private var device: DeviceContext
    @AppStorage("chat_draft_v1") private var draft = ""
    var openChat: () -> Void
    var body: some View {
        Form {
            Section {
                Toggle("允许读取电量状态", isOn: $device.enabled)
                if device.enabled {
                    Label(device.summary, systemImage: device.charging ? "battery.100percent.bolt" : "battery.100percent")
                    if let date = device.sampledAt { Text(date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary) }
                    Button("把这次设备状态放进聊天") {
                        guard let message = device.sharedDraft else { return }
                        draft = draft.isEmpty ? message : draft + "\n\n" + message
                        openChat()
                    }.disabled(device.sharedDraft == nil)
                }
            } header: { Text("手机的此刻") }
              footer: { Text("只在 App 前台读取，不持续追踪，不自动上传。放进草稿后，仍由你按回车发送。关闭后停止读取并清除当前显示的状态。") }
            Section {
                Label("健康数据尚未接入", systemImage: "heart.text.square")
                Text("步数、睡眠、心率等需要 HealthKit 能力和逐项授权，还要确认你的 AltStore 免费签名能否支持。目前没有读取健康数据，也没有申请任何健康权限。")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("健康与隐私") }
              footer: { Text("后续只接入你选择的数据类型，默认不把原始健康记录发给模型。小家不是医疗诊断工具。") }
        }.scrollContentBackground(.hidden).background { GlassWallpaper() }
            .navigationTitle("设备与隐私").navigationBarTitleDisplayMode(.inline)
    }
}
