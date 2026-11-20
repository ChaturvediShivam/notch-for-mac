import AppKit

/// `NOTCH_BENCH=1 build/Notch.app/Contents/MacOS/Notch` (with the app quit): drives the notch itself —
/// hover, open/close, every tab — and reports how long the main thread was blocked. A blocked main
/// thread is what you feel as lag: > 33 ms drops frames, > 100 ms is a visible stutter.
@MainActor
enum Bench {
    private static var last = CACurrentMediaTime()
    private static var gaps: [Double] = []

    /// `only`: "tabs" runs just tab switching (for profiling it with `sample`).
    static func run(_ m: NotchModel, only: String? = nil) {
        // 120 Hz probe in .common mode: it fires late exactly when the main thread was busy.
        let probe = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                gaps.append(now - last - 1.0 / 120); last = now
            }
        }
        RunLoop.main.add(probe, forMode: .common)

        var steps: [(String, Double, () -> Void)] = [("idle", 3, {})]
        if only == "look" {
            // Day/night check: can we read the screen behind the notch, and how bright is it?
            Task {
                let r = NotchController.shared?.panelFrame ?? .zero
                let lum = await Look.brightness(behind: r)
                let out = "access=\(CGPreflightScreenCaptureAccess()) rect=\(r) brightness=\(lum.map { String(format: "%.2f", $0) } ?? "nil")\n"
                try? out.write(toFile: NSTemporaryDirectory() + "notch-look.txt", atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
            }
            return
        }
        if only == "meeting" {
            // Live speech on the Meeting tab: a partial result every 100 ms, as the recogniser sends them.
            steps.append(("open meeting", 0.9, { m.show(.meeting) }))
            let words = "so tell me about a time you handled a difficult distributor and what the result was in numbers".split(separator: " ")
            for line in 0..<6 {
                let id = UUID()
                for n in 1...words.count {
                    steps.append(("speech", 0.1, { MeetingService.shared.apply(id, line % 2 == 0 ? "Them" : "Me", words.prefix(n).joined(separator: " "), n == words.count) }))
                }
            }
            steps.append(("close", 0.8, { m.setOpen(false) }))
            return go(steps)
        }
        if only == "tabs" {
            steps.append(("open", 0.9, { m.setOpen(true) }))
            for _ in 0..<4 { for t in Skin.visibleTabs { steps.append(("tabs", 0.35, { m.setTab(t) })) } }
            steps.append(("close", 0.8, { m.setOpen(false) }))
            return go(steps)
        }
        for _ in 0..<10 { steps += [("hover", 0.5, { m.setHovering(true) }), ("hover", 0.5, { m.setHovering(false) })] }
        for _ in 0..<8 { steps += [("open/close", 0.9, { m.setOpen(true) }), ("open/close", 0.7, { m.setOpen(false) })] }
        steps.append(("open/close", 0.9, { m.setOpen(true) }))
        for t in Skin.visibleTabs { steps.append(("tab " + t.title, 0.7, { m.setTab(t) })) }   // first visit: builds the tab
        for t in Skin.visibleTabs.reversed() { steps.append(("tabs again", 0.35, { m.setTab(t) })) }
        steps.append(("close", 0.8, { m.setOpen(false) }))
        go(steps)
    }

    private static func go(_ steps: [(String, Double, () -> Void)]) {
        var results: [(String, Int, Double, Int, Int, Double)] = []   // name, n, worst ms, >33, >100, cpu ms
        func cpu() -> Double {
            var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
        }
        var i = 0, c0 = cpu()
        func next() {
            if i > 0 {
                let name = steps[i - 1].0
                let worst = (gaps.max() ?? 0) * 1000
                let n33 = gaps.filter { $0 > 0.033 }.count, n100 = gaps.filter { $0 > 0.1 }.count
                let c = cpu()
                if let j = results.lastIndex(where: { $0.0 == name }), j == results.count - 1 {
                    let r = results[j]
                    results[j] = (name, r.1 + 1, max(r.2, worst), r.3 + n33, r.4 + n100, r.5 + c - c0)
                } else { results.append((name, 1, worst, n33, n100, c - c0)) }
                c0 = c
            }
            gaps = []; last = CACurrentMediaTime()
            guard i < steps.count else { report(results); return }
            let s = steps[i]; i += 1
            s.2()
            DispatchQueue.main.asyncAfter(deadline: .now() + s.1) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { next() }   // let launch work settle
    }

    private static func report(_ r: [(String, Int, Double, Int, Int, Double)]) {
        var out = String(format: "%-22@ %5@ %9@ %6@ %6@ %8@\n", "step" as NSString, "runs" as NSString, "worst ms" as NSString,
                         ">33ms" as NSString, ">100ms" as NSString, "cpu ms" as NSString)
        for (name, n, worst, n33, n100, c) in r {
            out += String(format: "%-22@ %5d %9.0f %6d %6d %8.0f\n", name as NSString, n, worst, n33, n100, c)
        }
        print(out, terminator: ""); fflush(stdout)
        NSApp.terminate(nil)
    }
}
