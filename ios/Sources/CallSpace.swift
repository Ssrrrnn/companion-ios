import SwiftUI
import AVFoundation
import Speech
import Combine

struct CallSegment: Codable, Equatable { let en: String; let zh: String }
struct CallLine: Codable, Identifiable, Equatable {
    let id: UUID
    let role: String
    let segments: [CallSegment]
    let at: Date
    var translation: String { segments.map(\.zh).joined(separator: "\n") }
    var original: String { segments.map(\.en).filter { !$0.isEmpty }.joined(separator: "\n") }
}
struct CallRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let started: Date
    var ended: Date?
    var lines: [CallLine]
    var duration: TimeInterval { max(0, (ended ?? started).timeIntervalSince(started)) }
}
private struct CallStatus: Decodable { let configured: Bool; let voice: String }
private struct CallReply: Decodable { let request_id: String; let segments: [CallSegment] }
private struct CallAudio: Decodable { let audio_base64: String }

extension Notification.Name { static let morrowStopCall = Notification.Name("morrowStopCall") }

@MainActor
final class CallSpace: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var active = false
    @Published private(set) var phase = "等待接通"
    @Published private(set) var heard = ""
    @Published private(set) var lines: [CallLine] = []
    @Published private(set) var records: [CallRecord] = []
    @Published private(set) var caption: CallSegment?
    @Published private(set) var started: Date?
    @Published private(set) var muted = false
    @Published private(set) var speaker = true
    @Published var error: String?
    private let defaults: UserDefaults
    private var api: CompanionAPI?
    private var sessionID = UUID()
    private var generation = UUID()
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var tapInstalled = false
    private var recognitionID = UUID()
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var maximum: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var replyID: String?
    private var replySegments: [CallSegment] = []
    private var replyIndex = 0
    private var previewing = false
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "call_records_v1"), let saved = try? JSONDecoder().decode([CallRecord].self, from: data) { records = Array(saved.prefix(30)) }
        super.init()
        NotificationCenter.default.publisher(for: .morrowStopCall).sink { [weak self] _ in Task { @MainActor in self?.end(deactivateAudio: false) } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] _ in Task { @MainActor in
            guard self?.active == true else { return }; self?.end(); self?.error = "通话被系统声音打断，记录已保留。"
        } }.store(in: &subscriptions)
    }
    func attach(api: CompanionAPI) { if let old = self.api, old != api { end() }; self.api = api }
    func start() {
        guard !active, let api else { error = "先连接小家，再拨给他。"; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") { preview(); return }
        #endif
        error = nil; phase = "正在连接"; active = true; started = .now; sessionID = UUID(); lines = []; heard = ""; caption = nil
        let stamp = generation
        task = Task {
            do {
                let status: CallStatus = try await api.request("v1/call/status", timeout: 15)
                guard status.configured else { throw ConnectionError.server("ElevenLabs 音色尚未配置。") }
                let microphone = await AVAudioApplication.requestRecordPermission()
                let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
                guard active, generation == stamp, !Task.isCancelled else { return }
                guard microphone, speech == .authorized else { throw ConnectionError.server("请在 iPhone 设置里允许 Morrow 使用麦克风和语音识别，然后重拨。") }
                NotificationCenter.default.post(name: .morrowPauseListening, object: nil)
                NotificationCenter.default.post(name: .morrowStopVoice, object: nil)
                await Task.yield()
                guard active, generation == stamp else { return }
                try audioSession()
                task = nil; send("", greeting: true)
            } catch {
                guard generation == stamp else { return }; end(); self.error = error.localizedDescription
            }
        }
    }
    private func audioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: speaker ? [.defaultToSpeaker, .allowBluetooth] : [.allowBluetooth])
        try session.setActive(true)
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
    }
    private func listen() {
        guard active, !muted, !previewing else { phase = muted ? "麦克风已关闭" : "听你说"; return }
        stopRecognition(); heard = ""; phase = "听你说"
        let locale = defaults.string(forKey: "call_input_language") ?? "zh-CN"
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else { error = "语音识别暂不可用，请稍后重拨。"; phase = "等待重试"; return }
        let request = SFSpeechAudioBufferRecognitionRequest(); self.request = request
        request.shouldReportPartialResults = true
        let stamp = generation, recognitionStamp = recognitionID
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.active, self.generation == stamp, self.recognitionID == recognitionStamp, self.phase == "听你说" else { return }
                if let words, !words.isEmpty {
                    if self.heard != words { self.heard = words; self.scheduleSilence(stamp) }
                    if final { self.sendHeard() }
                } else if failure != nil {
                    self.stopRecognition(); self.phase = "等待重试"; self.error = "这次没有听清楚，点“我来说”重新开始。"
                }
            }
        }
        do {
            try audioSession()
            let node = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw ConnectionError.server("麦克风暂不可用。") }
            node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true; engine.prepare(); try engine.start()
            maximum = Task { try? await Task.sleep(for: .seconds(50)); guard !Task.isCancelled, generation == stamp else { return }; if heard.isEmpty { listen() } else { sendHeard() } }
        } catch { stopRecognition(); phase = "等待重试"; self.error = error.localizedDescription }
    }
    private func scheduleSilence(_ stamp: UUID) {
        silence?.cancel()
        silence = Task { try? await Task.sleep(for: .milliseconds(1600)); guard !Task.isCancelled, generation == stamp else { return }; sendHeard() }
    }
    func sendHeard() { let text = String(heard.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines); guard active, !text.isEmpty else { return }; send(text, greeting: false) }
    private func stopRecognition() {
        recognitionID = UUID()
        silence?.cancel(); silence = nil; maximum?.cancel(); maximum = nil
        engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio(); request = nil; recognition?.cancel(); recognition = nil
    }
    private func send(_ text: String, greeting: Bool) {
        guard active, let api else { return }
        stopRecognition(); heard = ""; task?.cancel(); phase = "他正在想"; error = nil
        if !greeting { lines.append(CallLine(id: UUID(), role: "user", segments: [CallSegment(en: "", zh: text)], at: .now)); persistCurrent() }
        let stamp = generation, requestID = UUID().uuidString, session = sessionID.uuidString
        task = Task {
            do {
                let body = try JSONSerialization.data(withJSONObject: ["request_id": requestID, "session_id": session, "text": text, "greeting": greeting])
                let reply: CallReply = try await api.request("v1/call/turn", body: body, timeout: 90)
                guard active, generation == stamp, !Task.isCancelled else { return }
                guard !reply.segments.isEmpty else { throw ConnectionError.server("通话字幕没有返回。") }
                lines.append(CallLine(id: UUID(), role: "assistant", segments: reply.segments, at: .now)); persistCurrent()
                replyID = reply.request_id; replySegments = reply.segments; replyIndex = 0; task = nil; playSegment()
            } catch {
                guard generation == stamp, active, !Task.isCancelled else { return }; phase = "等待重试"; self.error = error.localizedDescription
            }
        }
    }
    private func playSegment() {
        guard active, let api, let replyID, replySegments.indices.contains(replyIndex) else { listen(); return }
        let stamp = generation, index = replyIndex
        caption = replySegments[index]; phase = "正在准备声音"
        task = Task {
            do {
                let audio: CallAudio = try await api.request("v1/call/audio", body: JSONSerialization.data(withJSONObject: ["request_id": replyID, "segment": index]), timeout: 55)
                guard active, generation == stamp, !Task.isCancelled else { return }
                guard let data = Data(base64Encoded: audio.audio_base64), !data.isEmpty, data.count <= 3_000_000 else { throw ConnectionError.server("这段声音没有完整返回。") }
                try audioSession(); let player = try AVAudioPlayer(data: data); player.delegate = self; self.player = player
                guard player.play() else { throw ConnectionError.server("声音没有开始播放，请重试。") }; phase = "他正在说"; task = nil
            } catch {
                guard generation == stamp, active, !Task.isCancelled else { return }; phase = "声音暂不可用"; self.error = error.localizedDescription
            }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.active, self.player === player else { return }
            self.player = nil
            guard flag else { self.phase = "声音暂不可用"; self.error = "声音播放中断，点“重播这句”再试。"; return }
            self.replyIndex += 1; self.playSegment()
        }
    }
    func retryAudio() { guard active, !previewing else { return }; error = nil; player?.stop(); player = nil; task?.cancel(); playSegment() }
    func interrupt() {
        guard active, !previewing else { return }; generation = UUID(); task?.cancel(); task = nil; player?.stop(); player = nil; error = nil; listen()
    }
    func toggleMute() { muted.toggle(); if muted { stopRecognition(); if phase == "听你说" { phase = "麦克风已关闭" } } else if phase == "麦克风已关闭" || phase == "等待重试" { listen() } }
    func toggleSpeaker() { speaker.toggle(); if active { do { try audioSession() } catch { self.error = "声音输出没有切换成功。" } } }
    func end(deactivateAudio: Bool = true) {
        guard active else { return }; generation = UUID(); task?.cancel(); task = nil; stopRecognition(); player?.stop(); player = nil
        active = false; phase = "通话已结束"; heard = ""; muted = false
        if let started, !lines.isEmpty { save(CallRecord(id: sessionID, started: started, ended: .now, lines: Array(lines.suffix(100)))) }
        if deactivateAudio { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func persistCurrent() { if let started { save(CallRecord(id: sessionID, started: started, ended: nil, lines: Array(lines.suffix(100)))) } }
    private func save(_ record: CallRecord) {
        records.removeAll { $0.id == record.id }; records.insert(record, at: 0); records = Array(records.prefix(30)); persist()
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(records), forKey: "call_records_v1") }
    func remove(_ id: UUID) { guard !active || id != sessionID else { return }; records.removeAll { $0.id == id }; persist() }
    #if DEBUG
    func preview() {
        previewing = true; active = true; started = .now; phase = "他正在说"
        let segment = CallSegment(en: "I'm here. Tell me how your day has been.", zh: "我在呢。跟我说说，今天过得怎么样？")
        caption = segment; lines = [CallLine(id: UUID(), role: "user", segments: [CallSegment(en: "", zh: "今天有点累，想听听你的声音。")], at: .now), CallLine(id: UUID(), role: "assistant", segments: [segment], at: .now)]
    }
    #endif
}
