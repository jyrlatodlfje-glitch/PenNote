import SwiftUI

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var path: [UUID] = []
    @State private var renaming: Note?
    @State private var newName = ""

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
                    .contextMenu {
                        Button {
                            newName = note.title
                            renaming = note
                        } label: {
                            Label("제목 수정", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            store.delete(note.id)
                        } label: {
                            Label("삭제", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("제목 수정") {
                            newName = note.title
                            renaming = note
                        }
                        .tint(.blue)
                    }
                }
                .onDelete { store.delete(at: $0) }
            }
            .alert("노트 제목", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("제목", text: $newName)
                Button("저장") {
                    if let note = renaming {
                        store.rename(note.id, to: newName)
                    }
                }
                Button("취소", role: .cancel) {}
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
                if let note = store.notes.first(where: { $0.id == id }) {
                    NoteEditorView(note: note)
                }
            }
        }
    }
}
