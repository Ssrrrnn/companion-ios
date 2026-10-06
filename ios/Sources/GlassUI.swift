import SwiftUI
import UIKit

/// Static translucent surfaces retain highlights without a blur pass per card/bubble.
struct GlassSurface<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color = .clear
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            shape.fill(reduceTransparency ? Color(uiColor: .secondarySystemGroupedBackground) :
                (scheme == .dark ? Color(uiColor: .secondarySystemGroupedBackground).opacity(0.96) : Color.white.opacity(0.64)))
            shape.fill(tint.opacity(scheme == .dark ? 0.12 : 0.055))
        }.overlay {
            shape.strokeBorderFallback(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.17 : 0.9),
                Color.white.opacity(0.035)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .allowsHitTesting(false)
        }
    }
}
private extension Shape {
    func strokeBorderFallback(_ gradient: LinearGradient) -> some View { stroke(gradient, lineWidth: 0.7) }
}
extension View {
    func glassSurface<S: Shape>(in shape: S, tint: Color = .clear) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }
    func chatSurface(tint: Color) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: 23, style: .continuous), tint: tint))
    }
}

enum WallpaperStyle: String, CaseIterable, Identifiable {
    case linen, mist, dusk, ocean
    var id: String { rawValue }
    var title: String {
        switch self { case .linen: return "奶油纸"; case .mist: return "柔雾"; case .dusk: return "晚霞"; case .ocean: return "潮汐" }
    }
    var accents: [Color] {
        switch self {
        case .linen: return [Color(red: 0.94, green: 0.90, blue: 0.84), Color(red: 0.89, green: 0.84, blue: 0.80), Color(red: 0.94, green: 0.88, blue: 0.86)]
        case .mist: return [Color(red: 0.83, green: 0.70, blue: 0.81), Color(red: 0.65, green: 0.78, blue: 0.88), Color(red: 0.90, green: 0.78, blue: 0.68)]
        case .dusk: return [Color(red: 0.88, green: 0.58, blue: 0.57), Color(red: 0.75, green: 0.59, blue: 0.80), Color(red: 0.94, green: 0.75, blue: 0.53)]
        case .ocean: return [Color(red: 0.45, green: 0.73, blue: 0.72), Color(red: 0.47, green: 0.61, blue: 0.82), Color(red: 0.73, green: 0.85, blue: 0.80)]
        }
    }
}

struct GlassWallpaper: View {
    @EnvironmentObject private var space: PersonalSpace
    @Environment(\.colorScheme) private var scheme
    @AppStorage("wallpaper_style") private var styleName = "linen"
    @AppStorage("wallpaper_shade") private var shade = 0.12
    @AppStorage("wallpaper_blur") private var blur = 0.0
    private var style: WallpaperStyle { WallpaperStyle(rawValue: styleName) ?? .linen }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let photo = space.wallpaper {
                    Image(uiImage: photo).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped().blur(radius: blur)
                } else {
                    LinearGradient(colors: scheme == .dark
                        ? [Color(red: 0.13, green: 0.12, blue: 0.11), Color(red: 0.19, green: 0.17, blue: 0.16)]
                        : style.accents, startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                (scheme == .dark ? Color.black : Color.white).opacity(space.wallpaper == nil ? (scheme == .dark ? 0.08 : 0.12) : max(shade, scheme == .dark ? 0.72 : 0.25))
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
