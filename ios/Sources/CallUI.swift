import SwiftUI

struct CallHomeCard: View {
    @AppStorage("companion_name") private var name = "他"
    var body: some View {
        NavigationLink(value: CompanionRoute.call) {
            HStack(spacing: 16) {
                Image(systemName: "phone.fill").font(.title3).frame(width: 50, height: 50).background(homeAccent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text("想听听\(name)的声音").font(.subheadline.weight(.semibold))
                    Text("你说中文 · 他答英文 · 随时打断").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(); Image(systemName: "arrow.up.right").font(.caption)
            }.foregroundStyle(homeAccent).padding(20).glassSurface(in: RoundedRectangle(cornerRadius: 24))
        }.buttonStyle(.plain).accessibilityIdentifier("home-call")
    }
}

struct CompanionCallView: View {
    @EnvironmentObject private var call: CallSpace
    @EnvironmentObject private var model: CompanionModel
    @AppStorage("companion_name") private var name = "他"
    @State private var history = false
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Text("A little closer.").font(MorrowType.script(37)).foregroundStyle(homeAccent)
                    CompanionAvatar(size: 86).padding(8).background(homeAccent.opacity(0.07), in: Circle())
                    Text(name).font(.system(.title2, design: .serif))
                    HStack(spacing: 8) {
                        Circle().fill(call.active ? homeAccent : .secondary).frame(width: 6, height: 6)
                        Text(call.phase)
                        if call.active, let started = call.started { Text(started, style: .timer).monospacedDigit() }
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 8)
                if let caption = call.caption {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("他说", systemImage: "waveform").font(.caption).foregroundStyle(homeAccent)
                        Text(caption.zh).font(.title3.weight(.medium)).lineSpacing(6).accessibilityIdentifier("call-caption-zh")
                        Text(caption.en).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4).accessibilityIdentifier("call-caption-en")
                    }.padding(23).frame(maxWidth: .infinity, alignment: .leading).glassSurface(in: RoundedRectangle(cornerRadius: 27))
                } else {
                    Text("不用想好再开口。\n让他听听你今天的声音。").font(.title3).multilineTextAlignment(.center).lineSpacing(7).foregroundStyle(.secondary).padding(.vertical, 20)
                }
                if !call.heard.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("正在听你说").font(.caption).foregroundStyle(.secondary); Text(call.heard).font(.body); Button("说完了，发送") { call.sendHeard() }.font(.caption) }.frame(maxWidth: .infinity, alignment: .leading) }
                if let error = call.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(error).font(.footnote).foregroundStyle(.red)
                        if call.active { Text("可以直接继续说中文，也可以点“我来说”。").font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if call.active {
                    HStack(alignment: .top, spacing: 16) {
                        control(call.muted ? "开启麦克风" : "静音", icon: call.muted ? "mic.slash.fill" : "mic.fill") { call.toggleMute() }
                        control(call.speaker ? "扬声器" : "听筒", icon: call.speaker ? "speaker.wave.2.fill" : "ear") { call.toggleSpeaker() }
                        control("我来说", icon: "hand.raised") { call.interrupt() }
                        VStack(spacing: 8) {
                            Button { call.end() } label: { Image(systemName: "phone.down.fill").font(.title3).foregroundStyle(.white).frame(width: 58, height: 58).background(Color(red: 0.72, green: 0.25, blue: 0.30), in: Circle()) }.accessibilityIdentifier("call-end")
                            Text("挂断").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Button { call.attach(api: model.api); call.start() } label: { Label("拨给\(name)", systemImage: "phone.fill").frame(maxWidth: .infinity).padding(12) }.buttonStyle(.borderedProminent).disabled(!model.connected).accessibilityIdentifier("call-start")
                    Label("你说中文，他用英语回答", systemImage: "waveform").font(.subheadline).foregroundStyle(homeAccent)
                    Text("保持麦克风开启，说完会自动接话；他说话时你也可以直接开口打断。使用 ElevenLabs 的伴侣音色，中文翻译为主，保留英文原文。内容只显示在通话页面和通话记录里，同一通电话会记住前面聊过的话。").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                }
                if !call.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("这一通，慢慢记下来").font(.subheadline.weight(.semibold)).foregroundStyle(homeAccent)
                        ForEach(call.lines.suffix(12)) { CallTranscriptRow(line: $0, name: name) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(24).frame(maxWidth: 620)
        }.background(homePaper).navigationTitle("语音通话").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { history = true } label: { Image(systemName: "clock.arrow.circlepath") }.accessibilityLabel("通话记录") } }
            .sheet(isPresented: $history) { NavigationStack { CallHistoryView() } }
            .onDisappear { call.end() }
    }
    private func control(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 8) { Button(action: action) { Image(systemName: icon).font(.title3).frame(width: 58, height: 58).background(homeAccent.opacity(0.1), in: Circle()) }.accessibilityLabel(title); Text(title).font(.caption2).foregroundStyle(.secondary) }
    }
}

struct CallTranscriptRow: View {
    let line: CallLine
    let name: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(line.role == "user" ? "我" : name); Spacer(); Text(line.at, format: .dateTime.hour().minute()) }.font(.caption).foregroundStyle(.secondary)
            Text(line.translation).font(.body).lineSpacing(5)
            if !line.original.isEmpty { Text(line.original).font(.caption).foregroundStyle(.secondary).lineSpacing(3) }
            if line.interrupted == true { Text("这句被打断了").font(.caption2).foregroundStyle(.secondary) }
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading).glassSurface(in: RoundedRectangle(cornerRadius: 20)).textSelection(.enabled)
    }
}

struct CallHistoryView: View {
    @EnvironmentObject private var call: CallSpace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("companion_name") private var name = "他"
    var body: some View {
        List {
            if call.records.isEmpty { ContentUnavailableView("还没有通话记录", systemImage: "phone", description: Text("说过的话，都会留在这里。")) }
            ForEach(call.records) { record in
                NavigationLink {
                    ScrollView { LazyVStack(spacing: 14) { ForEach(record.lines) { CallTranscriptRow(line: $0, name: name) } }.padding(20) }.background(homePaper).navigationTitle("那天的声音")
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(record.started, format: .dateTime.month().day().hour().minute()).font(.subheadline.weight(.medium))
                        Text(record.lines.last?.translation ?? "语音通话").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(record.ended == nil ? "通话中或未正常结束" : "\(Int(record.duration / 60))分\(Int(record.duration) % 60)秒 · \(record.lines.count)段记录").font(.caption2).foregroundStyle(homeAccent)
                    }
                }.swipeActions { Button("删除", role: .destructive) { call.remove(record.id) } }
            }
        }.navigationTitle("通话记录").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
