import SwiftUI

/// Looks people can pick. The store edition gets the presets, glow and hiding optional tabs;
/// the master build (`-D MASTER`, see scripts/make-app.sh) also gets custom colours, the
/// Captain theme and hiding any tab.
struct Skin: Identifiable {
    let id, name: String
    let accent: Color
    /// Wash over the black panel, top → bottom. Empty = pure black (the default look).
    let tint: [Color]
    /// Edge glow around the open notch.
    let glow: [Color]
    /// Small mark beside the tab title.
    let mark: String
    var masterOnly = false

    #if MASTER
    static let isMaster = true
    #else
    static let isMaster = false
    #endif

    static let all: [Skin] = [
        Skin(id: "classic", name: "Classic", accent: Color(hex: "0A84FF"), tint: [], glow: [.white.opacity(0.35), .white.opacity(0.05)], mark: ""),
        Skin(id: "aurora", name: "Aurora", accent: Color(hex: "40E0D0"),
             tint: [Color(hex: "0E3B43"), Color(hex: "1B1035")], glow: [Color(hex: "40E0D0"), Color(hex: "8A5CF6"), Color(hex: "40E0D0")], mark: "sparkles"),
        Skin(id: "sunset", name: "Sunset", accent: Color(hex: "FF8A3D"),
             tint: [Color(hex: "3D1A12"), Color(hex: "2A0F25")], glow: [Color(hex: "FF8A3D"), Color(hex: "FF3D7F"), Color(hex: "FF8A3D")], mark: "sun.horizon.fill"),
        Skin(id: "graphite", name: "Graphite", accent: Color(hex: "E5E5EA"),
             tint: [Color(hex: "2C2C2E"), Color(hex: "1C1C1E")], glow: [.white.opacity(0.5), .white.opacity(0.1)], mark: ""),
        Skin(id: "neon", name: "Neon", accent: Color(hex: "FF2FD6"),
             tint: [Color(hex: "1A0B2E"), Color(hex: "04161F")], glow: [Color(hex: "FF2FD6"), Color(hex: "00E5FF"), Color(hex: "FF2FD6")], mark: "bolt.fill"),
        // Captain: Survey-Corps cloak green, blade steel, harness leather, a cup of black tea. Colours only, no artwork.
        Skin(id: "captain", name: "Captain (Levi)", accent: Color(hex: "C9D1D9"),
             tint: [Color(hex: "1F3A2B"), Color(hex: "0E1A14")], glow: [Color(hex: "C9D1D9"), Color(hex: "2E5E3E"), Color(hex: "6B4A2E"), Color(hex: "C9D1D9")],
             mark: "cup.and.saucer.fill", masterOnly: true),
    ]

    static var available: [Skin] { all.filter { isMaster || !$0.masterOnly } }

    /// Tabs the store edition can't hide: what the notch is for.
    static let coreTabs: Set<NotchTab> = [.home, .meeting, .media, .settings]

    @MainActor static var current: Skin {
        let c = Store.shared.config
        let base = available.first { $0.id == c.theme } ?? all[0]
        guard isMaster else { return base }
        // Master: your own colours override the preset.
        return Skin(id: base.id, name: base.name,
                    accent: c.accentHex.isEmpty ? base.accent : Color(hex: c.accentHex),
                    tint: c.tintHex.isEmpty ? base.tint : [Color(hex: c.tintHex), .black],
                    glow: base.glow, mark: base.mark, masterOnly: base.masterOnly)
    }

    @MainActor static func canHide(_ t: NotchTab) -> Bool { t != .settings && (isMaster || !coreTabs.contains(t)) }

    @MainActor static var visibleTabs: [NotchTab] {
        let hidden = Set(Store.shared.config.hiddenTabs)
        return NotchTab.allCases.filter { !hidden.contains($0.title) || !canHide($0) }
    }
}

extension Color {
    /// "RRGGBB" or "#RRGGBB"; anything else is white.
    init(hex: String) {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ")), radix: 16) ?? 0xFFFFFF
        self.init(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
