import SwiftUI

/// Open from the right with a leftward swipe, without capturing vertical scrolling.
enum HomeSwipe {
    static func opens(x: CGFloat, y: CGFloat) -> Bool { x < -70 && abs(x) > abs(y) * 1.7 }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(homeAccent)
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(in: RoundedRectangle(cornerRadius: 25))
    }
}

struct HomeSidebar: View {
    @EnvironmentObject private var model: CompanionModel
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("relationship_caption") private var caption = "把日常，留在我们的小家。"
    @AppStorage("app_appearance") private var appearance = "system"
    let close: () -> Void
    let open: (CompanionRoute) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("我们的小世界").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44).background(homeAccent.opacity(0.1), in: Circle()) }
                        .accessibilityLabel("关闭侧边栏")
                }
                VStack(alignment: .leading, spacing: 12) {
                    CompanionAvatar(size: 64)
                    Text(name).font(.system(.title, design: .serif).weight(.medium))
                    Text(caption).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
                    Label(model.connected ? "小家已连接" : "等待连接", systemImage: model.connected ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.caption).foregroundStyle(homeAccent)
                }
                VStack(spacing: 4) {
                    item("设置与外观", subtitle: "头像、壁纸与纪念日", icon: "slider.horizontal.3", route: .settings)
                    item("他的电台", subtitle: "把文字，读成陪伴", icon: "dot.radiowaves.left.and.right", route: .radio)
                    item("一起听", subtitle: "音乐与播客", icon: "music.note", route: .listening)
                    item("一起读书", subtitle: "停在同一页", icon: "books.vertical", route: .books)
                    item("我们的日历", subtitle: "心情与小小约定", icon: "calendar", route: .calendar)
                }.padding(8).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                VStack(spacing: 4) {
                    item("通知、天气与健康", subtitle: "照顾每天的生活", icon: "bell", route: .permissions)
                    item("手机权限", subtitle: "日历与定位分享", icon: "iphone", route: .device)
                    item("网上散步", subtitle: "看看他发现了什么", icon: "globe", route: .browsing)
                    item("他的日常", subtitle: "规划与自主活动", icon: "pawprint", route: .activity)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("小家的光线").font(.caption).foregroundStyle(.secondary)
                    Picker("外观", selection: $appearance) {
                        Text("自动").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                    }.pickerStyle(.segmented).accessibilityIdentifier("sidebar-appearance")
                }
                Text("Morrow").font(MorrowType.script(30)).foregroundStyle(homeAccent).padding(.top, 6)
            }.padding(24)
        }.background(homePaper).accessibilityIdentifier("home-sidebar")
            .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded { value in
                if value.translation.width > 70 && abs(value.translation.width) > abs(value.translation.height) * 1.7 { close() }
            })
    }
    private func item(_ title: String, subtitle: String, icon: String, route: CompanionRoute) -> some View {
        Button { open(route) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(homeAccent).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 8).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("sidebar-open-" + String(describing: route))
    }
}
