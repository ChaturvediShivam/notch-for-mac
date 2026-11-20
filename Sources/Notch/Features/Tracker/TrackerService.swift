import AppKit
import PDFKit

/// Job-search tracker from a Google Sheet shared as "anyone with the link". Read-only, no Google login:
/// each tab comes down as CSV. Meeting answers get it as context (expected CTC, where I applied, CV notes),
/// and Today lists the follow-ups that are due.
@MainActor
final class TrackerService: ObservableObject {
    static let shared = TrackerService()
    /// The tabs worth knowing in a call; the rest (long company lists, sources) would only slow the prompt.
    static let tabs = ["Start Here", "Role Fit & Salary", "Application Tracker", "CV Improvements"]

    @Published private(set) var text = ""                                   // all tabs as plain lines, for prompts
    @Published private(set) var qaRows: [[String]] = []                     // my prepared interview Q&A sheet (row 0 = headings)
    @Published private(set) var cvs: [(name: String, text: String)] = []      // CV1, CV2, CV3… in file-name order
    private(set) var trackerRows: [[String]] = []                            // Application Tracker (row 0 = headings)
    @Published private(set) var followUps: [(company: String, role: String, status: String, date: Date)] = []
    @Published private(set) var status = ""
    private var lastFetch: Date?

    /// Sheet id from a pasted link (or the bare id).
    nonisolated static func sheetID(_ link: String) -> String? {
        let s = link.trimmingCharacters(in: .whitespaces)
        if let r = s.range(of: "/d/") { return s[r.upperBound...].split(separator: "/").first.map(String.init) }
        return s.isEmpty || s.contains("/") ? nil : s
    }

    /// Every 30 min at most, unless forced (Today's refresh button, a meeting starting).
    func refresh(force: Bool = false) {
        let c = Store.shared.config
        guard c.netTracker else { text = ""; qaRows = []; trackerRows = []; followUps = []; return }
        if !force, let l = lastFetch, Date().timeIntervalSince(l) < 1800 { return }
        lastFetch = Date()
        loadCVs()
        Task {
            // Q&A sheet: the tab in the link (gid), or its first tab.
            if let id = Self.sheetID(c.qaURL) { qaRows = await Self.fetch(id, ["gid": Self.gid(c.qaURL) ?? "0"]) ?? [] } else { qaRows = [] }
            guard let id = Self.sheetID(c.trackerURL) else { text = ""; followUps = []; return }
            var parts: [String] = [], rows: [[String]] = []
            for tab in Self.tabs {
                guard let t = await Self.fetch(id, ["sheet": tab]) else { continue }
                parts.append("## \(tab)\n" + t.map { $0.filter { !$0.isEmpty }.joined(separator: " | ") }.joined(separator: "\n"))
                if tab == "Application Tracker" { rows = t }
            }
            text = parts.joined(separator: "\n\n")
            trackerRows = rows
            followUps = Self.due(rows)
            status = parts.isEmpty ? "Couldn't read the sheet. Is it shared as \"Anyone with the link\"?" : ""
        }
    }

    // MARK: Which CV fits this call

    /// Reads the CV files off the main thread (PDF text or plain text).
    func loadCVs() {
        let paths = Store.shared.config.cvPaths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        Task.detached {
            let out = paths.compactMap { p -> (String, String)? in
                let u = URL(fileURLWithPath: p)
                let t = u.pathExtension.lowercased() == "pdf" ? PDFDocument(url: u)?.string : try? String(contentsOf: u, encoding: .utf8)
                return t.flatMap { $0.isEmpty ? nil : (u.deletingPathExtension().lastPathComponent, $0) }
            }
            await MainActor.run { TrackerService.shared.cvs = out }
        }
    }

