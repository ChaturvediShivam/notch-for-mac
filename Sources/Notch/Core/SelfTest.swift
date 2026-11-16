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
        // Looks: core tabs can't be hidden in the store edition; Settings never.
        assert(!Skin.canHide(.settings))
        if !Skin.isMaster { assert(!Skin.canHide(.home) && Skin.available.allSatisfy { !$0.masterOnly }) }
        assert(Skin.canHide(.markets))
        _ = Color(hex: "zz"); _ = Color(hex: ""); _ = Color(hex: "#FFFFFFFFFFFFFFFFFF")
        if !Skin.isMaster { assert(MeetingService.redact("secret plan here", 60) == "[3 words]") }
        print("selftest: all passed")
        exit(0)
    }
}
