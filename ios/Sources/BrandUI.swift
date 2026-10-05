import SwiftUI
import UIKit

enum MorrowType {
    static func script(_ size: CGFloat) -> Font {
        .custom(UIFont(name: "SnellRoundhand", size: size) == nil ? "Baskerville-Italic" : "SnellRoundhand", size: size, relativeTo: .largeTitle)
    }
    static func editorial(_ size: CGFloat) -> Font { .custom("Baskerville", size: size, relativeTo: .title) }
}
