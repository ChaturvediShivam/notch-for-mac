import Foundation

struct Quote: Identifiable {
    let symbol: String
    var name = ""
    var price: Double = 0
    var prevClose: Double = 0
    var currency = ""
    var points: [Double] = []
    var id: String { symbol }
    var change: Double { price - prevClose }
    var pct: Double { prevClose > 0 ? change / prevClose * 100 : 0 }
}

/// Watchlist quotes from Yahoo Finance's public chart endpoint (no key). Refreshes every
/// minute while the tab is visible.
@MainActor
final class MarketsService: ObservableObject {
    static let shared = MarketsService()

    @Published private(set) var quotes: [Quote] = []
    @Published private(set) var status = ""
    @Published private(set) var updated: Date?
    private var timer: Timer?

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { MarketsService.shared.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        let cfg = Store.shared.config
        guard cfg.netMarkets else { status = "Markets are off in Settings → Privacy"; quotes = []; return }
        let symbols = cfg.watchlist
        Task {
            let results = await withTaskGroup(of: Quote?.self) { g in
                for s in symbols { g.addTask { await Self.fetch(s) } }
                var out: [String: Quote] = [:]
                for await q in g { if let q { out[q.symbol] = q } }
                return out
            }
            quotes = symbols.compactMap { results[$0] }
            status = quotes.isEmpty ? "Couldn't load quotes" : ""
            updated = Date()
        }
    }

    nonisolated static func fetch(_ symbol: String) async -> Quote? {
        guard let enc = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=1d&interval=5m")
        else { return nil }
        guard let raw = try? await Net.json(url) else { return nil }
        let j: Any? = raw
        let r = j["chart"]["result"][0]
        guard let price = r["meta"]["regularMarketPrice"].num else { return nil }
        var q = Quote(symbol: symbol)
        q.price = price
        q.prevClose = r["meta"]["chartPreviousClose"].num ?? r["meta"]["previousClose"].num ?? price
        q.name = r["meta"]["shortName"].str ?? r["meta"]["longName"].str ?? symbol
        q.currency = r["meta"]["currency"].str ?? ""
        q.points = r["indicators"]["quote"][0]["close"].arr.compactMap { ($0 as? NSNumber)?.doubleValue }
        return q
    }
}
