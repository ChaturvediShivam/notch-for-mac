import SwiftUI

/// Design system from DESIGN.md: flat, ink at low alpha, iOS accents. Ink is white at night and
/// black in the day (Look), so text stays readable on whatever is behind the glass.
@MainActor
enum Theme {
    static var ink: Color { Look.shared.light ? .black : .white }
    static var card: Color    { ink.opacity(Look.shared.light ? 0.07 : 0.11) }
    static var control: Color { ink.opacity(Look.shared.light ? 0.10 : 0.18) }
    static var hover: Color   { ink.opacity(Look.shared.light ? 0.18 : 0.32) }
    static var pressed: Color { ink.opacity(Look.shared.light ? 0.24 : 0.40) }

    /// The chosen skin's accent (Settings → Look).
    @MainActor static var accent: Color { Skin.current.accent }
    static let blue   = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
    static let green  = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let orange = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
    static let yellow = Color(red: 0xFF / 255, green: 0xD6 / 255, blue: 0x0A / 255)
    static let red    = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let purple = Color(red: 0xBF / 255, green: 0x5A / 255, blue: 0xF2 / 255)

    static let body    = Font.system(size: 14)
    static let caption = Font.system(size: 13)
    static let title   = Font.system(size: 14, weight: .semibold)
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
