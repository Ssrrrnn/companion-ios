import SwiftUI
import UIKit

/// Glass controls on newer systems, translucent material on iOS 18.
struct GlassSurface<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color = .clear
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.10), lineWidth: 0.6))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else { compatible(content) }
            #else
            compatible(content)
            #endif
        }
    }
    private func compatible(_ content: Content) -> some View {
        content
            .background {
                shape.fill(tint.opacity(scheme == .dark ? 0.20 : 0.11))
                    .background(.ultraThinMaterial, in: shape)
            }
            .overlay {
                shape.stroke(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.36 : 0.80),
                    .white.opacity(0.08), .white.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.18 : 0.055), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func glassSurface<S: Shape>(in shape: S, tint: Color = .clear) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }
    func chatSurface(tint: Color) -> some View { modifier(ChatSurface(tint: tint)) }
}

/// Lazy chat rows use glass without the large per-row shadows of card surfaces.
private struct ChatSurface: ViewModifier {
    let tint: Color
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
                .overlay(shape.stroke(tint.opacity(0.2), lineWidth: 0.8))
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) { content.glassEffect(.regular.tint(tint.opacity(0.25)), in: shape) }
            else { compatible(content, shape: shape) }
            #else
            compatible(content, shape: shape)
            #endif
        }
    }
    private func compatible(_ content: Content, shape: RoundedRectangle) -> some View {
        content.background(.ultraThinMaterial, in: shape)
            .overlay(shape.fill(tint.opacity(scheme == .dark ? 0.16 : 0.09)).allowsHitTesting(false))
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.35 : 0.82), .white.opacity(0.08), .white.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8).allowsHitTesting(false))
    }
}

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case mist, dusk, ocean
    var id: String { rawValue }
    var title: String {
        switch self { case .mist: return "柔雾"; case .dusk: return "晚霞"; case .ocean: return "潮汐" }
    }
    var accents: [Color] {
        switch self {
        case .mist: return [Color(red: 0.83, green: 0.70, blue: 0.81), Color(red: 0.65, green: 0.78, blue: 0.88), Color(red: 0.90, green: 0.78, blue: 0.68)]
        case .dusk: return [Color(red: 0.88, green: 0.58, blue: 0.57), Color(red: 0.75, green: 0.59, blue: 0.80), Color(red: 0.94, green: 0.75, blue: 0.53)]
        case .ocean: return [Color(red: 0.45, green: 0.73, blue: 0.72), Color(red: 0.47, green: 0.61, blue: 0.82), Color(red: 0.73, green: 0.85, blue: 0.80)]
        }
    }
}

struct GlassWallpaper: View {
    @EnvironmentObject private var space: PersonalSpace
    @Environment(\.colorScheme) private var scheme
    @AppStorage("wallpaper_style") private var styleName = "mist"
    @AppStorage("wallpaper_shade") private var shade = 0.12
    @AppStorage("wallpaper_blur") private var blur = 0.0
    private var style: WallpaperStyle { WallpaperStyle(rawValue: styleName) ?? .mist }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let photo = space.wallpaper {
                    Image(uiImage: photo).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped().blur(radius: blur)
                } else {
                    Color(uiColor: scheme == .dark ? .black : UIColor(red: 0.94, green: 0.93, blue: 0.95, alpha: 1))
                    RadialGradient(colors: [style.accents[0], .clear], center: .topLeading, startRadius: 0, endRadius: geometry.size.height * 0.8)
                    RadialGradient(colors: [style.accents[1].opacity(0.8), .clear], center: .trailing, startRadius: 0, endRadius: geometry.size.height * 0.65)
                    RadialGradient(colors: [style.accents[2].opacity(0.8), .clear], center: .bottomLeading, startRadius: 0, endRadius: geometry.size.height * 0.55)
                }
                (scheme == .dark ? Color.black : Color.white).opacity(space.wallpaper == nil ? (scheme == .dark ? 0.57 : 0.18) : shade)
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
