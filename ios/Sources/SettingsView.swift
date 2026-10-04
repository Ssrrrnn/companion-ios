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
    @AppStorage("wallpaper_style") private var wallpaperStyle = "mist"
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
        Form {
            Section {
                HStack(spacing: 18) {
                    CompanionAvatar(size: 62)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("他的名字", text: $name).font(.headline)
                        PhotosPicker("选择头像", selection: $avatarItem, matching: .images).font(.subheadline)
                    }
                }.padding(.vertical, 6)
                TextField("小家的签名", text: $caption, axis: .vertical).lineLimit(1...3)
                if space.avatar != nil { Button("恢复文字头像") { space.removeImage(wallpaper: false) } }
            } header: { Text("我们的小家") }
            Section("我的资料") {
                HStack(spacing: 18) {
                    CompanionAvatar(size: 62, user: true)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("我的名字", text: $userName).font(.headline)
                        PhotosPicker("选择我的头像", selection: $userAvatarItem, matching: .images).font(.subheadline)
                    }
                }.padding(.vertical, 6)
                if space.userAvatar != nil { Button("恢复我的文字头像") { space.removeImage(wallpaper: false, userAvatar: true) } }
            }
            Section("我们的纪念日") {
                Toggle("记住相遇的日子", isOn: $anniversaryEnabled)
                    .onChange(of: anniversaryEnabled) { _, enabled in
                        if enabled && UserDefaults.standard.object(forKey: "anniversary_date") == nil {
                            anniversary = Date.now.timeIntervalSince1970
                        }
                    }
                if anniversaryEnabled {
                    DatePicker("纪念日", selection: Binding(get: { Date(timeIntervalSince1970: anniversary) }, set: { anniversary = $0.timeIntervalSince1970 }), in: ...Date.now, displayedComponents: .date)
                }
            }
            Section {
                Picker("气泡颜色", selection: $palette) {
                    ForEach(ChatPalette.allCases) { item in Text(item.title).tag(item.rawValue) }
                }.pickerStyle(.segmented)
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }
                Picker("内置背景", selection: $wallpaperStyle) {
                    ForEach(WallpaperStyle.allCases) { item in Text(item.title).tag(item.rawValue) }
                }.pickerStyle(.segmented)
                PhotosPicker("从相册更换背景壁纸", selection: $wallpaperItem, matching: .images)
                if space.wallpaper != nil {
                    HStack {
                        Image(uiImage: space.wallpaper!).resizable().scaledToFill().frame(width: 44, height: 60).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
                        Text("首页和聊天共用这张壁纸").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复内置背景") { space.removeImage(wallpaper: true) }
                    }
                }
                if space.wallpaper != nil {
                    VStack(alignment: .leading) {
                        Text("壁纸遮罩").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $wallpaperShade, in: 0...0.65).accessibilityLabel("壁纸遮罩")
                    }
                    VStack(alignment: .leading) {
                        Text("壁纸模糊").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $wallpaperBlur, in: 0...16).accessibilityLabel("壁纸模糊")
                    }
                }
                Toggle("轻触反馈", isOn: $haptics)
                if let error = space.imageError { Text(error).font(.caption).foregroundStyle(.red) }
            } header: { Text("聊天外观") }
              footer: { Text("头像、壁纸、纪念日、小纸条与手动收藏保存在手机里。心情记录进入双方共享日历，供他读取。") }
            Section {
                TextField("HTTPS 服务地址", text: $base).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("连接密钥", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button(connecting ? "正在连接" : "保存并连接") {
                    connecting = true
                    Task { saved = await model.connect(base: base, token: token); connecting = false }
                }.disabled(connecting || model.sending || model.pending != nil)
                if saved { Label("已经连接", systemImage: "checkmark.circle").foregroundStyle(.green) }
                if let error = model.error { Text(error).foregroundStyle(.red) }
            } header: { Text("连接现有伴侣") }
              footer: { Text("填写自己的伴侣服务地址与连接密钥。模型与语音服务密钥由服务端保存。") }
            Section("版本与更新") {
                Text("小家 · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"))")
                Link("查看版本更新", destination: URL(string: "https://github.com/Ssrrrnn/companion-ios/releases")!)
                Text("主动消息继续通过 QQ 或 Telegram 到达，打开小家可以同步查看聊天。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("一起做的事") {
                NavigationLink("一起读书", value: CompanionRoute.books)
                NavigationLink("我们的日历", value: CompanionRoute.calendar)
                NavigationLink("他的日常与自主唤醒", value: CompanionRoute.activity)
                NavigationLink("他的手机权限", value: CompanionRoute.device)
                Text("自主活动在服务器运行；手机定位与日历动作需要小家在前台。通话与酒馆尚未接入。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.scrollContentBackground(.hidden).background { GlassWallpaper() }
            .navigationTitle("设置").toolbarBackground(.hidden, for: .navigationBar)
            .onChange(of: avatarItem) { _, item in if let item { Task { await space.setImage(item, wallpaper: false) } } }
            .onChange(of: userAvatarItem) { _, item in if let item { Task { await space.setImage(item, wallpaper: false, userAvatar: true) } } }
            .onChange(of: wallpaperItem) { _, item in if let item { Task { await space.setImage(item, wallpaper: true) } } }
    }
}
