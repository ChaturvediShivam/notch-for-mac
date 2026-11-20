import SwiftUI
import UniformTypeIdentifiers

struct ShelfView: View {
    @ObservedObject private var svc = ShelfService.shared
    @State private var targeted = false

    var body: some View {
        Card(title: "Shelf", trailing: AnyView(HStack(spacing: 6) {
            if !svc.status.isEmpty { Text(svc.status).font(.system(size: 11)).foregroundStyle(Theme.ink.opacity(0.6)) }
            Button("AirDrop all") { svc.airDrop(svc.items) }.buttonStyle(PillButtonStyle()).disabled(svc.items.isEmpty)
            Button("Clear") { svc.clear() }.buttonStyle(PillButtonStyle()).disabled(svc.items.isEmpty)
        })) {
            Group {
                if svc.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 26)).foregroundStyle(Theme.ink.opacity(0.5))
                        Text("Drop files here to hold them. Drag them out to any app.").font(Theme.caption)
                            .foregroundStyle(Theme.ink.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(svc.items, id: \.self) { u in item(u) }
                        }
                        .padding(4)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : .clear, style: StrokeStyle(lineWidth: 2, dash: [6])))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { ShelfService.shared.add([url]) } }
                    }
                }
                return true
            }
        }
    }

    private func item(_ u: URL) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: u.path)).resizable().frame(width: 52, height: 52)
            Text(u.lastPathComponent).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
        }
        .frame(width: 84, height: 96)
        .background(HoverFill(radius: 10))
        .onDrag { NSItemProvider(contentsOf: u) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(u) }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(u) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            Button("AirDrop") { svc.airDrop([u]) }
            if ShelfService.isImage(u) { Button("Copy text (OCR)") { svc.ocr(u) } }
            Button("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.path, forType: .string) }
            Divider()
            Button("Remove from Shelf") { svc.remove(u) }
        }
    }
}
