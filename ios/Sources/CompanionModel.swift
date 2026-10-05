import SwiftUI
import AVFoundation
import CryptoKit

@MainActor
final class AudioProgress: ObservableObject {
    @Published var value: Double = 0
}

@MainActor
final class CompanionModel: ObservableObject {
    @Published var messages: [Message] = [] {
        didSet { if messages != oldValue { chatRows = presentation.update(messages) } }
    }
    private var presentation = ChatPresentationCache()
    private(set) var chatRows: [ChatRow] = []
    @Published var favorites: [Keepsake] = []
    @Published var diaries: [Keepsake] = []
    @Published var memories: [Keepsake] = []
    @Published private(set) var keepsakeLoading = Set<String>()
    @Published private(set) var keepsakeErrors: [String: String] = [:]
    @Published private(set) var keepsakeMore = Set<String>()
    private var keepsakeCursors: [String: String] = [:]
    @Published var pending: PendingMessage?
    @Published var sending = false
    @Published var error: String?
    @Published var connected = false
    @Published var playingID: String?
    let audioProgress = AudioProgress()
    var playbackProgress: Double {
        get { audioProgress.value }
        set { audioProgress.value = newValue }
    }
    @Published var playbackPaused = false
    @Published private(set) var voiceDurations: [String: Double] = [:]
    private var refreshing = false
    private var conversationGeneration = 0
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private let pendingKey = "pending_message_v1"
    private let voicesKey = "voice_durations_v1"
    private var voiceFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Voices", isDirectory: true)
    }
    private(set) var api = CompanionAPI(base: UserDefaults.standard.string(forKey: "server_url") ?? "", token: ConnectionKey.read())
    #if DEBUG
    var isPreview = false
    #endif
    init() {
        if let data = UserDefaults.standard.data(forKey: pendingKey) {
            pending = try? JSONDecoder().decode(PendingMessage.self, from: data)
        }
        voiceDurations = UserDefaults.standard.dictionary(forKey: voicesKey) as? [String: Double] ?? [:]
        for kind in ["diaries", "favorites", "memories"] {
            if let data = UserDefaults.standard.data(forKey: "keepsake_" + kind + "_v1"), let page = try? JSONDecoder().decode(Collection.self, from: data) {
                setKeepsakes(page.items, kind: kind)
                if page.has_more == true { keepsakeMore.insert(kind) }
                keepsakeCursors[kind] = page.next_before
            }
        }
    }
    func refresh() async {
        #if DEBUG
        guard !isPreview else { return }
        #endif
        guard !sending, !refreshing else { return }
        refreshing = true
        let generation = conversationGeneration
        defer { refreshing = false }
        do {
            let result: History = try await api.request("v1/history")
            // A send can start while this GET is in flight. Do not overwrite its reply.
            guard generation == conversationGeneration, !sending, pending == nil else { return }
            if messages != result.messages { messages = result.messages }
            if !connected { connected = true }
        } catch is CancellationError { }
        catch { if generation == conversationGeneration && connected { connected = false } }
    }
    func connect(base: String, token: String) async -> Bool {
        do {
            let connection = CompanionAPI(base: base.trimmingCharacters(in: .whitespacesAndNewlines),
                                          token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let result: History = try await connection.request("v1/history")
            try ConnectionKey.save(connection.token)
            UserDefaults.standard.set(connection.base, forKey: "server_url")
            if api.base != connection.base || api.token != connection.token {
                for kind in ["diaries", "favorites", "memories"] { setKeepsakes([], kind: kind); UserDefaults.standard.removeObject(forKey: "keepsake_" + kind + "_v1") }
                keepsakeCursors = [:]; keepsakeMore = []; keepsakeErrors = [:]
            }
            api = connection
            conversationGeneration += 1
            messages = result.messages
            if !connected { connected = true }
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// The composer clears its draft only after a request has been durably queued.
    func queue(_ text: String) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending == nil, !sending, connected, !content.isEmpty, content.count <= 4000 else { return false }
        let request = PendingMessage(id: UUID(), text: content, sentAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(request) else { return false }
        UserDefaults.standard.set(data, forKey: pendingKey)
        conversationGeneration += 1
        pending = request
        return true
    }
    func retry() async {
        #if DEBUG
        // UI fixtures must never send synthetic messages to a real service.
        guard !isPreview else { return }
        #endif
        guard let request = pending, !sending else { return }
        sending = true
        error = nil
        do {
            let result = try await api.send(request)
            let assistantID = result.assistant_id ?? request.id.uuidString + ":assistant"
            if let encoded = result.replies.first(where: { $0.type == "record" })?.audio_base64,
               let data = Data(base64Encoded: encoded) { retainVoice(data, id: assistantID) }
            let answer = result.replies.compactMap { $0.text ?? $0.fallback_text }.joined(separator: "\n")
            let userID = result.assistant_id.map { String($0.dropLast(":assistant".count)) + ":user" } ?? request.id.uuidString + ":user"
            if !messages.contains(where: { $0.id == userID }) {
                messages.append(Message(id: userID, role: "user", text: request.text))
            }
            if !answer.isEmpty, !messages.contains(where: { $0.id == assistantID }) {
                messages.append(Message(id: assistantID, role: "assistant", text: answer))
            }
            pending = nil
            UserDefaults.standard.removeObject(forKey: pendingKey)
            if !connected { connected = true }
        } catch { self.error = error.localizedDescription }
        sending = false
        // The response above is already visible; do not immediately replace it with an older history snapshot.
    }
    func discardPending() {
        guard !sending else { return }
        pending = nil
        UserDefaults.standard.removeObject(forKey: pendingKey)
        error = nil
    }
    func loadKeepsakes() async {
        #if DEBUG
        guard !isPreview else { return }
        #endif
        await withTaskGroup(of: Void.self) { group in
            for kind in ["diaries", "favorites", "memories"] { group.addTask { await self.loadKeepsakes(kind: kind) } }
        }
    }
    private func setKeepsakes(_ items: [Keepsake], kind: String) {
        switch kind { case "diaries": diaries = items; case "favorites": favorites = items; case "memories": memories = items; default: break }
    }
    func keepsakes(_ kind: String) -> [Keepsake] {
        switch kind { case "diaries": return diaries; case "favorites": return favorites; case "memories": return memories; default: return [] }
    }
    func loadKeepsakes(kind: String, more: Bool = false) async {
        #if DEBUG
        guard !isPreview else { return }
        #endif
        guard ["diaries", "favorites", "memories"].contains(kind), !keepsakeLoading.contains(kind), !more || keepsakeCursors[kind] != nil else { return }
        keepsakeLoading.insert(kind); keepsakeErrors[kind] = nil
        defer { keepsakeLoading.remove(kind) }
        let connection = api
        do {
            let cursor = more ? "&before=" + (keepsakeCursors[kind] ?? "") : ""
            let page: Collection = try await connection.request("v1/\(kind)?limit=50\(cursor)", timeout: 20)
            guard api.base == connection.base, api.token == connection.token else { return }
            let previous = more ? keepsakes(kind) : []
            var ids = Set<String>()
            let items = (previous + page.items).filter { ids.insert($0.id).inserted }
            setKeepsakes(items, kind: kind)
            let progressed = !more || items.count > previous.count
            if page.has_more == true, let cursor = page.next_before, !cursor.isEmpty, cursor.count <= 19, cursor.utf8.allSatisfy({ (48...57).contains($0) }), progressed {
                keepsakeMore.insert(kind); keepsakeCursors[kind] = cursor
            } else { keepsakeMore.remove(kind); keepsakeCursors[kind] = nil }
            UserDefaults.standard.set(try JSONEncoder().encode(Collection(items: items, has_more: keepsakeMore.contains(kind), next_before: keepsakeCursors[kind])), forKey: "keepsake_" + kind + "_v1")
        } catch { keepsakeErrors[kind] = "暂未取得新的内容，下面保留最近同步的珍藏。" }
    }
    private func voiceURL(_ id: String) -> URL {
        let hash = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return voiceFolder.appendingPathComponent(hash + ".mp3")
    }
    private func retainVoice(_ data: Data, id: String) {
        do {
            let duration = try AVAudioPlayer(data: data).duration
            try FileManager.default.createDirectory(at: voiceFolder, withIntermediateDirectories: true)
            try data.write(to: voiceURL(id), options: [.atomic, .completeFileProtection])
            voiceDurations[id] = duration
            UserDefaults.standard.set(voiceDurations, forKey: voicesKey)
        } catch { self.error = "文字已收到，但这条语音未能保存。" }
    }
    // Files are validated when actually played, not during every bubble render.
    func hasAudio(_ id: String) -> Bool { voiceDurations[id] != nil }
    func play(_ id: String) {
        if playingID == id, let player {
            if playbackPaused { player.play(); playbackPaused = false }
            else { player.pause(); playbackPaused = true }
            return
        }
        stopAudio()
        do {
            NotificationCenter.default.post(name: .morrowPauseListening, object: nil)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let audio = try AVAudioPlayer(contentsOf: voiceURL(id))
            guard audio.play() else { throw CocoaError(.fileReadUnknown) }
            player = audio; playingID = id; playbackProgress = 0; playbackPaused = false
            playbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, let player = self.player, self.playingID == id else { return }
                    if !player.isPlaying && !self.playbackPaused { self.stopAudio(); return }
                    self.playbackProgress = player.duration > 0 ? player.currentTime / player.duration : 0
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                }
            }
        } catch { stopAudio(); self.error = "这条语音暂时无法播放。" }
    }
    func stopAudio() {
        playbackTask?.cancel(); playbackTask = nil
        let hadPlayer = player != nil
        player?.stop(); player = nil; playingID = nil; playbackProgress = 0; playbackPaused = false
        if hadPlayer { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
}
