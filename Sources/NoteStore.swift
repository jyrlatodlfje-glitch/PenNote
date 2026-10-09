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

    var title: String {
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
