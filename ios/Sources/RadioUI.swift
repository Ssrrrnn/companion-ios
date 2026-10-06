import SwiftUI

struct RadioHomeCard: View {
    @EnvironmentObject private var radio: RadioSpace
    var body: some View {
        NavigationLink(value: CompanionRoute.radio) {
            HStack(spacing: 16) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(homeAccent)
                    .frame(width: 54, height: 60).background(homeAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text("他的电台").font(.headline).foregroundStyle(.primary)
                    Text(radio.preparing ? "正在准备声音…" : radio.current?.title ?? "留一段声音，陪你过今晚。")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).accessibilityIdentifier("home-radio")
    }
}

struct RadioView: View {
    @EnvironmentObject private var radio: RadioSpace
    @EnvironmentObject private var listening: ListeningSpace
    @EnvironmentObject private var model: CompanionModel
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("radio_opening") private var opening = true
    @State private var composer = false
    private var playing: Bool { listening.current?.kind == "radio" && listening.playing }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                station
                if let error = radio.error ?? (listening.current?.kind == "radio" ? listening.error : nil) { Label(error, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("radio-error") }
                if let current = radio.current {
                    SettingsCard(title: "\(current.title)", icon: "text.quote") {
                        if radio.preparing {
                            ProgressView(value: Double(radio.prepared), total: Double(max(1, radio.parts.count)))
                            Text("正在准备第 \(min(radio.prepared + 1, radio.parts.count)) / \(radio.parts.count) 段声音，准备好后开始播放。").font(.caption).foregroundStyle(.secondary)
                            Button("取消准备") { radio.stop() }
                        } else {
                            HStack {
                                Text(radio.completed ? "这一期听完了" : "第 \(radio.index + 1) / \(max(1, radio.parts.count)) 段").font(.caption).foregroundStyle(homeAccent)
                                Spacer()
                                Text(current.source).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(radio.transcript).font(.body).lineSpacing(8).textSelection(.enabled).accessibilityIdentifier("radio-transcript")
                            if listening.current?.kind == "radio" {
                                Slider(value: Binding(get: { listening.position }, set: { listening.seek($0) }), in: 0...max(1, listening.duration)).disabled(listening.duration <= 0).accessibilityLabel("电台播放进度")
                                HStack { Text(clock(listening.position)); Spacer(); Text(clock(listening.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 34) {
                                Spacer()
                                Button { radio.move(-1) } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("电台上一段")
                                Button { radio.toggle() } label: { Image(systemName: playing ? "pause.fill" : "play.fill").font(.title2).frame(width: 64, height: 64).background(homeAccent.opacity(0.15), in: Circle()) }.accessibilityLabel(playing ? "暂停电台" : "播放电台")
                                Button { radio.advance() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("电台下一段")
                                Spacer()
                            }.disabled(radio.prepared == 0)
                            if radio.prepared == 0 { Button("重新准备这期") { radio.prepare(current, host: name, opening: opening) } }
                        }
                    }
                }
                SettingsCard(title: "今晚怎么听", icon: "moon.stars") {
                    Toggle("电台开场与结束语", isOn: $opening).font(.subheadline)
                    HStack {
                        Label("睡眠定时", systemImage: "moon.zzz").font(.subheadline)
                        Spacer()
                        Menu {
                            ForEach([0, 10, 20, 30, 60], id: \.self) { minutes in Button(minutes == 0 ? "关闭定时" : "\(minutes) 分钟后停止") { radio.setSleep(minutes: minutes) } }
                        } label: { Text(radio.sleepMinutes == 0 ? "未开启" : "\(radio.sleepMinutes) 分钟").font(.subheadline); Image(systemName: "chevron.down").font(.caption) }
                    }
                    if radio.sleepMinutes > 0 && radio.sleepUntil == nil { Text("声音准备好，开始播放后计时。").font(.caption).foregroundStyle(.secondary) }
                    if let until = radio.sleepUntil { Text("\(until.formatted(date: .omitted, time: .shortened)) 停止播放").font(.caption).foregroundStyle(.secondary) }
                }
                HStack { Text("节目架").font(.headline); Spacer(); Button { composer = true } label: { Label("新一期", systemImage: "plus") }.font(.subheadline).accessibilityIdentifier("radio-new-program") }
                if radio.programs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("今天，想听我读什么？").font(.system(.title3, design: .serif))
                        Text("选一篇日记、一张小纸条，或书里读到的几页。也可以把你喜欢的文字放进来。").font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
                        Button("准备第一期") { composer = true }.buttonStyle(.borderedProminent)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                }
                ForEach(radio.programs) { program in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(program.source, systemImage: "waveform").font(.caption).foregroundStyle(homeAccent)
                            Spacer()
                            Menu { Button("删除节目", role: .destructive) { radio.remove(program) }; ShareLink(item: program.text) { Label("分享文字", systemImage: "square.and.arrow.up") } } label: { Image(systemName: "ellipsis").frame(width: 40, height: 32) }.accessibilityLabel("节目选项")
                        }
                        Text(program.title).font(.system(.title3, design: .serif)).foregroundStyle(.primary)
                        Text(program.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(3).lineSpacing(4)
                        HStack {
                            Text(program.tone == "night" ? "夜间轻声" : "自然朗读").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { radio.prepare(program, host: name, opening: opening) } label: { Label("听这一期", systemImage: "play.fill").font(.subheadline.weight(.medium)) }.accessibilityIdentifier("radio-listen-" + program.id.uuidString)
                        }
                    }.padding(20).glassSurface(in: RoundedRectangle(cornerRadius: 24))
                }
                Text("使用他现有的 AI 音色朗读。节目文字保存在本机；点开始后，正文会交给小家的语音服务生成。声音准备好后支持后台收听。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).frame(maxWidth: 720).frame(maxWidth: .infinity)
        }.background { GlassWallpaper() }.navigationTitle("他的电台").navigationBarTitleDisplayMode(.inline)
            .onAppear { radio.attach(listening, api: model.api) }
            .sheet(isPresented: $composer) { NavigationStack { RadioComposer() } }
    }
    private var station: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("MORROW · PRIVATE RADIO").font(.system(size: 10, weight: .semibold)).tracking(2); Spacer(); Image(systemName: "dot.radiowaves.left.and.right") }.foregroundStyle(homeAccent)
            Text("今晚，\n把声音留给你。").font(MorrowType.editorial(35)).lineSpacing(4)
            HStack { CompanionAvatar(size: 38); VStack(alignment: .leading, spacing: 4) { Text("\(name)的独享电台").font(.subheadline.weight(.medium)); Text(playing ? "正在朗读" : "日记 · 故事 · 书里的句子").font(.caption).foregroundStyle(.secondary) }; Spacer() }
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<38, id: \.self) { index in RoundedRectangle(cornerRadius: 3).fill(homeAccent.opacity(playing ? 0.75 : 0.35)).frame(maxWidth: .infinity).frame(height: CGFloat(12 + abs(sin(Double(index) * 0.8)) * 34)) }
            }.frame(height: 50).accessibilityHidden(true)
        }.padding(26).glassSurface(in: RoundedRectangle(cornerRadius: 30), tint: homeAccent)
    }
    private func clock(_ value: Double) -> String { let seconds = Int(value.isFinite ? max(0, value) : 0); return String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

struct RadioComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var radio: RadioSpace
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var library: ReadingLibrary
    @EnvironmentObject private var space: PersonalSpace
    @EnvironmentObject private var shared: SharedSpace
    @State private var title = ""
    @State private var text = ""
    @State private var source = "我的选文"
    @State private var tone = "night"
    @State private var chooser = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SettingsCard(title: "这期读什么", icon: "text.book.closed") {
                    TextField("节目标题", text: $title).font(.headline).accessibilityIdentifier("radio-title")
                    Divider()
                    TextEditor(text: $text).frame(minHeight: 210).scrollContentBackground(.hidden).accessibilityIdentifier("radio-text")
                    HStack { Button { chooser = true } label: { Label("从小家选内容", systemImage: "square.stack") }; Spacer(); Text("\(text.unicodeScalars.count) / 6000 字").font(.caption.monospacedDigit()).foregroundStyle(text.unicodeScalars.count > RadioScript.limit ? .red : .secondary) }.font(.subheadline)
                }
                SettingsCard(title: "朗读风格", icon: "waveform") {
                    Picker("朗读风格", selection: $tone) { Text("夜间轻声").tag("night"); Text("自然朗读").tag("natural") }.pickerStyle(.segmented)
                    Text("保留他的音色，用段落和标点安排停顿。夜间轻声在支持语气控制的语音服务上生效。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }
                if let error = error ?? radio.error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("收好这一期") {
                    if radio.save(title: title, text: text, source: source, tone: tone) != nil { dismiss() }
                }.buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.unicodeScalars.count > RadioScript.limit).accessibilityIdentifier("radio-save")
                Text("先保存节目，确认文字后再开始朗读。每期最多 6000 字，长内容可以分期。").font(.caption).foregroundStyle(.secondary)
            }.padding(22)
        }.scrollDismissesKeyboard(.interactively).background { GlassWallpaper() }.navigationTitle("准备一期电台").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完成输入") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
            .sheet(isPresented: $chooser) { sources }
    }
    private var sources: some View {
        NavigationStack {
            List {
                Section("他的日记") {
                    if model.diaries.isEmpty { Text("还没有已同步的日记").foregroundStyle(.secondary) }
                    ForEach(model.diaries) { diary in Button { choose(title: diary.text.components(separatedBy: .newlines).first ?? "日记", text: diary.text, source: "他的日记") } label: { Text(diary.text).lineLimit(3).foregroundStyle(.primary) } }
                }
                Section("我们的纸条") {
                    ForEach(shared.entries.filter { $0.kind == "note" }.reversed()) { note in Button { choose(title: note.title.isEmpty ? "留给你的纸条" : note.title, text: note.text, source: "小纸条") } label: { Text(note.text).lineLimit(3).foregroundStyle(.primary) } }
                    ForEach(space.notes) { note in Button { choose(title: "一张小纸条", text: note.text, source: "小纸条") } label: { Text(note.text).lineLimit(3).foregroundStyle(.primary) } }
                }
                Section("一起读的书 · 当前页起最多三页") {
                    ForEach(library.books) { book in
                        Button {
                            chooser = false
                            Task {
                                do {
                                    let excerpt = try await Task.detached(priority: .userInitiated) { try (book.page..<min(book.page + 3, book.pageCount)).map { try ReadingDisk.loadPage(book.id, page: $0) }.joined(separator: "\n\n") }.value
                                    choose(title: "\(book.title) · 第\(book.page + 1)页起", text: excerpt, source: "书籍片段")
                                } catch { self.error = "这几页没有读到文字，请重新打开书籍后再试。" }
                            }
                        } label: { VStack(alignment: .leading, spacing: 5) { Text(book.title); Text("从第 \(book.page + 1) 页开始").font(.caption).foregroundStyle(.secondary) }.foregroundStyle(.primary) }
                    }
                }
                Section("我收藏的句子") {
                    ForEach(space.moments) { moment in Button { choose(title: "收藏的一句话", text: moment.text, source: "我的收藏") } label: { Text(moment.text).lineLimit(3).foregroundStyle(.primary) } }
                }
            }.navigationTitle("选一段给我读").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { chooser = false } } }
                .task { await model.loadKeepsakes(kind: "diaries") }
        }
    }
    private func choose(title: String, text: String, source: String) { self.title = String(title.prefix(80)); self.text = text; self.source = source; chooser = false; error = nil }
}