    /// Pick the CV files (several at once). File names in order = CV1, CV2, CV3.
    func chooseCVs() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.pdf, .plainText]
        p.message = "Choose your CV versions. Name order = CV1, CV2, CV3."
        p.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        defer { NotchModel.shared.show(.meeting) }
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        Store.shared.config.cvPaths = p.urls.map(\.path)
        loadCVs()
    }

    /// Words that point to each CV, as in the Role Fit tab: CV1 research / CI / strategy / ops / KYC,
    /// CV2 research + AI, CV3 building AI products.
    nonisolated static let cvSignals: [[String]] = [
        ["market research", "competitive intelligence", "market intelligence", "market development", "strategy", "business expansion",
         "due diligence", "kyc", "aml", "insights", "operations", "fielding", "consulting", "benchmarking"],
        ["ai research", "research operations", "ai training", "ai analyst", "llm", "genai", "gen ai", "rlhf", "annotation",
         "prompt", "evaluation", "ai expert", "machine learning", "data quality", "ai tools"],
        ["engineer", "engineering", "developer", "frontend", "front-end", "full-stack", "full stack", "react", "typescript",
         "software", "ai application", "agentic", "builder", "product development", "founder", "api", "swift"]]

    /// Which CV (1-based) the call is about: the tracker's "CV used" for this company, else the role words heard
    /// or in the Job box / calendar. nil = no signal.
    nonisolated static func cvNumber(for text: String, company: String?, trackerRows: [[String]]) -> (n: Int, why: String)? {
        if let company, let ci = column(trackerRows, "company"), let vi = column(trackerRows, "cv"),
           let row = trackerRows.dropFirst().first(where: { ci < $0.count && $0[ci].lowercased().contains(company.split(separator: " ")[0].lowercased()) }),
           vi < row.count, let d = row[vi].first(where: { ("1"..."9").contains(String($0)) }), let n = Int(String(d)) {
            return (n, "\(company) in your tracker")
        }
        let t = " " + text.lowercased() + " "
        let scores = cvSignals.map { ks in ks.filter { t.range(of: "(?<![a-z])" + NSRegularExpression.escapedPattern(for: $0) + "(?![a-z])", options: .regularExpression) != nil } }
        guard let best = scores.indices.max(by: { scores[$0].count < scores[$1].count }), !scores[best].isEmpty else { return nil }
        return (best + 1, "heard " + scores[best].prefix(2).joined(separator: ", "))
    }

    // MARK: Which company is this call with

    /// Column whose heading starts with `name` ("company" matches "Company / CV").
    nonisolated static func column(_ rows: [[String]], _ name: String) -> Int? {
        rows.first?.firstIndex { $0.lowercased().hasPrefix(name) }
    }

    /// Company names from both sheets: "NEC India (via LanceSoft) – Sr Executive" → "NEC India";
    /// "micro1 / Mercor / Alignerr – AI interviews" → three names. Role groups ("All", "AI roles") aren't companies.
    var companies: [String] {
        var out: [String] = []
        for rows in [qaRows, trackerRows] {
            guard let ci = Self.column(rows, "company") else { continue }
            for r in rows.dropFirst() where ci < r.count {
                let name = r[ci].components(separatedBy: " – ")[0].components(separatedBy: " (")[0]
                for n in name.components(separatedBy: " / ") {
                    let n = n.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty, !Self.groups.contains(where: { n.lowercased().hasPrefix($0) }), !out.contains(n) { out.append(n) }
                }
            }
        }
        return out
    }
    nonisolated static let groups = ["all", "any", "ai ", "ai/", "research", "strategy", "pmm", "role"]

    /// First company whose first word shows up in `text` as a whole word. Names written in capitals
    /// in the sheet (AHEAD, NAILBITER) must match in capitals, so "ahead of time" in a JD isn't a company.
    nonisolated static func company(in text: String, names: [String]) -> String? {
        names.first { n in
            guard let key = n.split(separator: " ").first.map(String.init), key.count >= 3 else { return false }
            let caps = key == key.uppercased() && key.contains(where: \.isLetter)
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: key) + "(?![A-Za-z0-9])"
            return text.range(of: pattern, options: caps ? .regularExpression : [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// The Q&A for the prompt: this company's rows first, then the rest.
    func qaText(company: String?) -> String {
        guard let h = qaRows.first else { return "" }
        let ci = Self.column(qaRows, "company")
        let key = company?.split(separator: " ").first.map { $0.lowercased() }
        let body = qaRows.dropFirst()
        let mine = body.filter { r in key.map { k in ci.map { $0 < r.count && r[$0].lowercased().contains(k) } ?? false } ?? false }
        return ([h] + mine + body.filter { r in !mine.contains(r) })
            .map { $0.filter { !$0.isEmpty }.joined(separator: " | ") }.joined(separator: "\n")
    }

    /// Questions heard in the call that no Q&A row covers: few shared content words with every prepared question.
    func newQuestions(_ heard: [String]) -> [String] {
        guard let qi = Self.column(qaRows, "question") else { return [] }
        let known = qaRows.dropFirst().compactMap { qi < $0.count ? Self.content($0[qi]) : nil }
        return heard.filter { q in
            let w = Self.content(q)
            return w.count >= 2 && !known.contains { k in Double(w.intersection(k).count) / Double(min(w.count, max(k.count, 1))) >= 0.5 }
        }
    }
    nonisolated static func content(_ s: String) -> Set<String> {
        let stop: Set<String> = ["what", "your", "you", "about", "would", "could", "with", "this", "that", "have", "tell",
                                 "they", "there", "from", "will", "does", "were", "which", "where", "when", "into", "some", "please", "like", "just", "okay", "also"]
        return Set(s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { $0.count > 3 && !stop.contains($0) })
    }

    // MARK: Writing back (Apps Script web app in the user's own Google account)

    /// After a call: tracker row status + follow-up date, and new questions appended to the Q&A tab.
    func report(company: String?, questions: [String]) async -> String? {
        let c = Store.shared.config
        guard c.netTracker, let url = URL(string: c.sheetWriteURL.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              let key = Keychain.get("sheet-write"), company != nil || !questions.isEmpty else { return nil }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d-MMM-yyyy"
        let today = f.string(from: Date()), follow = f.string(from: Date().addingTimeInterval(3 * 86400))
        var body: [String: Any] = ["key": key, "date": today, "questions": questions,
                                   "qaId": Self.sheetID(c.qaURL) ?? "", "qaGid": Self.gid(c.qaURL) ?? "0"]
        if let company { body["company"] = company; body["status"] = "Interviewed \(today)"; body["followUp"] = follow }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")   // Apps Script reads the raw body
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], j["ok"] as? Bool == true else {
            return "Couldn't update the sheet (check the script link in Settings → Job tracker)."
        }
        refresh(force: true)
        return [company.map { "Tracker: \($0) → Interviewed, follow up \(follow)" },
                questions.isEmpty ? nil : "\(questions.count) new question\(questions.count == 1 ? "" : "s") added to your Q&A sheet"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The script to paste into the tracker sheet (Extensions → Apps Script), with this Mac's key in it.
    static func script(key: String) -> String {
        #"""
        // Notch → this sheet. Deploy: Deploy → New deployment → Web app, Execute as: Me, Who has access: Anyone.
        // Only requests carrying this key are accepted.
        const KEY = "\#(key)";
        function doPost(e) {
          const b = JSON.parse(e.postData.contents);
          if (b.key !== KEY) return out({ ok: false, error: "bad key" });
          if (b.company) {
            const sh = SpreadsheetApp.getActive().getSheetByName("Application Tracker");
            const v = sh.getDataRange().getValues(), h = v[0].map(x => String(x).toLowerCase());
            const col = n => h.findIndex(x => x.startsWith(n));
            const c = col("company"), s = col("status"), f = col("follow"), d = col("date applied");
            const k = b.company.toLowerCase().split(" ")[0];
            let r = v.findIndex((row, i) => i > 0 && String(row[c]).toLowerCase().includes(k));
            if (r < 0) {
              const row = h.map(() => ""); row[c] = b.company; if (d >= 0) row[d] = b.date; row[col("notes")] = "Added by Notch";
              sh.appendRow(row); r = sh.getLastRow() - 1;
            }
            if (s >= 0) sh.getRange(r + 1, s + 1).setValue(b.status);
            if (f >= 0) sh.getRange(r + 1, f + 1).setValue(b.followUp);
          }
          if (b.questions && b.questions.length && b.qaId) {
            const qs = SpreadsheetApp.openById(b.qaId).getSheets().find(x => String(x.getSheetId()) === String(b.qaGid));
            const h = qs.getRange(1, 1, 1, qs.getLastColumn()).getValues()[0].map(x => String(x).toLowerCase());
            const col = n => h.findIndex(x => x.startsWith(n));
            b.questions.forEach(q => {
              const row = h.map(() => ""); row[0] = qs.getLastRow();
              if (col("section") >= 0) row[col("section")] = "NEW from call " + b.date;
              if (col("company") >= 0) row[col("company")] = b.company || "All";
              row[col("question")] = q; qs.appendRow(row);
            });
          }
          return out({ ok: true });
        }
        function out(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
        """#
    }

    /// One tab as rows (blank rows dropped); nil when unreadable or empty.
    nonisolated static func fetch(_ id: String, _ which: [String: String]) async -> [[String]]? {
        var q = URLComponents(string: "https://docs.google.com/spreadsheets/d/\(id)/gviz/tq")!
        q.queryItems = [.init(name: "tqx", value: "out:csv")] + which.map { .init(name: $0.key, value: $0.value) }
        guard let (d, r) = try? await URLSession.shared.data(from: q.url!), (r as? HTTPURLResponse)?.statusCode == 200,
              let s = String(data: d, encoding: .utf8) else { return nil }
        let t = csv(s).filter { $0.contains { !$0.isEmpty } }
        return t.isEmpty ? nil : t
    }

    /// Tab id from a link's "gid=123".
    nonisolated static func gid(_ link: String) -> String? {
        link.range(of: #"gid=\d+"#, options: .regularExpression).map { String(link[$0].dropFirst(4)) }
    }

    /// Application Tracker rows with a follow-up date up to 2 days ahead, oldest first.
    nonisolated static func due(_ rows: [[String]], now: Date = Date()) -> [(company: String, role: String, status: String, date: Date)] {
        guard let head = rows.first,
              let fi = head.firstIndex(where: { $0.lowercased().hasPrefix("follow") }) else { return [] }
        let col = { (name: String) in head.firstIndex { $0.lowercased().hasPrefix(name) } }
        let ci = col("company") ?? 0, ri = col("target role") ?? col("role"), si = col("status")
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "d-MMM-yyyy"
        let limit = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now))!
        func at(_ r: [String], _ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0] : nil } ?? "" }
        return rows.dropFirst().compactMap { r in
            guard let d = f.date(from: at(r, fi)), d <= limit, !at(r, si).lowercased().contains("rejected") else { return nil }
            return (at(r, ci), at(r, ri), at(r, si), d)
        }.sorted { $0.date < $1.date }
    }

    /// RFC 4180 CSV: quoted fields may hold commas, quotes ("") and new lines.
    nonisolated static func csv(_ s: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = s.makeIterator()
        while let ch = it.next() {
            if quoted {
                if ch == "\"" {
                    guard let n = it.next() else { quoted = false; break }
                    if n == "\"" { field.append("\"") } else {
                        quoted = false
                        if n == "," { row.append(field); field = "" }
                        else if n == "\n" || n == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
                    }
                } else { field.append(ch) }
            } else if ch == "\"" { quoted = true }
            else if ch == "," { row.append(field); field = "" }
            else if ch == "\n" || ch == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(ch) }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
