import SwiftUI
import UniformTypeIdentifiers

enum Route: Hashable {
    case folder(UUID)
    case note(UUID)
}

struct NoteListView: View {
    @EnvironmentObject private var store: NoteStore
    @ObservedObject private var voiceMemo = VoiceMemoCenter.shared
    @State private var path: [Route] = []

    var body: some View {
        navigation
            // 음성 메모는 ＋ 메뉴에서든 단축어에서든 시작하면 이 화면이 뜨고, 저장하면 그 노트를 연다.
            .sheet(isPresented: Binding(get: { voiceMemo.memo != nil }, set: { _ in }), onDismiss: {
                if let id = voiceMemo.savedNoteID {
                    voiceMemo.savedNoteID = nil
                    path.append(.note(id))
                }
            }) {
                if let memo = voiceMemo.memo {
                    VoiceMemoView(memo: memo)
                }
            }
    }

    private var navigation: some View {
        NavigationStack(path: $path) {
            NoteBrowser(folderID: nil, path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .folder(let id):
                        NoteBrowser(folderID: id, path: $path)
                    case .note(let id):
                        if let note = store.notes.first(where: { $0.id == id }) {
                            if note.mandala != nil {
                                MandalaEditorView(note: note)
                            } else if note.mindMap != nil {
                                MindMapEditorView(note: note)
                            } else {
                                NoteEditorView(note: note)
                            }
                        }
                    }
                }
        }
    }
}

/// 폴더 하나(또는 폴더 밖)의 노트 목록. 맨 위 화면에서는 폴더 목록도 함께 보여준다.
struct NoteBrowser: View {
    let folderID: UUID?
    @Binding var path: [Route]

    @EnvironmentObject private var store: NoteStore
    @State private var prompt: Prompt?
    @State private var showPrompt = false
    @State private var promptText = ""
    @State private var showPDFImporter = false
    @State private var showScanner = false
    /// 책 스캔: 두 쪽 나누기, 손가락 지우기, 휜 글줄 펴기를 거친다.
    @State private var bookMode = false
    @State private var importing = false
    @State private var importFailed = false

    enum Prompt {
        case newFolder
        case renameFolder(Folder)
        case renameNote(Note)

        var title: String {
            switch self {
            case .newFolder: return "새 폴더"
            case .renameFolder: return "폴더 이름"
            case .renameNote: return "노트 제목"
            }
        }

        /// 입력 칸이 비었을 때 보이는 글
        var placeholder: String {
            switch self {
            case .renameNote(let note):
                return "비워 두면 " + (note.dateTitle ?? "본문 첫 줄")
            default:
                return "이름"
            }
        }
    }

