import SwiftUI

struct NoteEditorView: View {
    @Binding var note: Note

    @StateObject private var recognizer = InkRecognizer()
    @StateObject private var editor = EditorController()
    @StateObject private var pad = PadController()

    @State private var useKeyboard = false
    @State private var lastInserted = ""
    @State private var alternatives: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            NoteTextView(text: $note.body, controller: editor, useKeyboard: useKeyboard)

            if !useKeyboard {
                Divider()
                statusBar
                InkPad(controller: pad, onIdle: recognize)
                    .frame(height: 220)
                keyRow
            }
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    useKeyboard.toggle()
                } label: {
                    Image(systemName: useKeyboard ? "pencil.line" : "keyboard")
                }
            }
        }
        .onChange(of: note.body) { _ in
            note.modified = Date()
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        Group {
            switch recognizer.state {
            case .downloading:
                Text("인식 모델을 내려받는 중입니다 (언어별 최초 1회)")
                    .foregroundColor(.secondary)
            case .failed(let message):
                Text(message)
                    .foregroundColor(.red)
            case .ready:
                if alternatives.isEmpty {
                    Text("아래 칸에 쓰고 잠시 멈추면 글자로 바뀝니다")
                        .foregroundColor(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(alternatives, id: \.self) { candidate in
                                Button(candidate) { choose(candidate) }
                                    .buttonStyle(.bordered)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, minHeight: 40)
    }

    private var keyRow: some View {
        HStack(spacing: 0) {
            key(text: recognizer.language.label) {
                recognizer.language = recognizer.language == .korean ? .english : .korean
                pad.clear()
            }
            key(icon: "arrow.uturn.backward") { pad.undoLastStroke() }
            key(icon: "space") { type(" ") }
            key(icon: "delete.left") {
                editor.backspace()
                alternatives = []
            }
            key(icon: "return") { type("\n") }
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    private func key(text: String? = nil, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let icon {
                    Image(systemName: icon)
                } else {
                    Text(text ?? "").fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
    }

    private func type(_ string: String) {
        editor.insert(string)
        alternatives = []
    }

    private func recognize(_ strokes: [[StrokeSample]]) {
        recognizer.recognize(strokes) { texts in
            guard let best = texts.first else { return }
            editor.insert(best)
            lastInserted = best
            alternatives = Array(texts.dropFirst().prefix(5))
        }
    }

    private func choose(_ candidate: String) {
        guard editor.replaceBeforeCursor(lastInserted, with: candidate) else {
            alternatives = []
            return
        }
        alternatives = alternatives.map { $0 == candidate ? lastInserted : $0 }
        lastInserted = candidate
    }
}
