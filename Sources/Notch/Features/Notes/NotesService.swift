import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var text = ""
    var updated = Date()
    var title: String {
        let first = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return first.isEmpty ? "New note" : String(first.prefix(40))
    }
}

@MainActor
final class NotesService: ObservableObject {
    static let shared = NotesService()

    @Published var notes: [Note] = DataFile.load("notes.json", as: [Note].self) ?? [Note()]
    @Published var selected: UUID?
    private var saveWork: DispatchWorkItem?

    private init() { selected = notes.first?.id }

    var current: Note? { notes.first { $0.id == selected } }

    func update(_ text: String) {
        guard let i = notes.firstIndex(where: { $0.id == selected }), notes[i].text != text else { return }
        notes[i].text = text; notes[i].updated = Date()
        saveSoon()
    }

    func add() { let n = Note(); notes.insert(n, at: 0); selected = n.id; saveSoon() }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        if notes.isEmpty { notes = [Note()] }
        if selected == id { selected = notes.first?.id }
        saveSoon()
    }

    private func saveSoon() {
        saveWork?.cancel()
        let w = DispatchWorkItem { DataFile.save("notes.json", NotesService.shared.notes) }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }
}
