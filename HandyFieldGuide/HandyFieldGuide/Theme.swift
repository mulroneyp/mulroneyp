import SwiftUI

enum GuideColor {
    static let paper = Color(red: 0.953, green: 0.933, blue: 0.894)
    static let card = Color(red: 0.984, green: 0.969, blue: 0.941)
    static let ink = Color(red: 0.110, green: 0.157, blue: 0.125)
    static let muted = Color(red: 0.239, green: 0.290, blue: 0.259)
    static let green = Color(red: 0.106, green: 0.200, blue: 0.188)
    static let line = Color(red: 0.847, green: 0.812, blue: 0.753)
    static let rust = Color(red: 0.604, green: 0.275, blue: 0.188)
}

struct GuideBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(GuideColor.paper.ignoresSafeArea())
            .foregroundStyle(GuideColor.ink)
    }
}

extension View {
    func guideBackground() -> some View {
        modifier(GuideBackground())
    }
}
