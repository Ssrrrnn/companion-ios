import SwiftUI

let moodInk = Color(red: 0.19, green: 0.25, blue: 0.31)
struct MoodChoice { let emoji: String; let title: String; let color: Color }
enum MoodStyle {
    static let choices = [
        MoodChoice(emoji: "😊", title: "开心", color: Color(red: 1, green: 0.76, blue: 0.54)),
        MoodChoice(emoji: "😌", title: "平静", color: Color(red: 0.68, green: 0.79, blue: 0.58)),
        MoodChoice(emoji: "😴", title: "疲惫", color: Color(red: 0.78, green: 0.72, blue: 0.65)),
        MoodChoice(emoji: "😔", title: "难过", color: Color(red: 0.62, green: 0.80, blue: 0.89)),
        MoodChoice(emoji: "😟", title: "焦虑", color: Color(red: 0.68, green: 0.69, blue: 0.82)),
        MoodChoice(emoji: "😤", title: "生气", color: Color(red: 0.91, green: 0.55, blue: 0.48)),
        MoodChoice(emoji: "🥺", title: "想你", color: Color(red: 0.92, green: 0.67, blue: 0.74)),
        MoodChoice(emoji: "🥰", title: "幸福", color: Color(red: 0.94, green: 0.78, blue: 0.47))
    ]
    static func label(_ emoji: String) -> String { choices.first { $0.emoji == emoji }?.title ?? "心情" }
    static func color(_ emoji: String?) -> Color { choices.first { $0.emoji == emoji }?.color ?? Color.gray.opacity(0.28) }
    static func latestPerDay(_ entries: [SharedEntry], actor: String) -> [SharedEntry] {
        var days: [String: SharedEntry] = [:]
        for entry in entries where entry.actor == actor && entry.kind == "mood" { days[entry.day] = entry }
        return days.values.sorted { $0.day < $1.day }
    }
}
struct MoodBadge: View {
    let emoji: String?
    let user: Bool
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: user ? size / 2 : size * 0.22)
            .fill(MoodStyle.color(emoji).opacity(emoji == nil ? 0.42 : 0.65))
            .overlay { if let emoji { Text(emoji).font(.system(size: size * 0.73)).minimumScaleFactor(0.65).lineLimit(1) } }
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}
struct MoodStatistics: View {
    let title: String
    let user: Bool
    let entries: [SharedEntry]
    private var days: [SharedEntry] { MoodStyle.latestPerDay(entries, actor: user ? "user" : "assistant") }
    private var groups: [(emoji: String, count: Int)] {
        Dictionary(grouping: days, by: \.emoji).map { (emoji: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.emoji < $1.emoji : $0.count > $1.count }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Text(title).font(.subheadline.weight(.semibold)); Spacer(); Text("\(days.count) 天").font(.caption).foregroundStyle(.secondary) }
            if days.isEmpty { Text("这个月还没有记录，慢慢来。").font(.caption).foregroundStyle(.secondary) }
            ForEach(groups, id: \.emoji) { group in
                HStack(spacing: 9) {
                    MoodBadge(emoji: group.emoji, user: user, size: 20)
                    Text(MoodStyle.label(group.emoji)).font(.caption).frame(width: 28, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule().fill(.secondary.opacity(0.12))
                            .overlay(alignment: .leading) { Capsule().fill(MoodStyle.color(group.emoji)).frame(width: geometry.size.width * Double(group.count) / Double(max(1, days.count))) }
                    }.frame(height: 7)
                    Text("\(group.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                }
            }
        }.padding(18).glassSurface(in: RoundedRectangle(cornerRadius: 24))
    }
}
