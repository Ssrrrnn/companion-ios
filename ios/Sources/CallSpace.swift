import SwiftUI
import AVFoundation
import Speech
import Combine

struct CallSegment: Codable, Equatable { let en: String; let zh: String }
struct CallLine: Codable, Identifiable, Equatable {
    let id: UUID
    let role: String
    var segments: [CallSegment]
    let at: Date
    var interrupted: Bool? = nil
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
private struct CallStatus: Decodable { let configured: Bool; let realtime: Bool? }
struct CallEvent: Decodable {
    let type: String
    var request_id: String?
    var segment: Int?
    var en: String?
    var zh: String?
    var audio_base64: String?
    var message: String?
    var complete: Bool?
    var sample_rate: Int?
}

enum CallPCM {
    static func samples(_ data: Data) -> [Float]? {
        guard !data.isEmpty, data.count % 2 == 0, data.count <= 16384 else { return nil }
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Float(Int16(bitPattern: UInt16(bytes[$0]) | (UInt16(bytes[$0 + 1]) << 8))) / 32768
        }
    }
}

// The audio tap runs off the main actor. It owns no UI or mutable CallSpace state.
private final class CallMicrophoneFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = value; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); let value = request; lock.unlock(); value?.append(buffer) }
}

extension Notification.Name { static let morrowStopCall = Notification.Name("morrowStopCall") }

