import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id = UUID()
    var body = ""
    var modified = Date()

    var title: String {
        let firstLine = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        if let firstLine, !firstLine.isEmpty { return firstLine }
        return "새 노트"
    }
}

final class NoteStore: ObservableObject {
    @Published var notes: [Note] = [] {
        didSet { save() }
    }

    private let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("notes.json")

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Note].self, from: data) {
            notes = saved
        }
    }

    func addNote() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        return note
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
