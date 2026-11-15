import Foundation

struct Match: Identifiable {
    let id: String
    let league: String
    var home = "", away = "", homeScore = "", awayScore = ""
    var homeLogo: URL?, awayLogo: URL?
    var detail = ""
    var state = ""        // pre, in, post
    var date = Date()
}

/// Live scores from ESPN's public scoreboard JSON. Leagues are "sport/league" paths, e.g. soccer/eng.1.
@MainActor
final class ScoresService: ObservableObject {
    static let shared = ScoresService()

    @Published private(set) var matches: [Match] = []
    @Published private(set) var status = ""
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { ScoresService.shared.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let cfg = Store.shared.config
        guard cfg.netScores else { status = "Scores are off in Settings → Privacy"; matches = []; return }
        let leagues = cfg.leagues
        Task {
            var all: [Match] = []
            await withTaskGroup(of: [Match].self) { g in
                for l in leagues { g.addTask { await Self.fetch(l) } }
                for await m in g { all += m }
            }
            let order = ["in": 0, "pre": 1, "post": 2]
            matches = all.sorted { (order[$0.state] ?? 3, $0.date) < (order[$1.state] ?? 3, $1.date) }
            status = matches.isEmpty ? "No matches today in your leagues" : ""
        }
    }

    nonisolated static func fetch(_ league: String) async -> [Match] {
        guard let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/\(league)/scoreboard"),
              let raw = try? await Net.json(url) else { return [] }
        let j: Any? = raw
        let name = j["leagues"][0]["abbreviation"].str ?? j["leagues"][0]["name"].str ?? league
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]
        let iso2 = DateFormatter(); iso2.dateFormat = "yyyy-MM-dd'T'HH:mmZ"
        return j["events"].arr.compactMap { e -> Match? in
            let e: Any? = e
            let comp = e["competitions"][0]
            var m = Match(id: e["id"].str ?? UUID().uuidString, league: name)
            for c in comp["competitors"].arr {
                let c: Any? = c
                let abbr = c["team"]["abbreviation"].str ?? c["team"]["shortDisplayName"].str ?? "?"
                let score = c["score"].str ?? ""
                let logo = c["team"]["logo"].str.flatMap(URL.init)
                if c["homeAway"].str == "home" { m.home = abbr; m.homeScore = score; m.homeLogo = logo }
                else { m.away = abbr; m.awayScore = score; m.awayLogo = logo }
            }
            m.detail = e["status"]["type"]["shortDetail"].str ?? ""
            m.state = e["status"]["type"]["state"].str ?? ""
            if let d = e["date"].str { m.date = iso.date(from: d) ?? iso2.date(from: d) ?? Date() }
            return m
        }
    }
}
