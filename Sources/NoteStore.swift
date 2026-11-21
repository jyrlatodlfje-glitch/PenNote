import Foundation
import CoreGraphics

enum PaperTemplate: String, Codable, CaseIterable {
    case blank, lined, grid

    var label: String {
        switch self {
        case .blank: return "무지"
        case .lined: return "줄노트"
        case .grid: return "모눈"
        }
    }
}

struct TextItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var x: CGFloat
    var y: CGFloat
    var text = ""
}

struct ImageItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var fileName: String
    /// 불러온 PDF의 쪽처럼 배경으로 고정된 이미지. 선택하거나 옮길 수 없다.
    var locked: Bool?
}

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var modified = Date()
    var template = PaperTemplate.lined
    /// PKDrawing 직렬화 데이터
    var drawing = Data()
    var texts: [TextItem] = []
    var images: [ImageItem] = []
    /// 사용자가 직접 정한 제목. 없으면 첫 줄을 제목으로 쓴다.
    var name: String?
    /// 들어 있는 폴더. nil이면 폴더 밖.
    var folderID: UUID?
    /// 불러온 PDF의 쪽이 끝나는 세로 위치들. PDF로 내보낼 때 같은 자리에서 쪽을 나눈다.
    var pageBreaks: [CGFloat]?
    /// 쪽 구분 없이 사방으로 넓게 쓰는 화이트보드인지
    var isWhiteboard: Bool?
    /// 만다라트 표. 있으면 이 노트는 만다라트 화면으로 연다.
    var mandala: MandalaBoard?
    /// 마인드맵. 있으면 이 노트는 마인드맵 화면으로 연다.
    var mindMap: MindNode?
    /// 노트를 만든 날짜·시각. 2026-11-15 전에 만든 노트에는 없다(그 노트는 예전처럼 본문 첫 줄이 제목).
    var created: Date? = Date()

    private static let dateTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM-dd (E) HH:mm"
        return formatter
    }()

    /// 제목을 넣지 않았을 때 쓰는 제목: "2026-11-15 (일) 14:30"
    var dateTitle: String? {
        created.map { Self.dateTitleFormatter.string(from: $0) }
    }

    var title: String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        if let mandala {
            let goal = mandala.cells.indices.contains(MandalaBoard.center) ? mandala.cells[MandalaBoard.center] : ""
            return goal.isEmpty ? "새 만다라트" : goal
        }
        if let mindMap {
            return mindMap.text.isEmpty ? "새 마인드맵" : mindMap.text
        }
        // 2026-11-15: 제목을 안 넣은 새 노트는 만든 날짜·시각이 제목이다.
        if let dateTitle {
            return dateTitle
        }
        let lines = texts
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .flatMap { $0.text.split(separator: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { !$0.isEmpty } ?? "새 노트"
    }
}

// MARK: - 검색 (2026-11-15)

extension Note {
    /// 검색할 글: 제목, 글상자, 만다라트 칸, 마인드맵 가지. 손으로 그린 필기와 사진 속 글자는 들어가지 않는다.
    private var searchableLines: [String] {
        var lines = [title]
        lines += texts.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .flatMap { $0.text.components(separatedBy: "\n") }
        if let mandala {
            lines += Self.cells(of: mandala)
        }
        if let mindMap {
            lines += Self.nodeTexts(of: mindMap)
        }
        return lines
    }

    private static func cells(of board: MandalaBoard) -> [String] {
        board.cells.filter { !$0.isEmpty } + board.children.values.flatMap { cells(of: $0) }
    }

    private static func nodeTexts(of node: MindNode) -> [String] {
        [node.text] + node.children.flatMap { nodeTexts(of: $0) }
    }

    func matches(_ query: String) -> Bool {
        searchableLines.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// 찾은 글이 든 줄 (제목이 아닌 본문에서). 목록에서 제목 아래에 보여 준다.
    func snippet(for query: String) -> String? {
        guard let line = searchableLines.dropFirst().first(where: { $0.localizedCaseInsensitiveContains(query) }) else {
            return nil
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 60 ? String(trimmed.prefix(60)) + "…" : trimmed
    }
}

struct Folder: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
}

final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []
    @Published private(set) var folders: [Folder] = []

    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let folder = NoteStore.documents.appendingPathComponent("Notes")
    private let foldersURL = NoteStore.documents.appendingPathComponent("folders.json")

