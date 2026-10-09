import PhotosUI
import SwiftUI

enum InkColor: String, CaseIterable, Identifiable {
    case black, red, blue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .black: return "검정"
        case .red: return "빨강"
        case .blue: return "파랑"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .black: return .black
        case .red: return .systemRed
        case .blue: return .systemBlue
        }
    }
}

struct NoteEditorView: View {
    @EnvironmentObject private var store: NoteStore

    @StateObject private var recognizer = InkRecognizer()
    @StateObject private var page = PageController()
    @StateObject private var pad = PadController()
    @StateObject private var audio: AudioRecorder

    @State private var note: Note
    @State private var tool = PageTool.select
    @State private var inkColor = InkColor.black
    @State private var useKeyboard = false
    @State private var lastInserted = ""
    @State private var alternatives: [String] = []
    @State private var showRecordings = false
    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var photoItem: PhotosPickerItem?

    init(note: Note) {
        _note = State(initialValue: note)
        _audio = StateObject(wrappedValue: AudioRecorder(noteID: note.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if audio.isRecording {
                recordingBanner
            }
            toolRow
            Divider()
            PageCanvas(initialNote: note, controller: page, tool: tool, color: inkColor.uiColor,
                       useKeyboard: useKeyboard) { changed in
                note = changed
                store.update(changed)
            }

            if tool == .select && !useKeyboard {
                Divider()
                statusBar
                InkPad(controller: pad, onIdle: recognize)
                    .frame(height: 200)
                keyRow
            }
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    audio.toggleRecording()
                } label: {
                    Image(systemName: audio.isRecording ? "stop.circle.fill" : "mic")
                        .foregroundColor(audio.isRecording ? .red : .accentColor)
                }
                Button {
                    showRecordings = true
                } label: {
                    Image(systemName: "waveform")
                }
                moreMenu
            }
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsView(audio: audio)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                page.addImage(image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoLibrary, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    page.addImage(image)
                }
                photoItem = nil
            }
        }
        .alert("녹음", isPresented: Binding(
            get: { audio.errorMessage != nil },
            set: { if !$0 { audio.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(audio.errorMessage ?? "")
        }
    }

    private var moreMenu: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    tool = .select
                    showCamera = true
                } label: {
                    Label("사진 찍기", systemImage: "camera")
                }
            }
            Button {
                tool = .select
                showPhotoLibrary = true
            } label: {
                Label("앨범에서 사진 넣기", systemImage: "photo")
            }
            Picker("속지", selection: Binding(
                get: { note.template },
                set: { page.setTemplate($0) }
            )) {
                ForEach(PaperTemplate.allCases, id: \.self) { template in
                    Text(template.label).tag(template)
                }
            }
            Button {
                useKeyboard.toggle()
            } label: {
                Label(useKeyboard ? "글씨 칸으로 입력" : "키보드로 입력",
                      systemImage: useKeyboard ? "pencil.line" : "keyboard")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var toolRow: some View {
        HStack(spacing: 0) {
            toolButton(.select, icon: "textformat")
            toolButton(.pen, icon: "pencil.tip")
            toolButton(.highlighter, icon: "highlighter")
            toolButton(.eraser, icon: "eraser")
            toolButton(.lasso, icon: "lasso")
            Divider().frame(height: 24)
            Menu {
                ForEach(InkColor.allCases) { color in
                    Button(color.label) { inkColor = color }
                }
            } label: {
                Image(systemName: "circle.fill")
                    .foregroundColor(Color(inkColor.uiColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            key(icon: "arrow.uturn.backward") { page.undo() }
            key(icon: "arrow.uturn.forward") { page.redo() }
            if page.hasSelection {
                key(icon: "trash") {
                    page.deleteSelected()
                    alternatives = []
                }
            }
        }
        .frame(height: 44)
    }

    private func toolButton(_ target: PageTool, icon: String) -> some View {
        Button {
            tool = target
        } label: {
            Image(systemName: icon)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(tool == target ? Color.accentColor.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
        }
    }

    private var recordingBanner: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 6) {
                Image(systemName: audio.isInterrupted ? "pause.circle.fill" : "record.circle")
                if audio.isInterrupted {
                    Text("통화로 일시 중지됨 · 끝나면 자동으로 이어집니다")
                } else {
                    let seconds = Int(audio.elapsed)
                    Text(String(format: "녹음 중 %02d:%02d", seconds / 60, seconds % 60))
                        .monospacedDigit()
                }
            }
            .font(.footnote)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(audio.isInterrupted ? Color.orange : Color.red)
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
                    Text("페이지를 눌러 위치를 정하고, 아래 칸에 쓰세요")
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
            key(icon: "scribble") { pad.undoLastStroke() }
            key(icon: "space") { type(" ") }
            key(icon: "delete.left") {
                page.backspace()
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
        page.insert(string)
        alternatives = []
    }

    private func recognize(_ strokes: [[StrokeSample]]) {
        recognizer.recognize(strokes) { texts in
            guard let best = texts.first else { return }
            page.insert(best)
            lastInserted = best
            alternatives = Array(texts.dropFirst().prefix(5))
        }
    }

    private func choose(_ candidate: String) {
        guard page.replaceBeforeCursor(lastInserted, with: candidate) else {
            alternatives = []
            return
        }
        alternatives = alternatives.map { $0 == candidate ? lastInserted : $0 }
        lastInserted = candidate
    }
}
