import SwiftUI
import UIKit

struct QuotedText {
    let quote: String?
    let author: String?
    let body: String
    init(_ text: String) {
        if text.hasPrefix("[回复「"), let titleEnd = text.range(of: "」]\n"),
           let quoteEnd = text.range(of: "\n[/回复]\n", range: titleEnd.upperBound..<text.endIndex) {
            author = String(text[text.index(text.startIndex, offsetBy: 4)..<titleEnd.lowerBound])
            quote = String(text[titleEnd.upperBound..<quoteEnd.lowerBound])
            body = String(text[quoteEnd.upperBound...])
        } else { quote = nil; author = nil; body = text }
    }
    static func compose(_ draft: String, replyingTo message: Message?, name: String) -> String {
        guard let message else { return draft }
        let author = message.role == "user" ? "我" : name.replacingOccurrences(of: "\n", with: " ")
        let excerpt = String(QuotedText(message.text).body.prefix(400)).replacingOccurrences(of: "[/回复]", with: "")
        return "[回复「\(author)」]\n\(excerpt)\n[/回复]\n\(draft)"
    }
}

struct MessageBubbleShape: Shape {
    var outgoing: Bool
    var tail: Bool
    func path(in rect: CGRect) -> Path {
        let radius = min(CGFloat(20), rect.height / 2)
        let bodyWidth = rect.width - (tail ? 7 : 0)
        let height = rect.height
        // A single outline avoids overlapping subpaths cutting holes in the fill.
        var path = Path()
        path.move(to: CGPoint(x: radius, y: 0))
        path.addLine(to: CGPoint(x: bodyWidth - radius, y: 0))
        path.addQuadCurve(to: CGPoint(x: bodyWidth, y: radius), control: CGPoint(x: bodyWidth, y: 0))
        path.addLine(to: CGPoint(x: bodyWidth, y: height - radius))
        if tail {
            path.addCurve(to: CGPoint(x: rect.width, y: height),
                          control1: CGPoint(x: bodyWidth, y: height - 5),
                          control2: CGPoint(x: rect.width - 7, y: height - 1))
            path.addCurve(to: CGPoint(x: bodyWidth - 15, y: height - 5),
                          control1: CGPoint(x: rect.width - 10, y: height),
                          control2: CGPoint(x: bodyWidth - 10, y: height - 2))
            path.addQuadCurve(to: CGPoint(x: bodyWidth - 28, y: height),
                              control: CGPoint(x: bodyWidth - 20, y: height))
        } else {
            path.addQuadCurve(to: CGPoint(x: bodyWidth - radius, y: height),
                              control: CGPoint(x: bodyWidth, y: height))
        }
        path.addLine(to: CGPoint(x: radius, y: height))
        path.addQuadCurve(to: CGPoint(x: 0, y: height - radius), control: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: radius))
        path.addQuadCurve(to: CGPoint(x: radius, y: 0), control: CGPoint(x: 0, y: 0))
        path.closeSubpath()
        return outgoing ? path : path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.width, ty: 0))
    }
}

