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
        notes.filter { $0.folderID == folderID }
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
        notes[index] = note
        write(note)
    }

    func rename(_ id: UUID, to name: String) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.name = name
        note.modified = Date()
        update(note)
    }

    /// 열려 있지 않은 노트의 맨 아래에 글상자를 하나 덧붙인다 (음성 입력을 녹음으로 다시 받아 적은 글).
    func appendText(_ text: String, to id: UUID) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
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
