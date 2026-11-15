import AppKit

struct NotchAlert: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var source: String
    var date = Date()
}

/// Alerts arrive on POST /notify (and from Claude Code hooks); the newest one
/// shows in the closed pill for a few seconds.
@MainActor
final class AlertsService: ObservableObject {
    static let shared = AlertsService()

    @Published private(set) var alerts: [NotchAlert] = DataFile.load("alerts.json", as: [NotchAlert].self) ?? []
    @Published private(set) var flash: NotchAlert?
    private var flashWork: DispatchWorkItem?

    private init() {
        LocalServer.shared.route("POST", "/notify") { r in
            let j = r.json
            let title = j["title"] as? String ?? "Alert"
            AlertsService.shared.add(title: title, body: j["body"] as? String ?? j["message"] as? String ?? "",
                                     source: j["source"] as? String ?? "API")
            return (200, ["ok": true])
        }
    }

    func add(title: String, body: String, source: String) {
        let a = NotchAlert(title: title, body: body, source: source)
        alerts.insert(a, at: 0)
        if alerts.count > 100 { alerts.removeLast(alerts.count - 100) }
        DataFile.save("alerts.json", alerts)
        flash = a
        NSSound(named: "Tink")?.play()
        flashWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flash = nil }
        flashWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func remove(_ a: NotchAlert) { alerts.removeAll { $0.id == a.id }; DataFile.save("alerts.json", alerts) }
    func clear() { alerts = []; DataFile.save("alerts.json", alerts) }
}
