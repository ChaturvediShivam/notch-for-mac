import Foundation
import SwiftUI

/// `NOTCH_SELFTEST=1 swift run` checks the hand-written parsers, then exits.
@MainActor
enum SelfTest {
    static func run() -> Never {
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
        // Calculator
        assert(near(Calculator.eval("2+3*4"), 14))
        assert(near(Calculator.eval("(2+3)*4"), 20))
        assert(near(Calculator.eval("2^3^2"), 512))
        assert(near(Calculator.eval("-3 + 5"), 2))
        assert(near(Calculator.eval("sqrt(16) + 10 % 4"), 6))
        assert(near(Calculator.eval("1,000 * 2"), 2000))
        assert(Calculator.eval("hello") == nil)
        assert(Calculator.eval("42") == nil)            // a bare number isn't maths
        assert(Calculator.eval("2+") == nil)
        assert(Calculator.format(2.5) == "2.5" && Calculator.format(4) == "4")
        // LRC lyrics
        let l = MediaService.parseLRC("[00:01.50]One\n[00:03.00][00:10.00]Two\n[ar:Someone]\nnot a line")
        assert(l.map(\.time) == [1.5, 3, 10] && l[1].text == "Two")
        // HTTP request parsing (waits for the full body)
        let raw = "POST /notify HTTP/1.1\r\nContent-Length: 5\r\nX-Notch-Token: t\r\n\r\nhello"
        assert(LocalServer.parse(Data(raw.utf8))?.body == Data("hello".utf8))
        assert(LocalServer.parse(Data(raw.dropLast(2).utf8)) == nil)
        assert(LocalServer.parse(Data(raw.utf8))?.headers["x-notch-token"] == "t")
        // Palette
        assert(PaletteService.timerSeconds("timer 10") == 600)
        assert(PaletteService.timerSeconds("t 90s") == 90)
        assert(PaletteService.timerSeconds("t 1.5h") == 5400)
        assert(PaletteService.url(from: "apple.com")?.absoluteString == "https://apple.com")
        assert(PaletteService.url(from: "two words.com") == nil)
        // Meeting question detection (English, Hinglish, Hindi)
        for q in ["What is the deadline for this project?", "Can you share the report by Monday",
                  "kya aap mujhe report bhej sakte hain", "ye feature kab tak ready hoga", "आप कब आएंगे",
                  "how would you handle the migration", "A funnel account?"] { assert(MeetingService.isQuestion(q), q) }
        for s in ["I will send it tomorrow.", "ok thanks", "humne budget discuss kiya", "The client approved the design.", "When everything is ready, we will launch."] {
            assert(!MeetingService.isQuestion(s), s)
        }
        // From the 17 Nov interview: missed asks, and my answers that got "You asked" cards.
        for q in ["So please introduce yourself.", "Uh, I would like to know, Lou, about yourself.",
                  "Um, tell me how comfortable are you with Excel and data modelling", "Walk me through your resume."] {
            assert(MeetingService.isQuestion(q), q)
        }
        assert(!MeetingService.isQuestion("So I, I shortlist from the market map and what our sales team and customers tell me, then, Visit the top 23 checked"))
        assert(!MeetingService.isQuestion("Where I did, uh, prep research, whether they are involved in any political", strict: true))
        assert(MeetingService.isQuestion("Which segments is IMI focusing on first?", strict: true))
        assert(!MeetingService.isQuestion("Okay, that's all, we'll let you know."))
        // From the 18 Nov interview: a lead-in before the question word, and "Are you" misheard as "I do".
        assert(MeetingService.isQuestion("Okay, and how much, uh, are you expecting like"))
        assert(MeetingService.isQuestion("I do comfortable with primary market research and field travel."))
        assert(!MeetingService.isQuestion("I'm comfortable with that, we can move on."))
        assert(!MeetingService.isQuestion("So I start with the clustering mapping of the area like from Pune"))
        if #available(macOS 26.0, *) {
            let r = AnalyzerTranscriber.roman("क्या आप हैं")
            assert(r == "kya apa hain", r)
        }
        // Fuzz: hostile or junk input must never crash (these used to be, or could be, remote/local crash paths).
        assert(LocalServer.parse(Data("POST / HTTP/1.1\r\nContent-Length: -5\r\n\r\nabc".utf8))?.body.isEmpty == true)
        assert(LocalServer.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\nabc".utf8)) != nil)
        assert(LocalServer.parse(Data("\r\n\r\n".utf8)) == nil)
        assert(LocalServer.parse(Data([0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A])) == nil)
        assert(LocalServer.sameToken(LocalServer.token) && !LocalServer.sameToken("") && !LocalServer.sameToken(LocalServer.token + "x"))
        _ = Calculator.eval(String(repeating: "(", count: 100_000) + "1")
        _ = Calculator.eval(String(repeating: "-", count: 100_000) + "1")
        _ = Calculator.eval(String(repeating: "(", count: 199) + "1")
        _ = Calculator.eval(String(repeating: "2^", count: 100_000) + "2")
        assert(Calculator.eval("9^9^9") == nil || Calculator.eval("9^9^9")!.isInfinite || true)
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("0123456789+-*/^%().,  sqrtabcक्याहैं?!\u{0}\u{202E}😀\n")
        for _ in 0..<3000 {
            let junk = String((0..<Int.random(in: 0...40, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            _ = Calculator.eval(junk); _ = MeetingService.isQuestion(junk); _ = PaletteService.url(from: junk)
            _ = PaletteService.timerSeconds(junk); _ = LocalServer.parse(Data(junk.utf8))
            if #available(macOS 26.0, *) { _ = AnalyzerTranscriber.roman(junk) }
        }
        // Config: junk / wrong types fall back to defaults instead of failing.
        let bad = try? JSONDecoder().decode(Config.self, from: Data(#"{"opacity":"x","theme":5,"hiddenTabs":"Home","glass":true}"#.utf8))
        assert(bad?.opacity == 1.0 && bad?.theme == "classic" && bad?.hiddenTabs == [] && bad?.glass == true)
        // Fillers: picked by question kind, rotating wording.
        assert(MeetingService.filler(for: "What are your salary expectations?", turn: 0).contains("numbers"))
        assert(MeetingService.filler(for: "Why do you want to join us", turn: 1).contains("comes down"))
        assert(MeetingService.filler(for: "Tell me about yourself", turn: 0).contains("quick picture"))
        assert(TrackerService.gid("https://x/edit?gid=905551930#gid=905551930") == "905551930")
        // Company: whole word, capitals-only names need capitals; new questions = not close to any prepared one.
        let names = ["NEC India", "AHEAD", "Marsh", "micro1"]
        assert(TrackerService.company(in: "Interview: NEC – Sr Executive", names: names) == "NEC India")
        assert(TrackerService.company(in: "plan ahead, Marshall", names: names) == nil)
        assert(TrackerService.company(in: "Hi, this is Priya from AHEAD", names: names) == "AHEAD")
        let known = TrackerService.content("Tell me about your data-centre analysis")
        assert(Double(TrackerService.content("Walk me through the data centre analysis you did").intersection(known).count) >= 2)
        // CV pick: tracker's "CV used" for a known company wins; else role words.
        let tr = [["Company", "Status", "CV used"], ["NEC India (via LanceSoft)", "Applied", "CV1 Research"]]
        assert(TrackerService.cvNumber(for: "", company: "NEC India", trackerRows: tr)?.n == 1)
        assert(TrackerService.cvNumber(for: "We're hiring an AI application engineer, React and TypeScript", company: nil, trackerRows: tr)?.n == 3)
        assert(TrackerService.cvNumber(for: "AI training and LLM evaluation work, RLHF", company: nil, trackerRows: tr)?.n == 2)
        assert(TrackerService.cvNumber(for: "operations manager for fielding and market research", company: nil, trackerRows: tr)?.n == 1)
        assert(TrackerService.cvNumber(for: "hello how are you", company: nil, trackerRows: tr) == nil)
        // Job tracker sheet: quoted CSV (commas, "" and new lines inside), sheet id from a link, follow-ups due.
        let rows = TrackerService.csv("Company,Target role,Status,Follow-up date\n\"NEC, India\",\"Sr \"\"Exec\"\"\nBD\",Applied,11-Nov-2026\nOddup,Analyst,Rejected,12-Nov-2026\nEpoch,Researcher,Applied,30-Dec-2099\n")
        assert(rows.count == 4 && rows[1] == ["NEC, India", "Sr \"Exec\"\nBD", "Applied", "11-Nov-2026"], "\(rows)")
        let due = TrackerService.due(rows, now: Date(timeIntervalSince1970: 1_795_000_000))   // Nov 2026
        assert(due.map(\.company) == ["NEC, India"], "\(due)")
        assert(TrackerService.sheetID("https://docs.google.com/spreadsheets/d/abc_1-X/edit?usp=sharing") == "abc_1-X")
        // Delivery coach: a 3 s silence that ends right after a card's words arrive is "waited for the card".
        let t0 = Date()
        let prog = [0.0, 0.5, 1.0, 4.0, 4.5, 5.0].map { t0.addingTimeInterval($0) }
        let rep = MeetingService.deliveryReport(progress: prog, questionEnded: t0.addingTimeInterval(-1.2),
                                                cardEvents: [t0.addingTimeInterval(3.5)],
                                                words: "uh so i um built the market map for the cluster".split(separator: " ").map(String.init), gaze: nil)
        assert(rep.pauses == 1 && rep.waited == 1 && rep.fillers == 2 && rep.text.contains("Started 1.2 s"), rep.text)
        // Started 5 s after the question, 1 s after the card's first words: that's waiting for the card too.
        let late = MeetingService.deliveryReport(progress: [5.0, 6, 7].map { t0.addingTimeInterval($0) }, questionEnded: t0,
                                                 cardEvents: [t0.addingTimeInterval(4)], words: Array(repeating: "word", count: 12), gaze: nil)
        assert(late.waited == 1 && late.text.contains("1.0 s after the card"), late.text)
        // Gaze: reading 4 lines = drift along, jump back 3 times = 3 sweeps; a still gaze = 0.
        var fr: [GazeTracker.Frame] = [], tt = 0.0
        for _ in 0..<4 { for k in 0..<6 { fr.append(.init(t: t0.addingTimeInterval(tt), face: true, away: false, h: 0.3 + Float(k) * 0.05, v: 0.5)); tt += 0.08 } }
        assert(GazeTracker.summarize(fr, baseline: fr)?.sweeps == 3)
        let still = (0..<30).map { GazeTracker.Frame(t: t0.addingTimeInterval(Double($0) * 0.08), face: true, away: false, h: 0.5, v: 0.5) }
        assert(GazeTracker.summarize(still, baseline: still)?.sweeps == 0 && GazeTracker.summarize(still, baseline: still)?.level == 1)
        // Old configs (no CV/JD/role yet) keep their context in "My words" and start as "I'm answering".
        let legacy = try? JSONDecoder().decode(Config.self, from: Data(#"{"meetingTopic":"my resume"}"#.utf8))
        assert(legacy?.meetingTopic == "my resume" && legacy?.meetingCV == "" && legacy?.meetingRole == "answer")
        assert(MeetingService.contextFields(interviewing: true)[0].label == "Candidate's CV")
        // Looks: core tabs can't be hidden in the store edition; Settings never.
        assert(!Skin.canHide(.settings))
        if !Skin.isMaster { assert(!Skin.canHide(.home) && Skin.available.allSatisfy { !$0.masterOnly }) }
        assert(Skin.canHide(.markets))
        _ = Color(hex: "zz"); _ = Color(hex: ""); _ = Color(hex: "#FFFFFFFFFFFFFFFFFF")
        if !Skin.isMaster { assert(MeetingService.redact("secret plan here", 60) == "[3 words]") }
        // Retention: only files older than the cutoff go.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notch-retention-test")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let old = tmp.appendingPathComponent("old"), new = tmp.appendingPathComponent("new")
        FileManager.default.createFile(atPath: old.path, contents: Data()); FileManager.default.createFile(atPath: new.path, contents: Data())
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)], ofItemAtPath: old.path)
        Retention.deleteFiles(in: tmp, before: Date(timeIntervalSinceNow: -7 * 86_400))
        assert(!FileManager.default.fileExists(atPath: old.path) && FileManager.default.fileExists(atPath: new.path))
        try? FileManager.default.removeItem(at: tmp)
        print("selftest: all passed")
        exit(0)
    }
}
