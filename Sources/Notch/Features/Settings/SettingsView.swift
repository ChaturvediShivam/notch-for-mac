import SwiftUI

struct SettingsView: View {
    @ObservedObject private var store = Store.shared
    @State private var watchlist = Store.shared.config.watchlist.joined(separator: ", ")
    @State private var leagues = Store.shared.config.leagues.joined(separator: ", ")
    @State private var message = ""
    @State private var loginItem = AppLifecycle.loginItemEnabled
    @State private var keepAlive = AppLifecycle.keepAliveEnabled
    @State private var axTrusted = AXIsProcessTrusted()

    private var c: Binding<Config> { $store.config }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
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
                        Text(Keychain.get("anthropic") != nil ? "API key saved in Keychain" : "No API key yet (add it in the Claude tab)")
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
                    toggle("Liquid Glass (macOS 26)", c.glass)
                    row("Transparency") {
                        Slider(value: c.opacity, in: 0.3...1).frame(width: 140)
                        Text("\(Int(store.config.opacity * 100))%").font(Theme.caption).monospacedDigit().frame(width: 36)
                    }
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
            .toggleStyle(.switch).controlSize(.mini)
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
