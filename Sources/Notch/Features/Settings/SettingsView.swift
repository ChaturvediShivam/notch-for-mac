import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = Store.shared
    @State private var watchlist = Store.shared.config.watchlist.joined(separator: ", ")
    @State private var leagues = Store.shared.config.leagues.joined(separator: ", ")
    @State private var message = ""
    @State private var loginItem = AppLifecycle.loginItemEnabled
    @State private var keepAlive = AppLifecycle.keepAliveEnabled
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var aiKey = ""
    @State private var confirmWipe = false
    /// Read once: a Keychain lookup on every redraw made Settings stutter.
    @State private var savedKeys = Set(ClaudeRunner.providers.map(\.id).filter { Keychain.get(ClaudeRunner.keyName($0)) != nil })
    @State private var anthropicSaved = Keychain.get("anthropic") != nil

    private var c: Binding<Config> { $store.config }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                group(Skin.isMaster ? "Look · master edition" : "Look") { look }

                group("Privacy · data on this Mac") { dataControls }

                group("Privacy · network features") {
                    toggle("Synced lyrics (lrclib.net)", c.netLyrics)
                    toggle("Weather (open-meteo.com)", c.netWeather)
                    toggle("Markets (Yahoo Finance)", c.netMarkets)
                    toggle("Scores (ESPN)", c.netScores)
                    toggle("Claude tab (Claude Code or api.anthropic.com)", c.netClaude)
                    toggle("Local API on 127.0.0.1:\(store.config.apiPort) (alerts, Claude Code hooks)", Binding(
                        get: { store.config.netLocalAPI },
                        set: { store.config.netLocalAPI = $0; LocalServer.shared.start() }))
                }

                group("Meeting answers · use your own AI") { meetingAI }

                group("Weather") {
                    row("City") { field("e.g. Mumbai", c.city) }
                    toggle("Use my location instead (asks for Location permission)", c.useLocation)
                    toggle("Celsius", c.celsius)
                }

                group("Markets & scores") {
                    row("Watchlist") {
                        field("AAPL, ^GSPC, BTC-USD", $watchlist) {
                            store.config.watchlist = watchlist.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
                        }
                    }
                    row("Leagues") {
                        field("soccer/eng.1, basketball/nba", $leagues) {
                            store.config.leagues = leagues.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                    }
                    Text("Leagues are ESPN paths: soccer/eng.1, soccer/esp.1, soccer/uefa.champions, basketball/nba, football/nfl, baseball/mlb, hockey/nhl")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                }

                group("Claude") {
                    row("Backend") { BackendSwitch() }
                    if store.config.claudeBackend == "api" {
                        row("API model") { field("claude-opus-5-5", c.claudeAPIModel) }
                        Text(anthropicSaved ? "API key saved in Keychain" : "No API key yet (add it in the Claude tab)")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    } else {
                        row("Model") { field("Claude Code default (e.g. opus, sonnet)", c.claudeModel) }
                        row("Folder") { field("~ (home)", c.claudeCwd) }
                    }
                    HStack {
                        Text(ClaudeService.shared.claudePath.map { "Using \($0)" } ?? "Claude Code not found")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        Spacer()
                        Button("Copy local API token") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(LocalServer.token, forType: .string)
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }

                group("Permissions") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-paste (Accessibility)").font(Theme.caption)
                            Text("Lets dictation and clipboard paste press ⌘V for you. Without it, text is copied and you paste.")
                                .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        if axTrusted { Text("On").font(Theme.caption).foregroundStyle(Theme.green) }
                        else {
                            Button("Allow…") {
                                let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                                axTrusted = AXIsProcessTrustedWithOptions(opts)
                            }
                            .buttonStyle(PillButtonStyle())
                        }
                    }
                    Text("Other permissions are asked only when you first use the feature: Microphone + Speech (Dictate), Screen Recording (Listen, screenshot ask), Camera (Mirror), Calendar (Today), Location (if turned on above), Automation (Dark mode, Empty Trash).")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }

                group("Hotkeys") {
                    ForEach(Hotkeys.shared.registered, id: \.self) { h in
                        Text(h).font(.system(size: 11, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(Hotkeys.shared.failed, id: \.self) { h in
                        Text("\(h)  (taken by another app)").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                group("App") {
                    toggle("Open at login", Binding(get: { loginItem }, set: { on in
                        message = AppLifecycle.setLoginItem(on) ?? ""
                        loginItem = AppLifecycle.loginItemEnabled
                    }))
                    toggle("Restart Notch if it crashes", Binding(get: { keepAlive }, set: { on in
                        Task {
                            message = await AppLifecycle.setKeepAlive(on) ?? ""
                            keepAlive = AppLifecycle.keepAliveEnabled
                        }
                    }))
                    toggle("Switch sound to earphones/headphones when they're plugged in", c.autoSwitchOutput)
                    row("Clipboard history") {
                        Stepper("\(store.config.clipboardLimit) items", value: c.clipboardLimit, in: 10...500, step: 10)
                            .font(Theme.caption)
                    }
                    HStack {
                        Text("Notch \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                            .font(Theme.caption).foregroundStyle(.white.opacity(0.5))
                        Spacer()
                        Button("Open data folder") { NSWorkspace.shared.open(Paths.home) }.buttonStyle(PillButtonStyle())
                        Button("Quit Notch") { NSApp.terminate(nil) }.buttonStyle(PillButtonStyle(tint: Theme.red))
                    }
                    if !message.isEmpty { Text(message).font(.system(size: 10)).foregroundStyle(Theme.orange) }
                }
            }
        }
        .onAppear { axTrusted = AXIsProcessTrusted() }
    }

    /// Themes, glow, glass, which tabs show. The store edition can't hide the core tabs or pick custom colours.
    @ViewBuilder private var look: some View {
        HStack(spacing: 10) {
            ForEach(Skin.available) { k in
                Button { store.config.theme = k.id } label: {
                    VStack(spacing: 4) {
                        ZStack {
                            Circle().fill(k.tint.isEmpty ? AnyShapeStyle(Color.black)
                                          : AnyShapeStyle(LinearGradient(colors: k.tint, startPoint: .top, endPoint: .bottom)))
                            Circle().strokeBorder(AngularGradient(colors: k.glow, center: .center), lineWidth: 1.5)
                            Image(systemName: k.mark.isEmpty ? "circle.fill" : k.mark)
                                .font(.system(size: k.mark.isEmpty ? 6 : 11, weight: .semibold)).foregroundStyle(k.accent)
                        }
                        .frame(width: 34, height: 34)
                        .overlay(Circle().strokeBorder(.white, lineWidth: store.config.theme == k.id ? 2 : 0).padding(-3))
                        Text(k.name).font(.system(size: 10)).foregroundStyle(.white.opacity(store.config.theme == k.id ? 1 : 0.55))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        toggle("Edge glow and hover glow", c.edgeGlow)
        toggle("Liquid Glass (macOS 26)", c.glass)
        row("Transparency") {
            Slider(value: c.opacity, in: 0.3...1).frame(width: 140)
            Text("\(Int(store.config.opacity * 100))%").font(Theme.caption).monospacedDigit().frame(width: 36)
        }
        if Skin.isMaster {
            row("Accent colour") { field("hex, e.g. C9D1D9 (empty = theme)", c.accentHex) }
            row("Background") { field("hex, e.g. 1F3A2B (empty = theme)", c.tintHex) }
        }
        Text("Tabs (tap to hide or show)" + (Skin.isMaster ? "" : " · Home, Meeting, Media and Settings always stay"))
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        HStack(spacing: 2) {
            ForEach(NotchTab.allCases) { t in
                let hidden = store.config.hiddenTabs.contains(t.title) && Skin.canHide(t)
                Button {
                    if hidden { store.config.hiddenTabs.removeAll { $0 == t.title } } else { store.config.hiddenTabs.append(t.title) }
                } label: {
                    Image(systemName: t.symbol)
                        .font(.system(size: 11)).frame(width: 26, height: 24)
                        .overlay(alignment: .bottomTrailing) {
                            if !Skin.canHide(t) { Image(systemName: "lock.fill").font(.system(size: 6)).foregroundStyle(.white.opacity(0.6)).padding(2) }
                        }
                        .foregroundStyle(hidden ? .white.opacity(0.25) : .white)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hidden ? .clear : Theme.control))
                }
                .buttonStyle(.plain).disabled(!Skin.canHide(t)).help(t.title)
            }
        }
    }

    /// How long things stay, and erase-everything (DPDP / GDPR: storage limits, right to erasure).
    @ViewBuilder private var dataControls: some View {
        row("Clipboard history") { daysMenu(c.clipDays, [1, 7, 30]) }
        row("Alerts") { daysMenu(c.alertDays, [7, 30, 90]) }
        row("Kept meetings") { daysMenu(c.keptDays, [0, 30, 90, 365]) }
        Text("Unkept meetings delete after 24 h, Listen after 7 days, screenshots after 1 day, logs after 7 days. Pinned clips and notes stay until you remove them. Everything stays on this Mac; nothing is sent to us.")
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
        HStack {
            Button("Open data folder") { NSWorkspace.shared.open(Paths.home) }.buttonStyle(PillButtonStyle())
            Spacer()
            Button(confirmWipe ? "Tap again to erase everything" : "Delete all my data") {
                if confirmWipe { Retention.deleteAll(); confirmWipe = false; message = "All your data was deleted" }
                else {
                    confirmWipe = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirmWipe = false }
                }
            }
            .buttonStyle(PillButtonStyle(tint: Theme.red))
            .help("Transcripts (kept too), clipboard, alerts, notes, Listen, screenshots, logs, web cache, meeting context. Settings and API keys stay.")
        }
    }

    private func daysMenu(_ b: Binding<Int>, _ options: [Int]) -> some View {
        func label(_ d: Int) -> String { d == 0 ? "Until I delete them" : d == 1 ? "1 day" : "\(d) days" }
        return Menu(label(b.wrappedValue)) {
            ForEach(options, id: \.self) { d in Button(label(d)) { b.wrappedValue = d; Retention.run() } }
        }
        .menuStyle(.borderlessButton).font(Theme.caption).fixedSize()
    }

    /// Bring your own model: pay with credits you already have, nothing billed by this app.
    @ViewBuilder private var meetingAI: some View {
        let id = store.config.meetingAI
        let p = ClaudeRunner.providers.first { $0.id == id } ?? ClaudeRunner.providers[0]
        row("AI") {
            Menu(p.name) {
                ForEach(ClaudeRunner.providers, id: \.id) { q in
                    Button { store.config.meetingAI = q.id; aiKey = "" } label: {
                        if q.id == id { Label(q.name, systemImage: "checkmark") } else { Text(q.name) }
                    }
                }
            }
            .menuStyle(.borderlessButton).font(Theme.caption).fixedSize()
            Spacer()
        }
        if id != "claude" {
            if id == "custom" { row("Base URL") { field("https://openrouter.ai/api/v1", c.aiBaseURL) } }
            row("Model") {
                field(p.hint, Binding(get: { store.config.aiModels[id] ?? "" },
                                      set: { store.config.aiModels[id] = $0 }))
            }
            if p.needsKey {
                let saved = savedKeys.contains(id)
                row("API key") {
                    SecureField(saved ? "Saved in Keychain" : "Paste key", text: $aiKey)
                        .textFieldStyle(.plain).font(Theme.caption)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
                    if !aiKey.isEmpty {
                        Button("Save") {
                            Keychain.set(ClaudeRunner.keyName(id), aiKey.trimmingCharacters(in: .whitespacesAndNewlines))
                            aiKey = ""; savedKeys.insert(id)
                        }.buttonStyle(PillButtonStyle(tint: Theme.accent))
                    } else if saved {
                        Button("Remove") { Keychain.set(ClaudeRunner.keyName(id), nil); savedKeys.remove(id) }.buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
        Text(id == "claude" ? "Uses your Claude Code login or Anthropic key (Claude section above)."
             : !p.cli.isEmpty ? "Uses your \(p.cli) login (your subscription, no API key). Install it and sign in once in Terminal; answers arrive whole, a few seconds slower than an API."
             : id == "ollama" ? "Runs on this Mac with Ollama: free and offline, but slower than cloud models. Run `ollama pull <model>` first."
             : "Your key, your credits: requests go straight from this Mac to the provider. Keys stay in the Keychain.")
            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
    }

    private func group<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
    }

    private func toggle(_ label: String, _ b: Binding<Bool>) -> some View {
        Toggle(isOn: b) { Text(label).font(Theme.caption) }
            .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<V: View>(_ label: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack {
            Text(label).font(Theme.caption).frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>, onCommit: (() -> Void)? = nil) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(Theme.caption)
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.control))
            .onChange(of: text.wrappedValue) { _ in onCommit?() }
    }
}
