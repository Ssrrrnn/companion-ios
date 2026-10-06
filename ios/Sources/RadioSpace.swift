import SwiftUI
import Combine

struct RadioProgram: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let text: String
    let source: String
    let tone: String
    let createdAt: Date
}

enum RadioScript {
    static let limit = 6000
    static func parts(text: String, title: String, host: String, opening: Bool) -> [String] {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.unicodeScalars.count <= limit else { return [] }
        var result: [String] = []
        if opening {
            let name = String(host.prefix(40)), title = String(title.prefix(80))
            result.append("这里是\(name)的电台。今晚，想陪你读一段《\(title)》。你可以把手里的事情放一放，也可以继续忙，我慢慢读，你慢慢听。")
        }
        var part = "", count = 0
        for scalar in body.unicodeScalars {
            part.unicodeScalars.append(scalar); count += 1
            if count >= 380 || (count >= 220 && "。！？!?\n".unicodeScalars.contains(scalar)) {
                if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(part) }
                part = ""; count = 0
            }
        }
        if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(part) }
        if opening { result.append("今天就先读到这里。这些话留在我们的小家，你想听的时候，我再陪你读。") }
        return result
    }
}
private struct RadioAudio: Decodable { let audio_base64: String; let text: String; let voice: String }

@MainActor
final class RadioSpace: ObservableObject {
    @Published private(set) var programs: [RadioProgram] = []
    @Published private(set) var current: RadioProgram?
    @Published private(set) var parts: [String] = []
    @Published private(set) var index = 0
    @Published private(set) var prepared = 0
    @Published private(set) var preparing = false
    @Published private(set) var sleepUntil: Date?
    @Published private(set) var sleepMinutes = 0
    @Published private(set) var completed = false
    @Published var error: String?
    private let defaults: UserDefaults
    private let folder: URL
    private var api: CompanionAPI?
    private weak var listening: ListeningSpace?
    private var task: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = UUID()
    private var files: [URL] = []
    private var listeners = Set<AnyCancellable>()
    var transcript: String { parts.indices.contains(index) ? parts[index] : "" }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowRadio-" + UUID().uuidString, isDirectory: true)
        if let data = defaults.data(forKey: "radio_programs_v1"), let saved = try? JSONDecoder().decode([RadioProgram].self, from: data) { programs = Array(saved.prefix(30)) }
        NotificationCenter.default.publisher(for: .morrowStopRadio).sink { [weak self] _ in Task { @MainActor in self?.stop() } }.store(in: &listeners)
        NotificationCenter.default.publisher(for: .morrowPauseListening).sink { [weak self] _ in Task { @MainActor in
            // Chat voice also cancels preparation so it cannot start later over the reply.
            if self?.preparing == true { self?.stop() }
        } }.store(in: &listeners)
    }
    func attach(_ listening: ListeningSpace, api: CompanionAPI) {
        if let existing = self.api, existing != api { stop() }
        self.listening = listening; self.api = api
        listening.radioFinished = { [weak self] in self?.advance() }
        listening.radioNext = { [weak self] in self?.advance() }
        listening.radioPrevious = { [weak self] in self?.move(-1) }
        listening.radioToggle = { [weak self] in self?.toggle() }
    }
    @discardableResult func save(title: String, text: String, source: String, tone: String) -> RadioProgram? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= RadioScript.limit else { error = "每期最多 6000 字，长文章可以分成几期。"; return nil }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let program = RadioProgram(id: UUID(), title: String((cleanTitle.isEmpty ? "想读给你听" : cleanTitle).prefix(80)), text: text, source: source, tone: tone == "natural" ? "natural" : "night", createdAt: .now)
        programs.insert(program, at: 0); programs = Array(programs.prefix(30)); persist(); error = nil
        return program
    }
    func remove(_ program: RadioProgram) {
        if current?.id == program.id { stop(); current = nil; parts = [] }
        programs.removeAll { $0.id == program.id }; persist()
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(programs), forKey: "radio_programs_v1") }
    func prepare(_ program: RadioProgram, host: String, opening: Bool) {
        let preferredSleep = sleepMinutes
        stop(); sleepMinutes = preferredSleep; current = program; completed = false; index = 0
        parts = RadioScript.parts(text: program.text, title: program.title, host: host, opening: opening)
        guard !parts.isEmpty, let api, let listening else { error = "先连接小家，再开始电台。"; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") { error = "预览不会生成或播放真实声音"; return }
        #endif
        listening.prepareForRadio(); NotificationCenter.default.post(name: .morrowStopVoice, object: nil)
        preparing = true; prepared = 0; error = nil
        let stamp = generation, script = parts
        task = Task {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (number, text) in script.enumerated() {
                    try Task.checkCancellation()
                    let body = try JSONSerialization.data(withJSONObject: ["text": text, "tone": program.tone])
                    let reply: RadioAudio = try await api.request("v1/radio/speech", body: body, timeout: 65)
                    guard stamp == generation else { return }
                    guard let data = Data(base64Encoded: reply.audio_base64), !data.isEmpty, data.count <= 3_000_000 else { throw ConnectionError.server("电台音频没有完整返回，请重试。") }
                    let url = folder.appendingPathComponent("\(stamp)-\(number).mp3")
                    // Keep generated local audio available while the device is locked.
                    try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    files.append(url); prepared = files.count
                }
                guard stamp == generation else { return }
                preparing = false; task = nil; setSleep(minutes: sleepMinutes); playPart()
            } catch {
                guard stamp == generation else { return }
                preparing = false; task = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    private func playPart() {
        guard let current, files.indices.contains(index) else { return }
        if let deadline = sleepUntil, deadline <= .now { stop(); return }
        completed = false
        listening?.playRadio(title: "\(current.title) · \(index + 1)/\(parts.count)", programID: current.id, part: index, url: files[index])
    }
    func advance() {
        guard !preparing, !files.isEmpty else { return }
        if index + 1 < files.count { index += 1; playPart() }
        else { listening?.pause(); completed = true; setSleep(minutes: 0) }
    }
    func move(_ delta: Int) {
        guard !preparing, !files.isEmpty else { return }
        index = max(0, min(files.count - 1, index + delta)); playPart()
    }
    func toggle() {
        guard !preparing, !files.isEmpty else { return }
        if listening?.current?.kind != "radio" { playPart() }
        else if completed { index = 0; playPart() }
        else if listening?.playing == true { listening?.pause() }
        else { listening?.resume() }
    }
    func setSleep(minutes: Int) {
        timer?.cancel(); timer = nil; sleepMinutes = max(0, minutes); sleepUntil = nil
        guard minutes > 0, !files.isEmpty, !preparing else { sleepUntil = nil; return }
        let deadline = Date.now.addingTimeInterval(Double(minutes * 60)); sleepUntil = deadline
        timer = Task {
            do { try await Task.sleep(for: .seconds(minutes * 60)) } catch { return }
            guard sleepUntil == deadline else { return }
            stop()
        }
    }
    #if DEBUG
    func preview() {
        let program = RadioProgram(id: UUID(uuidString: "A3111111-1111-1111-1111-111111111111")!, title: "窗外的灯亮起来", text: "窗外的灯一盏盏亮起来，桌上还摊着没读完的书。有人把书向旁边推了推，留出另一个人的位置。有时候，陪伴不是赶到结尾，而是愿意停在同一句话里。", source: "书里的句子", tone: "night", createdAt: .now)
        programs = [program]; current = program
        parts = RadioScript.parts(text: program.text, title: program.title, host: "他", opening: false)
        index = 0; prepared = 0; error = nil
    }
    #endif
    func stop() {
        generation = UUID(); task?.cancel(); task = nil; preparing = false
        timer?.cancel(); timer = nil; sleepUntil = nil; sleepMinutes = 0
        listening?.stopRadio()
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []; prepared = 0
    }
}