    /// 검색어. 있으면 폴더와 상관없이 모든 노트에서 찾는다.
    @State private var query = ""
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !trimmedQuery.isEmpty }

    private var notes: [Note] {
        searching ? store.notes.filter { $0.matches(trimmedQuery) } : store.notes(in: folderID)
    }
    private var showsFolders: Bool { folderID == nil && !store.folders.isEmpty && !searching }

    var body: some View {
        List {
            if showsFolders {
                Section("폴더") {
                    ForEach(store.folders) { folder in
                        folderRow(folder)
                    }
                }
            }
            Section {
                ForEach(notes) { note in
                    noteRow(note)
                }
                .onDelete { offsets in
                    offsets.map { notes[$0].id }.forEach { store.delete($0) }
                }
            } header: {
                if showsFolders {
                    Text("노트")
                }
            }
        }
        .overlay {
            if notes.isEmpty && !showsFolders {
                Text(searching ? "찾는 글이 든 노트가 없습니다" : "오른쪽 위 + 를 눌러 노트를 만드세요")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(store.folders.first { $0.id == folderID }?.name ?? "펜노트")
        // 2026-11-15: 모든 노트 검색 (제목·글자·만다라트·마인드맵. 손필기 그림은 못 찾음)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "제목·글자 검색")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if folderID == nil {
                    Button {
                        ask(.newFolder, text: "")
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
                Menu {
                    Button {
                        path.append(.note(store.addNote(in: folderID).id))
                    } label: {
                        Label("노트", systemImage: "note.text")
                    }
                    Button {
                        VoiceMemoCenter.shared.start(folderID: folderID)
                    } label: {
                        Label("음성 메모", systemImage: "waveform")
                    }
                    Button {
                        path.append(.note(store.addNote(in: folderID, whiteboard: true).id))
                    } label: {
                        Label("화이트보드", systemImage: "rectangle.dashed")
                    }
                    Button {
                        path.append(.note(store.addMandala(in: folderID).id))
                    } label: {
                        Label("만다라트 표", systemImage: "square.grid.3x3")
                    }
                    Button {
                        path.append(.note(store.addMindMap(in: folderID).id))
                    } label: {
                        Label("마인드맵", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    Button {
                        showPDFImporter = true
                    } label: {
                        Label("PDF 불러오기", systemImage: "doc")
                    }
                    if DocumentScanner.isSupported {
                        Button {
                            bookMode = false
                            showScanner = true
                        } label: {
                            Label("문서 스캔", systemImage: "doc.viewfinder")
                        }
                        Button {
                            bookMode = true
                            showScanner = true
                        } label: {
                            Label("책 스캔", systemImage: "book")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(importing)
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { pages in
                importScan(pages)
            }
            .ignoresSafeArea()
        }
        .overlay {
            if importing {
                ProgressView("불러오는 중")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            importPDF(url)
        }
        .alert("불러오지 못했습니다", isPresented: $importFailed) {
            Button("확인", role: .cancel) {}
        }
        .alert(prompt?.title ?? "", isPresented: $showPrompt) {
            TextField(prompt?.placeholder ?? "이름", text: $promptText)
            Button("저장") { confirmPrompt() }
            Button("취소", role: .cancel) {}
        }
    }

    private func folderRow(_ folder: Folder) -> some View {
        NavigationLink(value: Route.folder(folder.id)) {
            Label(folder.name, systemImage: "folder")
        }
        .badge(store.notes(in: folder.id).count)
        // 노트를 길게 눌러 끌어다 놓으면 이 폴더로 옮긴다.
        .dropDestination(for: String.self) { items, _ in
            guard let noteID = items.first.flatMap({ UUID(uuidString: $0) }) else { return false }
            store.move(noteID, to: folder.id)
            return true
        }
        .contextMenu {
            Button {
                ask(.renameFolder(folder), text: folder.name)
            } label: {
                Label("이름 수정", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.deleteFolder(folder.id)
            } label: {
                Label("폴더 삭제 (노트는 남김)", systemImage: "trash")
            }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        NavigationLink(value: Route.note(note.id)) {
            HStack(spacing: 12) {
                Image(systemName: icon(for: note))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .lineLimit(1)
                    if searching, let snippet = note.snippet(for: trimmedQuery) {
                        Text(snippet)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }
                    Text(note.modified, style: .date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                // 2026-11-15: 제목은 목록에서 넣는다. 안 넣으면 만든 날짜·시각이 제목.
                Button {
                    ask(.renameNote(note), text: note.name ?? "")
                } label: {
                    Image(systemName: "pencil")
                        .foregroundColor(.accentColor)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("제목 수정")
            }
        }
        .draggable(note.id.uuidString)
        .contextMenu {
            Button {
                ask(.renameNote(note), text: note.name ?? "")
            } label: {
                Label("제목 수정", systemImage: "pencil")
            }
            Menu {
                if note.folderID != nil {
                    Button("폴더 밖으로") { store.move(note.id, to: nil) }
                }
                ForEach(store.folders.filter { $0.id != note.folderID }) { folder in
                    Button(folder.name) { store.move(note.id, to: folder.id) }
                }
            } label: {
                Label("폴더로 이동", systemImage: "folder")
            }
            Button(role: .destructive) {
                store.delete(note.id)
            } label: {
                Label("삭제", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button("제목 수정") {
                ask(.renameNote(note), text: note.name ?? "")
            }
            .tint(.blue)
        }
    }

    private func icon(for note: Note) -> String {
        if note.mandala != nil { return "square.grid.3x3" }
        if note.mindMap != nil { return "point.3.connected.trianglepath.dotted" }
        return note.isWhiteboard == true ? "rectangle.dashed" : "note.text"
    }

    private func importPDF(_ url: URL) {
        importing = true
        let pageWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let folderID = folderID
        Task.detached {
            let note = PDFImporter.makeNote(from: url, pageWidth: pageWidth, folderID: folderID)
            await MainActor.run {
                importing = false
                if let note {
                    store.add(note)
                    path.append(.note(note.id))
                } else {
                    importFailed = true
                }
            }
        }
    }

    private func importScan(_ pages: [UIImage]) {
        guard !pages.isEmpty else { return }
        importing = true
        let pageWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let folderID = folderID
        let bookMode = bookMode
        let held = DocumentScanner.heldOrientation
        Task.detached {
            let fixed = bookMode
                ? pages.flatMap { BookScan.process($0, held: held) }
                : pages.map { BookScan.orient($0, held: held) }
            let note = ScanImporter.makeNote(from: fixed, pageWidth: pageWidth, folderID: folderID)
            await MainActor.run {
                importing = false
                if let note {
                    store.add(note)
                    path.append(.note(note.id))
                } else {
                    importFailed = true
                }
            }
        }
    }

    private func ask(_ prompt: Prompt, text: String) {
        promptText = text
        self.prompt = prompt
        showPrompt = true
    }

    private func confirmPrompt() {
        switch prompt {
        case .newFolder:
            store.addFolder(named: promptText)
        case .renameFolder(let folder):
            store.renameFolder(folder.id, to: promptText)
        case .renameNote(let note):
            store.rename(note.id, to: promptText)
        case nil:
            break
        }
    }
}
