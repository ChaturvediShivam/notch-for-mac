import SwiftUI

struct NotesView: View {
    @ObservedObject private var svc = NotesService.shared

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 4) {
                Button { svc.add() } label: { Label("New note", systemImage: "plus").frame(maxWidth: .infinity) }
                    .buttonStyle(PillButtonStyle())
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(svc.notes) { n in
                            Text(n.title).font(Theme.caption).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).frame(height: 26)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(n.id == svc.selected ? Theme.control : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { svc.selected = n.id }
                                .contextMenu { Button("Delete") { svc.delete(n.id) } }
                        }
                    }
                }
            }
            .padding(8)
            .frame(width: 160)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))

            TextEditor(text: Binding(get: { svc.current?.text ?? "" }, set: { svc.update($0) }))
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
                .id(svc.selected)
        }
    }
}