struct ChatView: View {
    @EnvironmentObject private var model: CompanionModel
    @EnvironmentObject private var space: PersonalSpace
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("chat_palette") private var paletteName = "blue"
    @AppStorage("chat_draft_v1") private var draft = ""
    @AppStorage("chat_haptics") private var haptics = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selection: Int
    @FocusState private var focused: Bool
    @State private var replyingTo: Message?
    @State private var profile = false
    @State private var searching = false
    @State private var query = ""
    @State private var scrollTarget: String?
    @State private var nearBottom = true
    @State private var unseen = false
    @State private var width: CGFloat = 390
    private var palette: ChatPalette { ChatPalette(rawValue: paletteName) ?? .blue }
    private var composed: String { QuotedText.compose(draft, replyingTo: replyingTo, name: name) }
    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && composed.count <= 4000 && model.pending == nil && !model.sending && model.connected
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Text("我们的聊天").font(.caption2.weight(.semibold)).foregroundStyle(Color(uiColor: .secondaryLabel)).padding(.vertical, 22)
                    if model.messages.isEmpty && model.pending == nil {
                        VStack(spacing: 14) {
                            CompanionAvatar(size: 72)
                            Text(model.connected ? "想说的话，慢慢说。" : "先把我们的小家连接起来。")
                                .font(.title3.weight(.medium))
                            Text(model.connected ? "这里延续你们已有的聊天和记忆。" : "在设置里填写服务地址与连接密钥。")
                                .font(.subheadline).foregroundStyle(Color(uiColor: .secondaryLabel))
                            if !model.connected { Button("去设置") { selection = 3 }.buttonStyle(.bordered) }
                        }.padding(.vertical, 50).frame(maxWidth: .infinity)
                    }
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        let tail = index == model.messages.count - 1 || model.messages[index + 1].role != message.role
                        let gap: CGFloat = index == 0 || model.messages[index - 1].role != message.role ? 11 : 3
                        bubble(message, tail: tail).padding(.top, gap).id(message.id)
                    }
                    if let pending = model.pending {
                        bubble(Message(id: pending.id.uuidString, role: "user", text: pending.text), tail: true)
                            .padding(.top, 12)
                        HStack {
                            Spacer()
                            if model.sending { Text("发送中").foregroundStyle(Color(uiColor: .secondaryLabel)) }
                            else {
                                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                                Button("重试") { Task { await model.retry() } }
                                Button("保留为草稿") {
                                    draft = [QuotedText(pending.text).body, draft].filter { !$0.isEmpty }.joined(separator: "\n")
                                    model.discardPending()
                                }
                            }
                        }.font(.caption).padding(.top, 5)
                        if model.sending {
                            HStack {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.mini)
                                    Text("正在回复").font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel))
                                }.padding(14).background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                                Spacer()
                            }.padding(.top, 16).accessibilityLabel("正在等待回复")
                        }
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).padding(.top, 12) }
                    Color.clear.frame(height: 16).id("bottom")
                }.padding(.horizontal, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 100
            } action: { _, value in
                nearBottom = value
                if value { unseen = false }
            }
            .background { chatBackground }
            .overlay(alignment: .bottom) {
                if unseen {
                    Button {
                        jumpToBottom(proxy); unseen = false
                    } label: {
                        Label("新消息", systemImage: "arrow.down").font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                    }.padding(.bottom, 12)
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.messages.last?.id) { _, _ in
                if nearBottom { jumpToBottom(proxy) } else { unseen = true }
            }
            .onChange(of: model.pending?.id) { _, value in if value != nil { jumpToBottom(proxy) } }
            .onChange(of: focused) { _, value in if value && nearBottom { jumpToBottom(proxy) } }
            .onChange(of: scrollTarget) { _, value in
                if let value { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(value, anchor: .center) } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { focused = false; selection = 0 } label: { Image(systemName: "chevron.left").font(.title3.weight(.medium)) }
                    .accessibilityLabel("回到小家")
            }
            ToolbarItem(placement: .principal) {
                Button { focused = false; profile = true } label: {
                    HStack(spacing: 8) {
                        CompanionAvatar(size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                            Text(model.sending ? "正在回复" : model.connected ? "已连接" : "尚未连接")
                                .font(.caption2).foregroundStyle(Color(uiColor: .secondaryLabel))
                        }
                        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                }.accessibilityLabel("查看\(name)的资料")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { focused = false; searching = true } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索聊天")
            }
        }
        .sheet(isPresented: $profile) {
            NavigationStack {
                RelationshipCard().navigationTitle("我们").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("完成") { profile = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("编辑") { profile = false; selection = 3 } }
                    }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $searching) { searchSheet }
    }
    private func jumpToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
    }
    @ViewBuilder private var chatBackground: some View {
        if let image = space.wallpaper {
            GeometryReader { geometry in
                Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay(Color(uiColor: .systemBackground).opacity(colorScheme == .dark ? 0.60 : 0.78))
            }.ignoresSafeArea()
        } else { Color(uiColor: .systemBackground).ignoresSafeArea() }
    }
    private func bubble(_ message: Message, tail: Bool) -> some View {
        let outgoing = message.role == "user"
        let content = QuotedText(message.text)
        return HStack(alignment: .bottom, spacing: 0) {
            if outgoing { Spacer(minLength: 45) }
            VStack(alignment: .leading, spacing: 9) {
                if let quote = content.quote {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.author ?? name).font(.caption.weight(.semibold))
                        Text(quote).font(.caption).lineLimit(3)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(outgoing ? Color.white.opacity(0.15) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                if model.hasAudio(message.id) { audioBar(message.id, outgoing: outgoing) }
                Text(content.body).font(.body).lineSpacing(3)
                if space.isSaved(message.id) { Image(systemName: "heart.fill").font(.caption2).opacity(0.8).accessibilityLabel("已收藏") }
            }
            .padding(.vertical, 10).padding(.leading, outgoing ? 14 : (tail ? 21 : 14)).padding(.trailing, outgoing && tail ? 21 : 14)
            .foregroundStyle(outgoing ? Color.white : Color.primary)
            .background(outgoing ? palette.color : Color(uiColor: .secondarySystemBackground), in: MessageBubbleShape(outgoing: outgoing, tail: tail))
            .frame(maxWidth: min(520, width * 0.78), alignment: outgoing ? .trailing : .leading)
            .contextMenu {
                Button { replyingTo = message; focused = true } label: { Label("回复这句", systemImage: "arrowshape.turn.up.left") }
                Button { UIPasteboard.general.string = content.body } label: { Label("复制", systemImage: "doc.on.doc") }
                Button { space.toggleMoment(message); feedback() } label: { Label(space.isSaved(message.id) ? "取消收藏" : "收藏这句", systemImage: space.isSaved(message.id) ? "heart.slash" : "heart") }
                ShareLink(item: content.body) { Label("分享", systemImage: "square.and.arrow.up") }
            }
            if !outgoing { Spacer(minLength: 45) }
        }
    }
    private func audioBar(_ id: String, outgoing: Bool) -> some View {
        Button { model.play(id); feedback() } label: {
            HStack(spacing: 10) {
                Image(systemName: model.playingID == id && !model.playbackPaused ? "pause.fill" : "play.fill").font(.body)
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: "waveform").font(.title3)
                    ProgressView(value: model.playingID == id ? model.playbackProgress : 0)
                        .tint(outgoing ? .white : palette.color).frame(width: 94)
                }
                Text(duration(model.voiceDurations[id] ?? 0)).font(.caption.monospacedDigit())
            }.padding(.vertical, 4)
        }.buttonStyle(.plain).accessibilityLabel(model.playingID == id && !model.playbackPaused ? "暂停语音" : "播放语音")
    }
    private func duration(_ seconds: Double) -> String { let value = max(0, Int(seconds.rounded())); return String(format: "%d:%02d", value / 60, value % 60) }
    private func feedback() { if haptics { UISelectionFeedbackGenerator().selectionChanged() } }
    private var composer: some View {
        VStack(spacing: 8) {
            if let reply = replyingTo {
                HStack(spacing: 12) {
                    Capsule().fill(palette.color).frame(width: 3)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("回复 \(reply.role == "user" ? "我" : name)").font(.caption.weight(.semibold)).foregroundStyle(palette.color)
                        Text(QuotedText(reply.text).body).font(.caption).foregroundStyle(Color(uiColor: .secondaryLabel)).lineLimit(2)
                    }
                    Spacer()
                    Button { replyingTo = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color(uiColor: .secondaryLabel)) }.accessibilityLabel("取消引用")
                }.frame(maxHeight: 58).padding(.horizontal, 16).padding(.top, 9)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button { focused = false; searching = true } label: { Label("搜索聊天", systemImage: "magnifyingglass") }
                    Button { focused = false; selection = 2 } label: { Label("收藏与日记", systemImage: "heart.text.square") }
                    Button { focused = false; selection = 3 } label: { Label("头像与聊天外观", systemImage: "paintpalette") }
                    Button { Task { await model.refresh() } } label: { Label("同步聊天", systemImage: "arrow.clockwise") }
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 29)).foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(width: 38, height: 44)
                }.accessibilityLabel("更多聊天功能")
                HStack(alignment: .bottom, spacing: 6) {
                    TextField("信息", text: $draft, axis: .vertical).lineLimit(1...5).focused($focused)
                        .padding(.vertical, 10).padding(.leading, 14).font(.body)
                    Button {
                        let text = composed
                        guard model.queue(text) else { return }
                        draft = ""; replyingTo = nil; feedback()
                        Task { await model.retry() }
                    } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 29, height: 29).background(canSend ? palette.color : Color(uiColor: .tertiaryLabel), in: Circle())
                    }.disabled(!canSend).padding(.trailing, 5).padding(.bottom, 5).accessibilityLabel("发送信息")
                }.background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 23))
                    .overlay(RoundedRectangle(cornerRadius: 23).strokeBorder(Color(uiColor: .separator).opacity(0.6), lineWidth: 0.5))
            }.padding(.horizontal, 9).padding(.bottom, 8).padding(.top, replyingTo == nil ? 8 : 0)
            if composed.count > 3800 { Text("\(composed.count) / 4000 字").font(.caption2).foregroundStyle(composed.count > 4000 ? .red : .secondary).padding(.bottom, 4) }
        }.background(.bar)
    }
    private var searchSheet: some View {
        NavigationStack {
            List {
                Section {
                    let results = model.messages.filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
                    if results.isEmpty { ContentUnavailableView.search(text: query) }
                    ForEach(results) { message in
                        Button {
                            scrollTarget = nil; searching = false
                            Task { try? await Task.sleep(for: .milliseconds(250)); scrollTarget = message.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.role == "user" ? "我" : name).font(.caption.weight(.semibold)).foregroundStyle(palette.color)
                                Text(QuotedText(message.text).body).font(.body).foregroundStyle(Color.primary).lineLimit(4)
                            }.padding(.vertical, 6)
                        }.accessibilityIdentifier("chat-search-result-\(message.id)")
                    }
                } footer: { Text("搜索最近同步到小家的聊天。") }
            }.searchable(text: $query, prompt: "找一句话")
                .navigationTitle("聊天记录").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { searching = false } } }
        }
    }
}
