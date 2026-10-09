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

    var title: String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name
        }
        let lines = texts
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .flatMap { $0.text.split(separator: "\n") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { !$0.isEmpty } ?? "새 노트"
    }
}

final class NoteStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private let folder = NoteStore.documents.appendingPathComponent("Notes")

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
    }

    func addNote() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        write(note)
        return note
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
