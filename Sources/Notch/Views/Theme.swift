import SwiftUI

/// Design system from DESIGN.md: flat, pure black, white at low alpha, iOS accents.
enum Theme {
    static let card    = Color.white.opacity(0.11)
    static let control = Color.white.opacity(0.18)
    static let hover   = Color.white.opacity(0.32)
    static let pressed = Color.white.opacity(0.40)

    static let blue   = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
    static let green  = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let yellow = Color(red: 0xFF / 255, green: 0xD6 / 255, blue: 0x0A / 255)
    static let red    = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let purple = Color(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)

    static let body    = Font.system(size: 13)
    static let caption = Font.system(size: 12)
    static let title   = Font.system(size: 13, weight: .semibold)
}

/// Every hover/press fill is rounded.
struct GlyphButtonStyle: ButtonStyle {
    var radius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        GlyphBody(configuration: configuration, radius: radius)
    }
    private struct GlyphBody: View {
        let configuration: ButtonStyle.Configuration
        let radius: CGFloat
        @State private var hover = false
        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(configuration.isPressed ? Theme.pressed : (hover ? Theme.card : .clear))
                )
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}
