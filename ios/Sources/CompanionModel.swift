import SwiftUI
import AVFoundation
import CryptoKit

@MainActor
final class CompanionModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var favorites: [Keepsake] = []
    @Published var diaries: [Keepsake] = []
    @Published var pending: PendingMessage?
    @Published var sending = false
    @Published var error: String?
    @Published var connected = false
    @Published var playingID: String?
    @Published var playbackProgress: Double = 0
    @Published var playbackPaused = false
    @Published private(set) var voiceDurations: [String: Double] = [:]
    @Published var refreshing = false
    private var conversationGeneration = 0
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private let pendingKey = "pending_message_v1"
    private let voicesKey = "voice_durations_v1"
    private var voiceFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Voices", isDirectory: true)
    }
    var api: CompanionAPI {
        CompanionAPI(base: UserDefaults.standard.string(forKey: "server_url") ?? "", token: ConnectionKey.read())
    }
    #if DEBUG
    var isPreview = false
    #endif
    init() {
        if let data = UserDefaults.standard.data(forKey: pendingKey) {
            pending = try? JSONDecoder().decode(PendingMessage.self, from: data)
        }
        voiceDurations = UserDefaults.standard.dictionary(forKey: voicesKey) as? [String: Double] ?? [:]
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
            messages = result.messages
            connected = true
        } catch is CancellationError { }
        catch { if generation == conversationGeneration { connected = false } }
    }
    func connect(base: String, token: String) async -> Bool {
        do {
            let connection = CompanionAPI(base: base.trimmingCharacters(in: .whitespacesAndNewlines),
                                          token: token.trimmingCharacters(in: .whitespacesAndNewlines))
            let result: History = try await connection.request("v1/history")
            try ConnectionKey.save(connection.token)
            UserDefaults.standard.set(connection.base, forKey: "server_url")
            conversationGeneration += 1
            messages = result.messages
            connected = true
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
            connected = true
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
        do {
            async let saved: Collection = api.request("v1/favorites")
            async let diary: Collection = api.request("v1/diaries")
            let result = try await (saved, diary)
            favorites = result.0.items
            diaries = result.1.items
        } catch { self.error = error.localizedDescription }
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
    func hasAudio(_ id: String) -> Bool { voiceDurations[id] != nil && FileManager.default.fileExists(atPath: voiceURL(id).path) }
    func play(_ id: String) {
        if playingID == id, let player {
            if playbackPaused { player.play(); playbackPaused = false }
            else { player.pause(); playbackPaused = true }
            return
        }
        stopAudio()
        do {
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
        player?.stop(); player = nil; playingID = nil; playbackProgress = 0; playbackPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
