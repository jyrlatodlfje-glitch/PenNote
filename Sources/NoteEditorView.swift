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
    /// 손가락이 닿아 있는 동안만 참. 알림·전화로 동작이 끊겨도 저절로 거짓이 된다(onEnded는 안 올 수 있음).
    @GestureState private var touching = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Image(systemName: icon)
            .foregroundColor(.accentColor)
            .opacity(pressed ? 0.4 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($touching) { _, state, _ in state = true }
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
            // 끊긴 동작으로 ⌫가 계속 돌아 글이 끝까지 지워지던 것을 막는다(2026-11-21).
            .onChange(of: touching) { isTouching in
                if !isTouching { stop() }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { stop() }
            }
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
    @Environment(\.dismiss) private var dismiss

    private var landscape: Bool { verticalSizeClass == .compact }
    private let pageWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)

    @StateObject private var recognizer = InkRecognizer()
    @StateObject private var page = PageController()
    @StateObject private var pad = PadController()
    @StateObject private var audio: AudioRecorder
    @StateObject private var dictation = Dictation()

    /// 음성 입력 중 현재 구간에서 페이지에 넣은 글. 인식이 고쳐질 때마다 이 부분을 바꿔 쓴다.
    @State private var dictatedSegment = ""
    /// 화면이 꺼진 동안 확정된 음성 입력 글. 화면이 켜지면 종이에 넣는다.
    @State private var heldText = ""
    /// 화면이 꺼진 동안 말하는 중이던 글
    @State private var heldPartial = ""
    /// 음성 입력을 멈춘 뒤 녹음 파일로 빠진 말을 다시 받아 적는 중
    @State private var refining = false

    @State private var note: Note
    @State private var tool = PageTool.select
    @State private var inkColor = InkColor.black
    @State private var useKeyboard = false
    @State private var lastInserted = ""
    @AppStorage("straightenLines") private var straightenLines = true
    @State private var lastSuffix = ""
    /// 지금 글씨 칸에 남아 있는 글씨로 노트에 넣은 글. 칸의 글씨를 다시 읽을 때마다 이 부분을 바꿔 쓴다.
    @State private var sessionText = ""
    @State private var alternatives: [String] = []
    @State private var showRecordings = false
    @State private var showCamera = false
    @State private var showPhotoLibrary = false
    @State private var showScanner = false
    @State private var bookMode = false
    @State private var fixingScan = false
    @State private var photoItem: PhotosPickerItem?
    @State private var sharedItem: SharedItem?
    @State private var titleText: String
    @State private var confirmLeaveWhileRecording = false
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
            if refining {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("녹음으로 빠진 말이 있는지 확인하는 중")
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemBackground))
            }
            // 제목은 비워 둬도 된다. 비워 두면 목록에 만든 날짜·시각이 제목으로 나온다.
            TextField(note.dateTitle.map { "제목 (비워 두면 \($0))" } ?? "제목", text: $titleText)
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
                           useKeyboard: useKeyboard, straightenLines: straightenLines,
                           onTap: dropSession) { changed in
                    note = changed
                    store.update(changed)
                }
                // 화이트보드는 폭이 정해져 있지 않으므로 가로에서도 남는 자리를 다 쓴다.
                .frame(width: landscape && note.isWhiteboard != true ? pageWidth : nil)

                if padVisible {
                    Divider()
                    VStack(spacing: 0) {
                        statusBar
                        InkPad(controller: pad, onUpdate: padUpdated, onCommit: padCommitted)
                            .frame(height: landscape ? nil : 200)
                        keyRow
                    }
                } else if keyboardBarVisible {
                    Divider()
                    keyboardBar
                } else if landscape {
                    Color(.secondarySystemBackground)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // 기본 뒤로 버튼을 숨기면 시스템이 '밀어서 뒤로 가기'를 함께 끈다. 대신 같은 자리에 버튼을 직접 둔다.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    // 녹음 중에 나가면 녹음이 알림 없이 끝나므로 먼저 묻는다(2026-11-21 검토).
                    if audio.isRecording {
                        confirmLeaveWhileRecording = true
                    } else {
                        dismiss()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
        }
        .alert("녹음 중입니다", isPresented: $confirmLeaveWhileRecording) {
            Button("녹음 멈추고 나가기", role: .destructive) {
                audio.toggleRecording()
                dismiss()
            }
            Button("계속 녹음", role: .cancel) {}
        } message: {
            Text("노트를 나가면 녹음이 끝납니다. 녹음 파일은 이 노트의 녹음 목록에 남습니다.")
        }
        .background(ContentSwipeBackDisabler())
        .onChange(of: titleText) { name in
            page.setName(name)
        }
        // 2026-11-15: 새 노트를 열 때 제목란에 커서를 두던 것을 뺐다. 열면 바로 종이에 쓴다.
        // 화면이 꺼진 동안 모아 둔 음성 입력 글을, 화면이 다시 켜지면 종이에 넣는다.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            flushHeld()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    // 음성 입력과 녹음은 마이크를 함께 쓴다. 둘을 같이 켰다가 하나를 끄면 다른 쪽도 조용히 멈추므로 막는다.
                    // (음성 입력은 이미 소리를 녹음 목록에 남김, 2026-11-21)
                    if !audio.isRecording && dictation.isListening {
                        audio.errorMessage = "음성 입력 중에는 녹음을 함께 쓸 수 없습니다. 음성 입력 소리도 녹음 목록에 남습니다."
                    } else {
                        audio.toggleRecording()
                    }
                } label: {
                    Image(systemName: audio.isRecording ? "stop.circle.fill" : "record.circle")
                        .foregroundColor(audio.isRecording ? .red : .accentColor)
                }
                Button {
                    // 녹음 목록에서 재생하면 소리 세션을 바꿔 음성 입력이 조용히 멈추므로, 먼저 음성 입력을 끝낸다(2026-11-21).
                    stopDictation()
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
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScanner { pages in
                let held = DocumentScanner.heldOrientation
                // 문서 스캔은 세로로 찍었으면 그대로, 가로로 찍었으면 가로로 돌리기만 한다.
                guard bookMode || held.isLandscape else {
                    page.addImages(pages)
                    return
                }
                let bookMode = bookMode
                fixingScan = true
                Task.detached {
                    let fixed = bookMode
                        ? pages.flatMap { BookScan.process($0, held: held) }
                        : pages.map { BookScan.orient($0, held: held) }
                    await MainActor.run {
                        fixingScan = false
                        page.addImages(fixed)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .overlay {
            if fixingScan {
                ProgressView("스캔을 보정하는 중")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
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
        // 열린 동안 밖에서 들어오는 글(녹음으로 다시 받아 적은 글)을 이 종이에 넣게 알린다(NoteStore.openPage).
        // 닫을 때 따로 빼지 않는다 — 위에 다른 화면이 덮여 onDisappear가 와도 이 종이는 살아 있으므로.
        // 화면이 정말 닫히면 종이가 사라져 등록도 저절로 무효가 된다(약한 참조 + isAttached).
        .onAppear {
            store.attach(page, to: note.id)
        }
        .onDisappear {
            stopDictation()
        }
        .onChange(of: padVisible) { _ in
            // 글씨 칸이 사라지면 칸에 있던 글씨도 없어지므로, 이어 쓰던 글을 확정한다.
            recognizer.enqueue {
                sessionText = ""
            }
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
            Button {
                copySummaryRequest()
            } label: {
                Label("AI 요약용 복사", systemImage: "doc.on.clipboard")
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
            if DocumentScanner.isSupported {
                Button {
                    tool = .select
                    bookMode = false
                    showScanner = true
                } label: {
                    Label("문서 스캔해서 넣기", systemImage: "doc.viewfinder")
                }
                Button {
                    tool = .select
                    bookMode = true
                    showScanner = true
                } label: {
                    Label("책 스캔해서 넣기", systemImage: "book")
                }
            }
            Picker("속지", selection: Binding(
                get: { note.template },
                set: { page.setTemplate($0) }
            )) {
                ForEach(PaperTemplate.allCases, id: \.self) { template in
                    Text(template.label).tag(template)
                }
            }
            Toggle("직선 반듯하게 고치기", isOn: $straightenLines)
            Button {
                if useKeyboard {
                    useKeyboard = false
                } else {
                    startKeyboard()
                }
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
                endSession()
                recognizer.language = recognizer.language.next
            }
            micButton
            // 2026-11-15 키보드를 ⋯ 메뉴에서 꺼내 마이크 옆에 둠. 다시 글씨 칸으로는 keyboardBar의 버튼.
            key(icon: "keyboard") { startKeyboard() }
            key(icon: "scribble") { pad.undoLastStroke() }
            key(icon: "space") { type(" ") }
            RepeatKey(icon: "delete.left") {
                backspace()
            }
            key(icon: "return") { type("\n") }
        }
        .frame(height: 48)
        .background(Color(.systemBackground))
    }

    private var micButton: some View {
        Button(action: toggleDictation) {
            Image(systemName: dictation.isListening ? "stop.fill" : "mic.fill")
                .foregroundColor(dictation.isListening ? .red : .accentColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
    }

    /// 키보드로 쓰는 동안 아이폰 키보드 바로 위에 붙는 줄: 글씨 칸으로 돌아가기, 마이크.
    private var keyboardBar: some View {
        HStack(spacing: 0) {
            Button {
                useKeyboard = false
            } label: {
                Label("글씨 칸으로", systemImage: "pencil.line")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            micButton
        }
        .font(.subheadline)
        .frame(height: 44)
        .frame(maxWidth: landscape ? CGFloat(220) : CGFloat.infinity)
        .background(Color(.secondarySystemBackground))
    }

    /// 키보드로 바꾼다. 글씨 칸이 사라지며 화면이 다시 짜이는 동안 키보드가 떴다가 바로 닫혀서
    /// (2026-11-15 실기기 "올라왔다가 바로 내려가서"), 화면이 다 짜인 뒤에 글상자를 고르고 키보드를 다시 띄운다.
    private func startKeyboard() {
        useKeyboard = true
        let page = self.page
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            page.focusForKeyboard()
        }
    }

    private var keyboardBarVisible: Bool {
        tool == .select && useKeyboard && !titleFocused
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
        page.followCursor()
        endSession()
        alternatives = []
        dictatedSegment = ""
        heldText = ""
        heldPartial = ""
        dictation.start(locale: recognizer.language == .english ? "en-US" : "ko-KR",
                        recordInto: note.id) { text, segmentEnded in
            guard !text.isEmpty else { return }
            // 화면이 꺼져 있으면 종이의 커서가 풀려 글을 넣지 못한다(2026-11-15 실기기: 꺼진 동안 글 0개).
            // 그동안은 모아 두었다가 화면이 켜지면 한꺼번에 넣는다.
            if UIApplication.shared.applicationState != .active {
                if segmentEnded {
                    heldText += text + " "
                    heldPartial = ""
                } else {
                    heldPartial = text
                }
                return
            }
            flushHeld()
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

    /// 화면이 꺼진 동안 모아 둔 글을 종이에 넣는다.
    private func flushHeld() {
        let held = heldText + heldPartial
        guard !held.isEmpty else { return }
        // 화면이 꺼지기 직전에 넣던 '말하는 중' 글이 모아 둔 글의 앞부분과 같을 때만 그 자리를 바꿔 쓴다.
        // 다르면(인식 작업이 새로 시작되어 4,5,6만 모인 경우) 앞 글은 그대로 두고 뒤에 붙인다.
        // (2026-11-15 실기기: 예전에는 늘 지워서 "1,2,3은 없어지고, 4,5,6만" 남았음)
        if !dictatedSegment.isEmpty,
           Self.letters(held).hasPrefix(Self.letters(dictatedSegment)),
           page.replaceBeforeCursor(dictatedSegment, with: held) {
            // 바꿔 씀
        } else {
            page.insert(dictatedSegment.isEmpty ? held : " " + held)
        }
        dictatedSegment = heldPartial
        heldText = ""
        heldPartial = ""
    }

    /// 글자와 숫자만 남긴다. 쉼표·띄어쓰기가 고쳐져도 같은 말인지 견주려고.
    private static func letters(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }

    private func stopDictation() {
        guard dictation.isListening else { return }
        flushHeld()
        let live = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let recording = dictation.recordingURL
        let locale = dictation.locale
        let noteID = note.id
        let page = self.page
        let store = self.store
        dictation.stop()
        dictatedSegment = ""
        audio.reload()
        guard let recording else { return }
        // 실시간으로 못 받은 말이 있으면(화면이 꺼진 동안 인식이 멈춘 경우 등) 녹음 파일로 다시 받아 적어 덧붙인다.
        refining = true
        LiveTranscriber.transcribeFile(recording, locale: locale) { result in
            refining = false
            let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Double(result.count) > Double(live.count) * 1.2 + 20 else { return }
            let block = "[녹음으로 다시 받아 적은 글]\n" + result
            if page.isAttached {
                page.appendBlock(block, follow: false)
            } else {
                store.appendText(block, to: noteID)
            }
        }
    }

    private func exportText() {
        let body = page.plainText()
        guard !body.isEmpty else {
            audio.errorMessage = "내보낼 글자가 없습니다. 손으로 그린 필기와 사진은 텍스트로 내보낼 수 없습니다."
            return
        }
        // 제목란에 적은 제목이 있으면 첫 줄에 붙인다. 없으면 본문 첫 줄이 곧 제목이라 중복하지 않는다.
        let title = titleText.trimmingCharacters(in: .whitespaces)
        let text = (title.isEmpty ? body : title + "\n\n" + body)
            .replacingOccurrences(of: "\n", with: "\r\n")
        // PC의 메모장 등에서 한글이 깨지지 않도록 UTF-8 표식(BOM)을 붙이고 줄바꿈도 Windows 방식으로 쓴다.
        share(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8), fileExtension: "txt")
    }

    /// 노트 글 앞에 "회의록으로 정리해 줘" 부탁 글을 붙여 복사한다.
    /// 아이폰 14 Pro Max는 애플 AI(요약)가 안 돼서, Claude·ChatGPT 앱에 붙여 넣어 정리하게 한다.
    private func copySummaryRequest() {
        let body = page.plainText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            audio.errorMessage = "복사할 글자가 없습니다. 녹음을 글자로 바꾼 뒤에 해 보세요. 손으로 그린 필기와 사진은 복사되지 않습니다."
            return
        }
        let title = titleText.trimmingCharacters(in: .whitespaces)
        let request = """
        아래는 회의(또는 녹음)를 받아 적은 글이야. 받아쓰기라 틀린 낱말이 있을 수 있으니 앞뒤 뜻으로 바로잡아 읽어 줘.
        숫자·이름·날짜를 바로잡았으면 (원래 → 고침)으로 표시해 줘.
        다음 차례로 한국어로 정리해 줘.
        1. 세 줄 요약
        2. 회의록 — 주제별로, 누가 무슨 말을 했는지 ("화자 1·2"가 있으면 그대로 써 줘)
        3. 정해진 것
        4. 할 일 — 누가 / 무엇을 / 언제까지 (글에 없으면 "안 나옴")
        5. 다음에 확인할 것
        글에 없는 내용은 지어내지 말아 줘.
        """
        let heading = title.isEmpty ? note.title : title
        UIPasteboard.general.string = request + "\n\n---\n제목: " + heading + "\n\n" + body
        // 아주 긴 회의는 요금제에 따라 한 번에 다 안 들어갈 수 있어 미리 알린다(2만 자는 대략의 기준).
        let longNote = body.count > 20_000
            ? "\n\n글이 깁니다. 한 번에 안 들어가면 앞 반을 먼저 붙여 넣고, 뒤 반은 '앞 글에 이어서 같은 방식으로 정리해 줘'를 먼저 적은 뒤 붙여 넣으세요."
            : ""
        audio.errorMessage = "복사했습니다 (\(body.count)자). Claude나 ChatGPT 앱을 열어 입력칸을 길게 누르고 '붙여넣기' 하세요. 붙여 넣을 때는 인터넷이 필요합니다." + longNote
    }

    private func exportPDF() {
        guard let data = page.makePDF() else { return }
        share(data, fileExtension: "pdf")
    }

    /// 노트 제목을 파일 이름으로 해서 임시 파일을 만들고 공유 화면을 연다.
    private func share(_ data: Data, fileExtension: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(BoardExport.safeFileName(note.title))
            .appendingPathExtension(fileExtension)
        do {
            try data.write(to: url, options: .atomic)
            sharedItem = SharedItem(item: url)
        } catch {
            audio.errorMessage = "파일을 만들지 못했습니다: \(error.localizedDescription)"
        }
    }

    private var padVisible: Bool {
        tool == .select && !useKeyboard && !titleFocused
    }

    /// 페이지를 눌러 커서를 옮길 때: 칸의 글씨를 버리고 지금까지 넣은 글을 확정한다.
    private func dropSession() {
        pad.clear()
        recognizer.enqueue {
            sessionText = ""
        }
    }

    /// 글씨 칸의 글씨를 확정하고 칸을 비운다. 키 입력처럼 글을 이어 붙이는 동작 앞에서 부른다.
    /// 뒤따르는 동작은 `recognizer.enqueue`로 넣어야, 아직 끝나지 않은 인식 결과보다 먼저 실행되지 않는다.
    private func endSession() {
        pad.finish()
        recognizer.enqueue {
            sessionText = ""
        }
    }

    private func type(_ string: String) {
        page.followCursor()
        endSession()
        recognizer.enqueue {
            page.insert(string)
            alternatives = []
        }
    }

    private func backspace() {
        page.followCursor()
        endSession()
        recognizer.enqueue {
            page.backspace()
            alternatives = []
        }
    }

    /// 글씨 칸의 글씨 전체를 다시 읽어, 이 칸으로 넣었던 글을 새 결과로 바꿔 쓴다.
    private func padUpdated(_ strokes: [[StrokeSample]]) {
        guard !strokes.isEmpty else {
            recognizer.enqueue {
                if !sessionText.isEmpty {
                    _ = page.replaceBeforeCursor(sessionText, with: "")
                }
                sessionText = ""
                alternatives = []
            }
            return
        }
        page.followCursor()
        var preceding = page.textBeforeCursor()
        if preceding.hasSuffix(sessionText) {
            preceding.removeLast(sessionText.count)
        }
        recognizer.recognize(strokes, area: pad.size, preceding: preceding) { texts in
            guard let best = texts.first else { return }
            if !page.replaceBeforeCursor(sessionText, with: best) {
                page.insert(best)
            }
            sessionText = best
            lastInserted = best
            lastSuffix = ""
            alternatives = Array(texts.dropFirst().prefix(5))
        }
    }

    /// 글씨 칸이 비워지고 다음 글로 넘어갔다.
    private func padCommitted(wrapped: Bool) {
        recognizer.enqueue {
            // 칸을 다 채우고 왼쪽에서 이어 쓴 경우에는 다음 글과 붙지 않게 한 칸 띄운다.
            if wrapped, !sessionText.isEmpty {
                page.insert(" ")
                lastSuffix = " "
            }
            sessionText = ""
        }
    }

    private func choose(_ candidate: String) {
        // 고른 후보가 다음 인식 결과로 덮이지 않도록 글씨 칸을 비우고 확정한다.
        pad.clear()
        sessionText = ""
        guard page.replaceBeforeCursor(lastInserted + lastSuffix, with: candidate + lastSuffix) else {
            alternatives = []
            return
        }
        alternatives = alternatives.map { $0 == candidate ? lastInserted : $0 }
        lastInserted = candidate
    }
}