    static func imageFolder(for noteID: UUID) -> URL {
        documents.appendingPathComponent("Images").appendingPathComponent(noteID.uuidString)
    }

    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        notes = files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Note.self, from: Data(contentsOf: $0)) }
            .sorted { $0.modified > $1.modified }
        if let data = try? Data(contentsOf: foldersURL),
           let saved = try? decoder.decode([Folder].self, from: data) {
            folders = saved
        }
    }

    func notes(in folderID: UUID?) -> [Note] {
        guard folderID == nil else { return notes.filter { $0.folderID == folderID } }
        // 맨 위 목록: 폴더 밖 노트 + 있던 폴더가 없어진 노트(folders.json이 깨졌거나, 불러오는 사이 폴더를 지운 경우).
        // 전엔 어느 목록에도 안 보이고 검색으로만 찾을 수 있었다(2026-11-21).
        let known = Set(folders.map { $0.id })
        return notes.filter { note in
            guard let id = note.folderID else { return true }
            return !known.contains(id)
        }
    }

    func addNote(in folderID: UUID? = nil, whiteboard: Bool = false) -> Note {
        var note = Note()
        note.folderID = folderID
        if whiteboard {
            note.isWhiteboard = true
            note.template = .blank
        }
        notes.insert(note, at: 0)
        write(note)
        return note
    }

    func addMandala(in folderID: UUID? = nil) -> Note {
        var note = Note()
        note.folderID = folderID
        note.mandala = MandalaBoard()
        add(note)
        return note
    }

    func addMindMap(in folderID: UUID? = nil) -> Note {
        var note = Note()
        note.folderID = folderID
        note.mindMap = MindNode()
        add(note)
        return note
    }

    func add(_ note: Note) {
        notes.insert(note, at: 0)
        write(note)
    }

    func move(_ noteID: UUID, to folderID: UUID?) {
        guard var note = notes.first(where: { $0.id == noteID }) else { return }
        note.folderID = folderID
        update(note)
    }

    func addFolder(named name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        folders.append(Folder(name: name))
        writeFolders()
    }

    func renameFolder(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        writeFolders()
    }

    /// 폴더만 지운다. 안에 있던 노트는 폴더 밖으로 나온다.
    func deleteFolder(_ id: UUID) {
        for note in notes(in: id) {
            move(note.id, to: nil)
        }
        folders.removeAll { $0.id == id }
        writeFolders()
    }

    private func writeFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: foldersURL, options: .atomic)
    }

    func update(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }), notes[index] != note else { return }
        if note.modified > notes[index].modified, index != 0 {
            // 고친 노트는 목록 맨 위로(앱을 다시 켤 때의 순서와 같게, 2026-11-21).
            notes.remove(at: index)
            notes.insert(note, at: 0)
        } else {
            notes[index] = note
        }
        write(note)
    }

    func rename(_ id: UUID, to name: String) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.name = name
        note.modified = Date()
        update(note)
    }

    // MARK: 열린 노트 화면 (2026-11-21)
    // 노트 화면은 열 때 받은 노트 사본을 들고 있다가, 무엇이든 고치면 그 사본을 통째로 저장한다.
    // 그래서 열려 있는 노트에 밖에서(녹음을 다시 받아 적은 글 등) 저장소에만 글을 넣으면,
    // 다음 손질 때 옛 사본이 덮어써 그 글이 사라진다. 열려 있으면 그 화면의 종이에 넣는다.

    private struct OpenPage {
        weak var page: PageController?
    }
    private var openPages: [UUID: OpenPage] = [:]

    /// 열린 화면이 없어 저장소에만 넣은 글. 노트 화면이 막 만들어지는 틈(사본은 옛것인데 아직
    /// 등록 전)에 들어왔을 수 있으므로, 화면이 붙으면 그 종이에도 한 번 더 넣는다(이미 있으면 건너뜀).
    private enum PendingEdit {
        case replace(old: String, new: String, header: String)
        case append(String)
    }
    private var pendingEdits: [UUID: [PendingEdit]] = [:]

    /// 노트 화면이 열릴 때 부른다.
    func attach(_ page: PageController, to id: UUID) {
        openPages[id] = OpenPage(page: page)
        page.onViewReady = { [weak self, weak page] in
            guard let self, let page else { return }
            self.replayPending(id, on: page)
        }
        if page.isAttached {
            replayPending(id, on: page)
        }
    }

    private func replayPending(_ id: UUID, on page: PageController, tries: Int = 0) {
        guard page.isAttached, pendingEdits[id] != nil else { return }
        // 종이가 아직 자리를 잡기 전(폭 0)이면 맨 아래를 잘못 재어 글이 맨 위에 겹치므로 잠깐 뒤 다시(최대 약 2초).
        if !page.isLaidOut, tries < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak page] in
                guard let self, let page else { return }
                self.replayPending(id, on: page, tries: tries + 1)
            }
            return
        }
        guard let edits = pendingEdits.removeValue(forKey: id) else { return }
        for edit in edits {
            switch edit {
            case let .replace(old, new, header):
                if page.containsText(new) || page.containsText(header + new) { continue }
                if !page.replaceText(old, with: new) {
                    page.appendBlock(header + new, follow: false)
                }
            case let .append(text):
                if !page.containsText(text) {
                    page.appendBlock(text, follow: false)
                }
            }
        }
    }

    /// 노트 화면이 닫힐 때 부른다. 그사이 같은 노트를 다시 연 화면이 있으면 그것은 그대로 둔다.
    func detach(_ page: PageController, from id: UUID) {
        if openPages[id]?.page === page {
            openPages[id] = nil
        }
    }

    /// 지금 이 노트를 보여 주는 종이(없으면 nil).
    func openPage(for id: UUID) -> PageController? {
        guard let page = openPages[id]?.page, page.isAttached else { return nil }
        return page
    }

    /// 노트 안에서 글 `old` 와 꼭 같은 글상자를 `new` 로 바꾼다. 그런 글상자가 없으면
    /// (회원님이 그새 고쳤으면) 지우지 않고 `header` + `new` 를 맨 아래에 덧붙인다.
    func replaceText(_ old: String, with new: String, orAppendWith header: String, in id: UUID) {
        if let page = openPage(for: id) {
            if !page.replaceText(old, with: new) {
                page.appendBlock(header + new, follow: false)
            }
            return
        }
        guard var note = notes.first(where: { $0.id == id }) else { return }
        guard let index = note.texts.firstIndex(where: { $0.text == old }) else {
            appendText(header + new, to: id)
            return
        }
        pendingEdits[id, default: []].append(.replace(old: old, new: new, header: header))
        note.texts[index].text = new
        note.modified = Date()
        update(note)
    }

    /// 노트의 맨 아래에 글상자를 하나 덧붙인다 (음성 입력을 녹음으로 다시 받아 적은 글).
    /// 그 노트가 화면에 열려 있으면 그 종이에 넣는다(보던 자리는 지킴).
    func appendText(_ text: String, to id: UUID) {
        if let page = openPage(for: id) {
            page.appendBlock(text, follow: false)
            return
        }
        guard var note = notes.first(where: { $0.id == id }) else { return }
        pendingEdits[id, default: []].append(.append(text))
        let line = PageCanvasView.lineHeight
        let textBottom = note.texts.map { $0.y + CGFloat($0.text.components(separatedBy: "\n").count + 2) * line }.max() ?? 0
        let imageBottom = note.images.map { $0.y + $0.height }.max() ?? 0
        note.texts.append(TextItem(x: 16, y: max(textBottom, imageBottom) + line * 1.5, text: text))
        note.modified = Date()
        update(note)
    }

    func delete(_ id: UUID) {
        if let index = notes.firstIndex(where: { $0.id == id }) {
            delete(at: IndexSet(integer: index))
        }
    }

    func delete(at offsets: IndexSet) {
        for index in offsets {
            let id = notes[index].id
            pendingEdits[id] = nil
            openPages[id] = nil
            try? FileManager.default.removeItem(at: fileURL(id))
            try? FileManager.default.removeItem(at: Self.imageFolder(for: id))
            try? FileManager.default.removeItem(at: AudioRecorder.folder(for: id))
        }
        notes.remove(atOffsets: offsets)
    }

    private func fileURL(_ id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString + ".json")
    }

    private func write(_ note: Note) {
        guard let data = try? JSONEncoder().encode(note) else { return }
        try? data.write(to: fileURL(note.id), options: .atomic)
    }
}
