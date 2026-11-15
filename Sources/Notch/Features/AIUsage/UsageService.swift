import Foundation

/// Claude Code token usage, read locally from ~/.claude/projects/**/*.jsonl (no network).
@MainActor
final class UsageService: ObservableObject {
    static let shared = UsageService()

    struct Day: Identifiable { let date: Date; var tokens: Int; var id: Date { date } }
    struct ModelRow: Identifiable { let model: String; var input: Int; var output: Int; var cacheRead: Int; var cacheWrite: Int
        var id: String { model }; var total: Int { input + output + cacheRead + cacheWrite } }

    @Published private(set) var days: [Day] = []
    @Published private(set) var models: [ModelRow] = []
    @Published private(set) var today = 0
    @Published private(set) var windowTokens = 0       // current 5-hour window
    @Published private(set) var windowStart: Date?
    @Published private(set) var messagesToday = 0
    @Published private(set) var loading = false
    @Published private(set) var updated: Date?

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let r = Self.scan()
            await MainActor.run {
                let s = UsageService.shared
                s.days = r.days; s.models = r.models; s.today = r.today; s.messagesToday = r.msgs
                s.windowTokens = r.window; s.windowStart = r.windowStart
                s.loading = false; s.updated = Date()
            }
        }
    }

    nonisolated private static func scan() -> (days: [Day], models: [ModelRow], today: Int, msgs: Int, window: Int, windowStart: Date?) {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cal = Calendar.current
        let since = cal.startOfDay(for: Date().addingTimeInterval(-6 * 86400))
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var perDay: [Date: Int] = [:], perModel: [String: ModelRow] = [:]
        var seen = Set<String>(), stamps: [(Date, Int)] = []
        var today = 0, msgs = 0
        let startToday = cal.startOfDay(for: Date())

        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "jsonl",
                  let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  mod >= since, let data = try? Data(contentsOf: url) else { continue }
            for line in data.split(separator: 0x0A) where line.count > 50 {
                // Cheap filter before parsing JSON.
                guard line.range(of: Data("\"usage\"".utf8)) != nil,
                      let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any],
                      let ts = (o["timestamp"] as? String).flatMap(iso.date), ts >= since else { continue }
                let key = "\(m["id"] ?? "")|\(o["requestId"] ?? "")"
                guard seen.insert(key).inserted else { continue }
                func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
                let inp = n("input_tokens"), out = n("output_tokens")
                let cr = n("cache_read_input_tokens"), cw = n("cache_creation_input_tokens")
                let total = inp + out + cr + cw
                let model = m["model"] as? String ?? "unknown"
                guard model != "<synthetic>" else { continue }
                perDay[cal.startOfDay(for: ts), default: 0] += total
                var row = perModel[model] ?? ModelRow(model: model, input: 0, output: 0, cacheRead: 0, cacheWrite: 0)
                row.input += inp; row.output += out; row.cacheRead += cr; row.cacheWrite += cw
                perModel[model] = row
                if ts >= startToday { today += total; msgs += 1 }
                stamps.append((ts, total))
            }
        }
        // 5-hour windows start at the first message after the previous window ended (hour-floored).
        stamps.sort { $0.0 < $1.0 }
        var wStart: Date?, wTokens = 0
        for (t, n) in stamps {
            if let s = wStart, t < s.addingTimeInterval(5 * 3600) { wTokens += n }
            else {
                wStart = cal.dateInterval(of: .hour, for: t)?.start ?? t
                wTokens = n
            }
        }
        if let s = wStart, Date() >= s.addingTimeInterval(5 * 3600) { wStart = nil; wTokens = 0 }
        let days = (0..<7).reversed().map { i -> Day in
            let d = cal.startOfDay(for: Date().addingTimeInterval(-Double(i) * 86400))
            return Day(date: d, tokens: perDay[d] ?? 0)
        }
        return (days, perModel.values.sorted { $0.total > $1.total }, today, msgs, wTokens, wStart)
    }

    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.1fk", Double(n) / 1e3)
        default: "\(n)"
        }
    }
}