@MainActor
final class CallSpace: NSObject, ObservableObject {
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
    private let player = AVAudioPlayerNode()
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
    private let microphone = CallMicrophoneFeed()
    private var recognition: SFSpeechRecognitionTask?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var tapInstalled = false
    private var recognitionID = UUID()
    private var recognitionFailures = 0
    private var socket: URLSessionWebSocketTask?
    private var task: Task<Void, Never>?
    private var receiver: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var silence: Task<Void, Never>?
    private var maximum: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var replyID: String?
    private var segments: [Int: CallSegment] = [:]
    private var audioSegments = Set<Int>()
    private var pendingBuffers = 0
    private var networkDone = false
    private var previewing = false
    private var playbackID = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "call_records_v1"), let saved = try? JSONDecoder().decode([CallRecord].self, from: data) { records = Array(saved.prefix(30)) }
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
        NotificationCenter.default.publisher(for: .morrowStopCall).sink { [weak self] _ in Task { @MainActor in self?.end(deactivateAudio: false) } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] _ in Task { @MainActor in
            guard self?.active == true else { return }; self?.end(); self?.error = "通话被系统声音打断，记录已保留。"
        } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: AVAudioEngine.configurationChangeNotification, object: engine).sink { [weak self] _ in Task { @MainActor in
            guard let self, self.active, !self.previewing, self.socket != nil, !self.engine.isRunning else { return }
            self.end(); self.error = "音频设备发生变化，通话记录已保留，请重拨。"
        } }.store(in: &subscriptions)
    }
    func attach(api: CompanionAPI) { if let old = self.api, old != api { end() }; self.api = api }
    func start() {
        guard !active, let api else { error = "先连接小家，再拨给他。"; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") { preview(); return }
        #endif
        generation = UUID(); error = nil; phase = "正在连接"; active = true; started = .now
        sessionID = UUID(); lines = []; heard = ""; caption = nil; recognitionFailures = 0
        let stamp = generation
        task = Task {
            do {
                let status: CallStatus = try await api.request("v1/call/status", timeout: 15)
                guard status.configured else { throw ConnectionError.server("ElevenLabs 音色尚未配置。") }
                guard status.realtime == true else { throw ConnectionError.server("实时通话服务尚未更新，请稍后重拨。") }
                let permission = await AVAudioApplication.requestRecordPermission()
                let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
                guard active, generation == stamp, !Task.isCancelled else { return }
                guard permission, speech == .authorized else { throw ConnectionError.server("请在 iPhone 设置里允许 Morrow 使用麦克风和语音识别，然后重拨。") }
                NotificationCenter.default.post(name: .morrowPauseListening, object: nil)
                NotificationCenter.default.post(name: .morrowStopVoice, object: nil)
                await Task.yield()
                guard active, generation == stamp else { return }
                try audioSession()
                // Use the same engine for microphone and playback so Apple's voice
                // processing receives the actual speaker reference for echo cancellation.
                try engine.inputNode.setVoiceProcessingEnabled(true)
                engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
                let format = engine.inputNode.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw ConnectionError.server("麦克风暂不可用。") }
                let feed = microphone
                engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
                tapInstalled = true; engine.prepare(); try engine.start()
                let connection = try api.callSocket()
                socket = connection; connection.resume(); task = nil
                receiver = Task { [weak self] in guard let self else { return }; await self.receive(connection, stamp: stamp) }
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(20)) } catch { return }
                        guard let self, self.active, self.generation == stamp else { return }
                        self.sendEvent(["type": "ping"])
                    }
                }
            } catch {
                guard generation == stamp, !Task.isCancelled else { return }; end(); self.error = error.localizedDescription
            }
        }
    }
    private func audioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: speaker ? [.defaultToSpeaker, .allowBluetooth] : [.allowBluetooth])
        try session.setActive(true)
        try session.overrideOutputAudioPort(speaker ? .speaker : .none)
    }
    private func receive(_ connection: URLSessionWebSocketTask, stamp: UUID) async {
        do {
            while active, generation == stamp, !Task.isCancelled {
                let message = try await connection.receive()
                guard active, generation == stamp, !Task.isCancelled else { return }
                let data: Data
                switch message { case .string(let value): data = Data(value.utf8); case .data(let value): data = value; @unknown default: continue }
                guard data.count <= 100_000 else { throw ConnectionError.server("通话数据不完整，请重拨。") }
                try handle(JSONDecoder().decode(CallEvent.self, from: data))
            }
        } catch {
            guard active, generation == stamp, !Task.isCancelled else { return }
            end(); self.error = "通话连接断开了，记录已保留。请重新拨给他。"
        }
    }
    private func sendEvent(_ body: [String: Any]) {
        guard let connection = socket, active, let data = try? JSONSerialization.data(withJSONObject: body), let text = String(data: data, encoding: .utf8) else { return }
        let preceding = sender, stamp = generation
        sender = Task { [weak self] in
            await preceding?.value
            guard let self, self.active, self.generation == stamp, !Task.isCancelled else { return }
            do { try await connection.send(.string(text)) }
            catch { guard self.active, self.generation == stamp, !Task.isCancelled else { return }; self.end(); self.error = "通话连接断开了，请重拨。" }
        }
    }
    private func listen() {
        guard active, !muted, !previewing else { return }
        stopRecognition(); heard = ""
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else { error = "中文语音识别暂不可用，请稍后重拨。"; return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.taskHint = .dictation
        speechRequest = request; microphone.set(request)
        let stamp = generation, recognitionStamp = recognitionID
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
            let words = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self, self.active, !self.muted, self.generation == stamp, self.recognitionID == recognitionStamp else { return }
                if let words, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.recognitionFailures = 0
                    if self.heard != words {
                        // Recognized speech from the echo-cancelled microphone, not
                        // raw ambient loudness, triggers barge-in even during generation.
                        if self.replyID != nil { self.stopReply(notify: true) }
                        self.heard = words; self.phase = "听你说"; self.scheduleSilence(stamp)
                    }
                    if final { self.sendHeard() }
                } else if final || failure != nil {
                    self.recognitionFailures += 1
                    self.stopRecognition()
                    if self.recognitionFailures >= 3 {
                        self.error = "中文语音识别暂时中断，点“我来说”重试。"
                    } else {
                        self.maximum = Task {
                            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                            guard self.active, self.generation == stamp, !self.muted else { return }
                            self.listen()
                        }
                    }
                }
            }
        }
        maximum = Task {
            do { try await Task.sleep(for: .seconds(50)) } catch { return }
            guard active, generation == stamp, recognitionID == recognitionStamp else { return }
            if heard.isEmpty { listen() } else { sendHeard() }
        }
    }
    private func scheduleSilence(_ stamp: UUID) {
        silence?.cancel()
        silence = Task { do { try await Task.sleep(for: .milliseconds(1000)) } catch { return }; guard active, generation == stamp, !Task.isCancelled else { return }; sendHeard() }
    }
    func sendHeard() {
        let text = String(heard.prefix(1500)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !muted, !text.isEmpty else { return }
        send(text, greeting: false)
    }
    private func stopRecognition() {
        recognitionID = UUID(); silence?.cancel(); silence = nil; maximum?.cancel(); maximum = nil
        microphone.set(nil); speechRequest?.endAudio(); speechRequest = nil; recognition?.cancel(); recognition = nil
    }
    private func send(_ text: String, greeting: Bool) {
        guard active, socket != nil else { return }
        if replyID != nil { stopReply(notify: true) }
        heard = ""; error = nil; phase = "他在听，也在想"
        if !greeting { lines.append(CallLine(id: UUID(), role: "user", segments: [CallSegment(en: "", zh: text)], at: .now)); persistCurrent() }
        let id = UUID().uuidString
        replyID = id; networkDone = false; segments = [:]; audioSegments = []; pendingBuffers = 0; playbackID = UUID()
        sendEvent(["type": "turn", "request_id": id, "session_id": sessionID.uuidString, "text": text, "greeting": greeting])
        listen() // Always listen, including while the companion generates and speaks.
    }
    private func handle(_ event: CallEvent) throws {
        if event.type == "ready" {
            guard event.sample_rate == 24000 else { throw ConnectionError.server("通话声音格式不匹配。") }
            send("", greeting: true); return
        }
        guard let id = event.request_id, id == replyID else { return } // Discard late output after interruption.
        switch event.type {
        case "thinking": phase = "他在听，也在想"
        case "caption":
            guard let index = event.segment, index >= 0, index < 3, let en = event.en, let zh = event.zh, !en.isEmpty, !zh.isEmpty, en.count <= 450, zh.count <= 600 else { throw ConnectionError.server("字幕不完整。") }
            segments[index] = CallSegment(en: en, zh: zh)
            if pendingBuffers == 0 { caption = segments[index] }
        case "audio":
            guard let index = event.segment, let segment = segments[index], let encoded = event.audio_base64, let data = Data(base64Encoded: encoded), let samples = CallPCM.samples(data) else { throw ConnectionError.server("通话声音不完整。") }
            if audioSegments.insert(index).inserted {
                recordSegment(segment, id: id)
                if pendingBuffers == 0 { caption = segment }
            }
            try enqueue(samples, id: id)
        case "audio_end":
            guard let index = event.segment else { return }
            if audioSegments.contains(index) { try enqueueMarker(id: id, index: index, complete: event.complete == true) }
        case "audio_error":
            error = event.message
            if let index = event.segment, let segment = segments[index], !audioSegments.contains(index) { recordSegment(segment, id: id); if pendingBuffers == 0 { caption = segment } }
        case "done": networkDone = true; finishPlaybackIfReady()
        case "error":
            stopReply(notify: false); error = event.message ?? "这句没有接上，可以继续说。"; phase = muted ? "麦克风已关闭" : "听你说"
        default: break
        }
    }
    private func enqueue(_ samples: [Float], id: String) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] else { throw ConnectionError.server("声音缓冲区不可用。") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, value) in samples.enumerated() { channel[index] = value }
        let stamp = playbackID
        pendingBuffers += 1
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, self.replyID == id, self.playbackID == stamp else { return }
                self.pendingBuffers = max(0, self.pendingBuffers - 1); self.finishPlaybackIfReady()
            }
        }
        if !player.isPlaying { player.play() }
        phase = "他正在说 · 你可以直接打断"
    }
    private func enqueueMarker(id: String, index: Int, complete: Bool) throws {
        guard let marker = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1) else { throw ConnectionError.server("声音缓冲区不可用。") }
        marker.frameLength = 1; marker.floatChannelData?[0][0] = 0
        let stamp = playbackID
        pendingBuffers += 1
        player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active, self.replyID == id, self.playbackID == stamp else { return }
                if complete { self.sendEvent(["type": "played", "request_id": id, "segment": index]) }
                if let next = self.segments[index + 1] { self.caption = next }
                self.pendingBuffers = max(0, self.pendingBuffers - 1); self.finishPlaybackIfReady()
            }
        }
    }
    private func finishPlaybackIfReady() {
        guard networkDone, pendingBuffers == 0 else { return }
        replyID = nil; phase = muted ? "麦克风已关闭" : "听你说"
    }
    private func recordSegment(_ segment: CallSegment, id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        if let index = lines.firstIndex(where: { $0.id == uuid }) { lines[index].segments.append(segment) }
        else { lines.append(CallLine(id: uuid, role: "assistant", segments: [segment], at: .now)) }
        persistCurrent()
    }
    private func stopReply(notify: Bool) {
        if let id = replyID {
            if notify { sendEvent(["type": "interrupt", "request_id": id]) }
            if let index = lines.firstIndex(where: { $0.id.uuidString == id }) { lines[index].interrupted = true }
        }
        replyID = nil; playbackID = UUID(); player.stop(); pendingBuffers = 0; networkDone = false; segments = [:]; audioSegments = []
        persistCurrent()
    }
    func retryAudio() { interrupt() }
    func interrupt() { guard active, !previewing else { return }; stopReply(notify: true); error = nil; recognitionFailures = 0; phase = muted ? "麦克风已关闭" : "听你说"; listen() }
    func toggleMute() {
        muted.toggle()
        if muted { stopRecognition(); heard = ""; if replyID == nil { phase = "麦克风已关闭" } }
        else { listen(); if replyID == nil { phase = "听你说" } }
    }
    func toggleSpeaker() { speaker.toggle(); if active { do { try audioSession() } catch { self.error = "声音输出没有切换成功。" } } }
    func end(deactivateAudio: Bool = true) {
        guard active else { return }
        stopReply(notify: false); active = false; generation = UUID()
        task?.cancel(); task = nil; receiver?.cancel(); receiver = nil; heartbeat?.cancel(); heartbeat = nil; sender?.cancel(); sender = nil
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        stopRecognition(); engine.stop(); if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        phase = "通话已结束"; heard = ""; muted = false
        if let started, !lines.isEmpty { save(CallRecord(id: sessionID, started: started, ended: .now, lines: Array(lines.suffix(100)))) }
        if deactivateAudio { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func persistCurrent() { if let started, !lines.isEmpty { save(CallRecord(id: sessionID, started: started, ended: nil, lines: Array(lines.suffix(100)))) } }
    private func save(_ record: CallRecord) { records.removeAll { $0.id == record.id }; records.insert(record, at: 0); records = Array(records.prefix(30)); persist() }
    private func persist() { defaults.set(try? JSONEncoder().encode(records), forKey: "call_records_v1") }
    func remove(_ id: UUID) { guard !active || id != sessionID else { return }; records.removeAll { $0.id == id }; persist() }
    #if DEBUG
    func preview() {
        previewing = true; active = true; started = .now; phase = "他正在说 · 你可以直接打断"
        let segment = CallSegment(en: "I'm here. Tell me how your day has been.", zh: "我在呢。跟我说说，今天过得怎么样？")
        caption = segment; lines = [CallLine(id: UUID(), role: "user", segments: [CallSegment(en: "", zh: "今天有点累，想听听你的声音。")], at: .now), CallLine(id: UUID(), role: "assistant", segments: [segment], at: .now)]
    }
    #endif
}
