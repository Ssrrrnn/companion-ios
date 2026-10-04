import SwiftUI
import PhotosUI
import UIKit

struct SavedMoment: Codable, Identifiable {
    let id: String
    let text: String
    let role: String
    let savedAt: Date
}
struct LittleNote: Codable, Identifiable {
    var id = UUID()
    var text: String
    var date = Date()
}
struct MoodEntry: Codable, Identifiable {
    var id = UUID()
    var emoji: String
    var note: String
    var date = Date()
}

enum ChatPalette: String, CaseIterable, Identifiable {
    case blue, rose, sage
    var id: String { rawValue }
    var title: String {
        switch self { case .blue: return "信息蓝"; case .rose: return "玫瑰"; case .sage: return "鼠尾草" }
    }
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.04, green: 0.40, blue: 0.91)
        case .rose: return Color(red: 0.64, green: 0.25, blue: 0.39)
        case .sage: return Color(red: 0.24, green: 0.43, blue: 0.36)
        }
    }
}

@MainActor
final class PersonalSpace: ObservableObject {
    @Published private(set) var moments: [SavedMoment] = []
    @Published private(set) var notes: [LittleNote] = []
    @Published private(set) var moods: [MoodEntry] = []
    @Published private(set) var avatar: UIImage?
    @Published private(set) var wallpaper: UIImage?
    @Published var imageError: String?
    private let defaults = UserDefaults.standard
    private var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    init() {
        moments = read("saved_moments_v1") ?? []
        notes = read("little_notes_v1") ?? []
        moods = read("mood_entries_v1") ?? []
        avatar = loadImage("companion-avatar.jpg")
        wallpaper = loadImage("chat-wallpaper.jpg")
    }
    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func save<T: Encodable>(_ value: T, key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
    func isSaved(_ id: String) -> Bool { moments.contains { $0.id == id } }
    func toggleMoment(_ message: Message) {
        if isSaved(message.id) { moments.removeAll { $0.id == message.id } }
        else { moments.insert(SavedMoment(id: message.id, text: message.text, role: message.role, savedAt: .now), at: 0) }
        save(moments, key: "saved_moments_v1")
    }
    func removeMoment(_ id: String) {
        moments.removeAll { $0.id == id }; save(moments, key: "saved_moments_v1")
    }
    func addNote(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        notes.insert(LittleNote(text: String(value.prefix(2000))), at: 0)
        save(notes, key: "little_notes_v1")
    }
    func removeNote(_ id: UUID) {
        notes.removeAll { $0.id == id }; save(notes, key: "little_notes_v1")
    }
    func addMood(_ emoji: String, note: String) {
        let today = Calendar.current.startOfDay(for: .now)
        moods.removeAll { Calendar.current.startOfDay(for: $0.date) == today }
        moods.insert(MoodEntry(emoji: emoji, note: String(note.prefix(500))), at: 0)
        save(moods, key: "mood_entries_v1")
    }
    var todayMood: MoodEntry? { moods.first { Calendar.current.isDateInToday($0.date) } }
    private func loadImage(_ name: String) -> UIImage? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return UIImage(data: data)
    }
    func setImage(_ item: PhotosPickerItem, wallpaper isWallpaper: Bool) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let original = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let maxSide: CGFloat = isWallpaper ? 1800 : 600
            let scale = min(1, maxSide / max(original.size.width, original.size.height))
            let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.systemBackground.setFill(); context.fill(CGRect(origin: .zero, size: size))
                original.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let compressed = rendered.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileWriteUnknown) }
            let url = directory.appendingPathComponent(isWallpaper ? "chat-wallpaper.jpg" : "companion-avatar.jpg")
            try compressed.write(to: url, options: [.atomic, .completeFileProtection])
            if isWallpaper { wallpaper = rendered } else { avatar = rendered }
            imageError = nil
        } catch { imageError = "这张照片没有保存成功，请重新选择。" }
    }
    func removeImage(wallpaper isWallpaper: Bool) {
        let url = directory.appendingPathComponent(isWallpaper ? "chat-wallpaper.jpg" : "companion-avatar.jpg")
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            if isWallpaper { wallpaper = nil } else { avatar = nil }
            imageError = nil
        } catch { imageError = "暂时没能移除照片，请重试。" }
    }
}

struct CompanionAvatar: View {
    @EnvironmentObject private var space: PersonalSpace
    @AppStorage("companion_name") private var name = "他"
    var size: CGFloat = 44
    var body: some View {
        Group {
            if let image = space.avatar { Image(uiImage: image).resizable().scaledToFill() }
            else {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().fill(homeAccent.opacity(0.16)))
                    Text(String(name.prefix(1))).font(.system(size: size * 0.43, weight: .medium, design: .serif)).foregroundStyle(Color.primary)
                }
            }
        }.frame(width: size, height: size).clipShape(Circle()).accessibilityLabel("\(name)的头像")
    }
}

struct RelationshipCard: View {
    @AppStorage("companion_name") private var name = "他"
    @AppStorage("anniversary_enabled") private var anniversaryEnabled = false
    @AppStorage("anniversary_date") private var anniversary = Date.now.timeIntervalSince1970
    @AppStorage("relationship_caption") private var caption = "把日常，留在我们的小家。"
    var body: some View {
        VStack(spacing: 18) {
            CompanionAvatar(size: 96)
            Text(name).font(.title2.weight(.semibold))
            Text(caption).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if anniversaryEnabled {
                let start = Date(timeIntervalSince1970: anniversary)
                let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: start), to: Calendar.current.startOfDay(for: .now)).day ?? 0)
                Text("一起走过 \(days + 1) 天").font(.headline)
                Text(start, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(32).frame(maxWidth: .infinity)
    }
}
