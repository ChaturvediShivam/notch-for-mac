import SwiftUI

struct ToolsView: View {
    @ObservedObject private var tools = ToolsService.shared
    @ObservedObject private var voice = VoiceService.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Card(title: "Tools", trailing: AnyView(Text(tools.status).font(.system(size: 10)).foregroundStyle(.white.opacity(0.6)))) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    tool("Screenshot", "camera.viewfinder") { tools.screenshotToClipboard() }
                    tool("Copy text\nfrom screen", "text.viewfinder") { tools.ocrScreen() }
                    tool("Pick colour", "eyedropper") { tools.pickColor() }
                    tool("Lock screen", "lock.fill") { SystemControls.lockScreen() }
                    tool("Sleep display", "display") { SystemControls.sleepDisplay() }
                    tool("Empty Trash", "trash.fill") { SystemControls.emptyTrash() }
                    tool(tools.hiddenFiles ? "Hide hidden\nfiles" : "Show hidden\nfiles", "eye") { tools.toggleHiddenFiles() }
                    tool("Ask Claude\nabout screen", "sparkles") { ClaudeService.shared.askAboutScreen() }
                    tool("Palette", "magnifyingglass") { NotchModel.shared.openPalette() }
                }
            }
            .frame(width: 330)

            Card(title: "Voice") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button { voice.toggleDictation() } label: {
                            Label(voice.mode == .dictating ? "Stop" : "Dictate", systemImage: "mic.fill")
                        }
                        .buttonStyle(PillButtonStyle(tint: voice.mode == .dictating ? Theme.red : nil))
                        Button { voice.toggleListen() } label: {
                            Label(voice.mode == .listening ? "Stop" : "Listen", systemImage: "captions.bubble.fill")
                        }
                        .buttonStyle(PillButtonStyle(tint: voice.mode == .listening ? Theme.red : nil))
                    }
                    ScrollView {
                        Text(voice.finished + (voice.finished.isEmpty ? "" : " ") + voice.text)
                            .font(Theme.caption).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(voice.status.isEmpty ? "⌃⌥D dictates into any app · ⌃⌥L captions the Mac's audio" : voice.status)
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
    }

    private func tool(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                Text(name).font(.system(size: 10)).multilineTextAlignment(.center).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control.opacity(0.5)))
        }
        .buttonStyle(GlyphButtonStyle(radius: 10))
    }
}
