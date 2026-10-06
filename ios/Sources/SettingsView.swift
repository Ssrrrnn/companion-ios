import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var space: PersonalSpace
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("user_name") private var userName = "我"
    @AppStorage("relationship_caption") private var caption = "把日常，留在我们的小家。"
    @AppStorage("anniversary_enabled") private var anniversaryEnabled = false
    @AppStorage("anniversary_date") private var anniversary = Date.now.timeIntervalSince1970
    @AppStorage("chat_palette") private var palette = "blue"
    @AppStorage("chat_haptics") private var haptics = true
    @AppStorage("app_appearance") private var appearance = "system"
    @AppStorage("wallpaper_style") private var wallpaperStyle = "linen"
    @AppStorage("wallpaper_shade") private var wallpaperShade = 0.12
    @AppStorage("wallpaper_blur") private var wallpaperBlur = 0.0
    @State private var base = UserDefaults.standard.string(forKey: "server_url") ?? ""
    @State private var token = ConnectionKey.read()
    @State private var connecting = false
    @State private var saved = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var userAvatarItem: PhotosPickerItem?
    @State private var wallpaperItem: PhotosPickerItem?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make it ours.").font(MorrowType.editorial(32)).foregroundStyle(homeAccent)
                    Text("把小家，慢慢布置成喜欢的样子。").font(.subheadline).foregroundStyle(.secondary)
                }.padding(.vertical, 8)
                profileCard
                SettingsCard(title: "我们的第一天", icon: "heart") {
                    Toggle("显示相恋天数", isOn: $anniversaryEnabled)
                        .onChange(of: anniversaryEnabled) { _, enabled in
                            if enabled && UserDefaults.standard.object(forKey: "anniversary_date") == nil { anniversary = Date.now.timeIntervalSince1970 }
                        }
                    if anniversaryEnabled {
                        DatePicker("纪念日", selection: Binding(get: { Date(timeIntervalSince1970: anniversary) }, set: { anniversary = $0.timeIntervalSince1970 }), in: ...Date.now, displayedComponents: .date)
                    }
                }
                appearanceCard
                SettingsCard(title: "一起生活", icon: "sparkles") {
                    settingLink("他的电台", icon: "dot.radiowaves.left.and.right", route: .radio)
                    Divider()
                    settingLink("通知、天气与健康", icon: "bell", route: .permissions)
                    Divider()
                    settingLink("他的手机权限", icon: "iphone", route: .device)
                    Divider()
                    settingLink("一起听音乐与播客", icon: "music.note", route: .listening)
                }
                SettingsCard(title: "连接我们的小家", icon: "link") {
                    Label(model.connected ? "已连接" : "尚未连接", systemImage: model.connected ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.subheadline).foregroundStyle(homeAccent)
                    DisclosureGroup("服务连接信息") {
                        VStack(alignment: .leading, spacing: 16) {
                            TextField("HTTPS 服务地址", text: $base).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            SecureField("连接密钥", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder)
                            Button(connecting ? "正在连接" : "保存并连接") {
                                connecting = true
                                Task { saved = await model.connect(base: base, token: token); connecting = false }
                            }.buttonStyle(.borderedProminent).disabled(connecting || model.sending || model.pending != nil)
                            if saved { Label("已经连接", systemImage: "checkmark.circle").foregroundStyle(homeAccent) }
                            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red) }
                            Text("模型与语音服务密钥由服务端保存。").font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 16)
                    }.font(.subheadline)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Link(destination: URL(string: "https://github.com/Ssrrrnn/companion-ios/releases")!) {
                        HStack { Text("Morrow · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")"); Spacer(); Text("版本更新"); Image(systemName: "arrow.up.right") }
                    }.font(.caption)
                    Text("头像、壁纸与手动收藏保存在手机里。心情与共享纸条同步到双方的小家。当前免费签名版本需打开 App 同步主动消息。")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(6)
            }.padding(22).frame(maxWidth: 680).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar).accessibilityIdentifier("settings-scroll")
            .onChange(of: avatarItem) { _, item in if let item { Task { await space.setImage(item, wallpaper: false) } } }
            .onChange(of: userAvatarItem) { _, item in if let item { Task { await space.setImage(item, wallpaper: false, userAvatar: true) } } }
            .onChange(of: wallpaperItem) { _, item in if let item { Task { await space.setImage(item, wallpaper: true) } } }
    }
    private var profileCard: some View {
        SettingsCard(title: "两个人的小家", icon: "house") {
            HStack(spacing: 16) {
                CompanionAvatar(size: 58)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("他的名字", text: $name).font(.headline).accessibilityIdentifier("settings-companion-name")
                    PhotosPicker("更换他的头像", selection: $avatarItem, matching: .images).font(.caption)
                }
            }
            if space.avatar != nil { Button("恢复他的文字头像") { space.removeImage(wallpaper: false) }.font(.caption) }
            Divider()
            HStack(spacing: 16) {
                CompanionAvatar(size: 58, user: true)
                VStack(alignment: .leading, spacing: 8) {
                    TextField("我的名字", text: $userName).font(.headline)
                    PhotosPicker("更换我的头像", selection: $userAvatarItem, matching: .images).font(.caption)
                }
            }
            if space.userAvatar != nil { Button("恢复我的文字头像") { space.removeImage(wallpaper: false, userAvatar: true) }.font(.caption) }
            Divider()
            TextField("小家的签名", text: $caption, axis: .vertical).font(.subheadline).lineLimit(1...3)
        }
    }
    private var appearanceCard: some View {
        SettingsCard(title: "光线、颜色与触感", icon: "paintpalette") {
            VStack(alignment: .leading, spacing: 10) {
                Text("外观").font(.subheadline.weight(.medium))
                Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                    .pickerStyle(.segmented).accessibilityIdentifier("settings-appearance")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("气泡颜色").font(.subheadline.weight(.medium))
                Picker("气泡颜色", selection: $palette) { ForEach(ChatPalette.allCases) { Text($0.title).tag($0.rawValue) } }.pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("内置背景").font(.subheadline.weight(.medium))
                Picker("内置背景", selection: $wallpaperStyle) { ForEach(WallpaperStyle.allCases) { Text($0.title).tag($0.rawValue) } }.pickerStyle(.segmented)
            }
            PhotosPicker(selection: $wallpaperItem, matching: .images) { Label("从相册选择壁纸", systemImage: "photo") }.font(.subheadline)
            if let wallpaper = space.wallpaper {
                HStack(spacing: 12) {
                    Image(uiImage: wallpaper).resizable().scaledToFill().frame(width: 44, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                    Text("首页和聊天共用这张壁纸").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复") { space.removeImage(wallpaper: true) }.font(.caption)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("壁纸遮罩").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $wallpaperShade, in: 0...0.85).accessibilityLabel("壁纸遮罩")
                    Text("深色模式会自动加深遮罩，保证文字清晰。").font(.caption).foregroundStyle(.secondary)
                    Text("壁纸模糊").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $wallpaperBlur, in: 0...16).accessibilityLabel("壁纸模糊")
                }
            }
            Divider()
            Toggle("轻触反馈", isOn: $haptics)
            if let error = space.imageError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
    private func settingLink(_ title: String, icon: String, route: CompanionRoute) -> some View {
        NavigationLink(value: route) {
            HStack { Label(title, systemImage: icon).font(.subheadline).foregroundStyle(.primary); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 3)
        }.buttonStyle(.plain)
    }
}
