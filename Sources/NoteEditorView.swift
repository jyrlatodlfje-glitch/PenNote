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

/// 누르고 있는 동안 동작을 반복하는 키. 잠깐 누르면 한 번만 실행된다.
struct RepeatKey: View {
    let icon: String
    let action: () -> Void

    @State private var pressed = false
    @State private var timer: Timer?

    var body: some View {
        Image(systemName: icon)
            .foregroundColor(.accentColor)
            .opacity(pressed ? 0.4 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressed else { return }
                        pressed = true
                        action()
                        schedule(after: 0.4, repeats: false) {
                            schedule(after: 0.08, repeats: true, action)
                        }
                    }
                    .onEnded { _ in stop() }
            )
            .onDisappear { stop() }
    }

    private func schedule(after interval: TimeInterval, repeats: Bool, _ block: @escaping () -> Void) {
        timer?.invalidate()
        let next = Timer(timeInterval: interval, repeats: repeats) { _ in block() }
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        pressed = false
    }
}

struct NoteEditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var landscape: Bool { verticalSizeClass == .compact }
    private let pageWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)

    @StateObject private var recognizer = InkRecognizer()
    @StateObject private var page = PageController()
    @StateObject private var pad = PadController()
    @StateObject private var audio: AudioRecorder
    @StateObject private var dictation = Dictation()

    /// 음성 입력 중 현재 구간에서 페이지에 넣은 글. 인식이 고쳐질 때마다 이 부분을 바꿔 쓴다.
    @State private var dictatedSegment = ""

    @State private var note: Note
    @State private var tool = PageTool.select
    @State private var inkColor = InkColor.black
    @State private var useKeyboard = false
    @State private var lastInserted = ""
    @State private var lastSuffix = ""
    @State private var alternatives: [String] = []
    @State private var showRecordings = false
    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var photoItem: PhotosPickerItem?
    @State private var sharedItem: SharedItem?
    @State private var titleText: String
    @FocusState private var titleFocused: Bool

    init(note: Note) {
        _note = State(initialValue: note)
        _titleText = State(initialValue: note.name ?? "")
        _audio = StateObject(wrappedValue: AudioRecorder(noteID: note.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            if audio.isRecording {
                recordingBanner
            }
            TextField("제목", text: $titleText)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
                .focused($titleFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            toolRow
            if tool == .lasso {
                Text("옮길 부분을 손가락으로 빙 둘러 그린 뒤, 점선 안을 끌어 옮기세요 · 스크롤은 두 손가락")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            Divider()
            // 가로에서는 페이지 폭을 세로 때와 같게 두고, 남는 오른쪽에 글씨 칸을 놓는다.
            let layout = landscape ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                PageCanvas(initialNote: note, controller: page, tool: tool, color: inkColor.uiColor,
                           useKeyboard: useKeyboard) { changed in
                    note = changed
                    store.update(changed)
                }
                .frame(width: landscape ? pageWidth : nil)

                if tool == .select && !useKeyboard && !titleFocused {
                    Divider()
                    VStack(spacing: 0) {
                        statusBar
                        InkPad(controller: pad, onIdle: recognize)
                            .frame(height: landscape ? nil : 200)
                        keyRow
                    }
                } else if landscape {
                    Color(.secondarySystemBackground)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: titleText) { name in
            page.setName(name)
        }
        .onAppear {
            // 새 노트는 제목부터 적도록 제목란에 커서를 둔다.
            if note.name == nil && note.texts.isEmpty && note.drawing.isEmpty && note.images.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    titleFocused = true
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    audio.toggleRecording()
                } label: {
                    Image(systemName: audio.isRecording ? "stop.circle.fill" : "record.circle")
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
            RecordingsView(audio: audio) { transcript in
                tool = .select
                page.appendBlock(transcript)
            }
        }
        .sheet(item: $sharedItem) { shared in
            ActivityView(item: shared.item)
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
        .onChange(of: dictation.errorMessage) { message in
            if let message {
                audio.errorMessage = message
                dictation.errorMessage = nil
            }
        }
        .onDisappear {
            dictation.stop()
        }
        .alert("알림", isPresented: Binding(
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
            Button {
                exportPDF()
            } label: {
                Label("PDF 내보내기", systemImage: "square.and.arrow.up")
            }
            Button {
                exportText()
            } label: {
                Label("텍스트 내보내기", systemImage: "text.alignleft")
            }
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
            if dictation.isListening {
                Text("듣는 중 (\(recognizer.language == .english ? "English" : "한국어")) · 마이크를 다시 누르면 끝납니다")
                    .foregroundColor(.red)
            } else {
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
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, minHeight: 40)
    }

    private var keyRow: some View {
        HStack(spacing: 0) {
            key(text: recognizer.language.label) {
                stopDictation()
                recognizer.language = recognizer.language.next
                pad.clear()
            }
            Button(action: toggleDictation) {
                Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                    .foregroundColor(dictation.isListening ? .red : .accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            key(icon: "scribble") { pad.undoLastStroke() }
            key(icon: "space") { type(" ") }
            RepeatKey(icon: "delete.left") {
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

    private func toggleDictation() {
        if dictation.isListening {
            stopDictation()
            return
        }
        guard !audio.isRecording else {
            audio.errorMessage = "녹음 중에는 음성 입력을 함께 쓸 수 없습니다."
            return
        }
        alternatives = []
        dictatedSegment = ""
        dictation.start(locale: recognizer.language == .english ? "en-US" : "ko-KR") { text, segmentEnded in
            guard !text.isEmpty else { return }
            if !page.replaceBeforeCursor(dictatedSegment, with: text) {
                page.insert(text)
            }
            dictatedSegment = text
            if segmentEnded {
                page.insert(" ")
                dictatedSegment = ""
            }
        }
    }

    private func stopDictation() {
        guard dictation.isListening else { return }
        dictation.stop()
        dictatedSegment = ""
    }

    private func exportText() {
        let body = page.plainText()
        guard !body.isEmpty else {
            audio.errorMessage = "내보낼 글자가 없습니다. 손으로 그린 필기와 사진은 텍스트로 내보낼 수 없습니다."
            return
        }
        // 제목란에 적은 제목이 있으면 첫 줄에 붙인다. 없으면 본문 첫 줄이 곧 제목이라 중복하지 않는다.
        let title = titleText.trimmingCharacters(in: .whitespaces)
        sharedItem = SharedItem(item: title.isEmpty ? body : title + "\n\n" + body)
    }

    private func exportPDF() {
        guard let data = page.makePDF() else { return }
        let name = note.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".pdf")
        do {
            try data.write(to: url, options: .atomic)
            sharedItem = SharedItem(item: url)
        } catch {
            audio.errorMessage = "PDF를 만들지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func type(_ string: String) {
        page.insert(string)
        alternatives = []
    }

    private func recognize(_ strokes: [[StrokeSample]], wrapped: Bool) {
        recognizer.recognize(strokes, area: pad.size, preceding: page.textBeforeCursor()) { texts in
            guard let best = texts.first else { return }
            // 칸을 다 채우고 이어 쓴 경우에는 다음 글과 붙지 않게 한 칸 띄운다.
            lastSuffix = wrapped ? " " : ""
            page.insert(best + lastSuffix)
            lastInserted = best
            alternatives = Array(texts.dropFirst().prefix(5))
        }
    }

    private func choose(_ candidate: String) {
        guard page.replaceBeforeCursor(lastInserted + lastSuffix, with: candidate + lastSuffix) else {
            alternatives = []
            return
        }
        alternatives = alternatives.map { $0 == candidate ? lastInserted : $0 }
        lastInserted = candidate
    }
}
