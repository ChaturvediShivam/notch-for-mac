import AppKit

@MainActor
final class HomeService: ObservableObject {
    static let shared = HomeService()

    enum Tile: String, CaseIterable, Identifiable {
        case wifi, bluetooth, darkMode, nightShift, keepAwake, lowPower
        var id: String { rawValue }
        var name: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .bluetooth: "Bluetooth"
            case .darkMode: "Dark mode"
            case .nightShift: "Night Shift"
            case .keepAwake: "Keep awake"
            case .lowPower: "Low Power"
            }
        }
        var symbol: String {
            switch self {
            case .wifi: "wifi"
            case .bluetooth: "dot.radiowaves.left.and.right"
            case .darkMode: "circle.lefthalf.filled"
            case .nightShift: "moon.fill"
            case .keepAwake: "cup.and.saucer.fill"
            case .lowPower: "battery.25"
            }
        }
    }

    /// nil = not available on this Mac.
    @Published private(set) var state: [Tile: Bool?] = [:]
    @Published private(set) var detail: [Tile: String] = [:]
    @Published private(set) var brightness: Float?
    @Published private(set) var busy: Set<Tile> = []

    private init() {
        if Store.shared.config.keepAwake { SystemControls.setKeepAwake(true) }
        refresh()
        // Re-read when the user changes things elsewhere.
        DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HomeService.shared.refresh() }
        }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HomeService.shared.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .userInitiated) {
            let wifi = SystemControls.wifiOn, ssid = SystemControls.wifiName
            let bt = SystemControls.bluetoothOn, ns = SystemControls.nightShift
            let b = SystemControls.brightness
            await MainActor.run {
                let s = HomeService.shared
                s.state = [.wifi: wifi, .bluetooth: bt, .darkMode: SystemControls.darkMode, .nightShift: ns,
                           .keepAwake: SystemControls.keepAwake, .lowPower: SystemControls.lowPower]
                s.detail[.wifi] = wifi ? (ssid ?? "On") : "Off"
                s.brightness = b
            }
        }
    }

    func isOn(_ t: Tile) -> Bool { (state[t] ?? nil) ?? false }
    func available(_ t: Tile) -> Bool { (state[t] ?? nil) != nil }

    func toggle(_ t: Tile) {
        let on = !isOn(t)
        state[t] = on                     // optimistic
        busy.insert(t)
        Task {
            switch t {
            case .wifi: await SystemControls.setWiFi(on)
            case .bluetooth: await SystemControls.setBluetooth(on)
            case .darkMode: await SystemControls.setDarkMode(on)
            case .nightShift: SystemControls.setNightShift(on)
            case .keepAwake:
                SystemControls.setKeepAwake(on)
                Store.shared.config.keepAwake = on
            case .lowPower: await SystemControls.setLowPower(on)
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            busy.remove(t)
            refresh()
        }
    }

    func setBrightness(_ v: Float) {
        brightness = v
        SystemControls.setBrightness(v)
    }
}
