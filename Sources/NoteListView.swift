import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var path: [UUID] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                ForEach(store.notes) { note in
                    NavigationLink(value: note.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title)
                                .lineLimit(1)
                            Text(note.modified, style: .date)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { store.notes.remove(atOffsets: $0) }
            }
            .overlay {
                if store.notes.isEmpty {
                    Text("오른쪽 위 + 를 눌러 노트를 만드세요")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("펜노트")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        path.append(store.addNote().id)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let index = store.notes.firstIndex(where: { $0.id == id }) {
                    NoteEditorView(note: $store.notes[index])
                }
            }
        }
    }
}
