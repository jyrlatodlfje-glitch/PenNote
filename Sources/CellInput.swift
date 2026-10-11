import SwiftUI

/// 만다라트와 마인드맵에서 고른 칸에 글을 넣는 입력판.
/// 노트와 같이 글씨 칸(손글씨 → 글자), 음성, 키보드 세 가지로 쓸 수 있다. 글은 항상 칸의 맨 끝에 이어 붙는다.
struct CellInputPanel: View {
    @Binding var text: String
    let placeholder: String
    /// 고른 칸이 바뀌면 달라지는 값. 바뀌면 쓰던 글씨와 음성 입력을 끝낸다.
    let target: String

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @StateObject private var recognizer = InkRecognizer()
    @StateObject private var pad = PadController()
    @StateObject private var dictation = Dictation()
    @AppStorage("boardUseKeyboard") private var useKeyboard = false

    /// 지금 글씨 칸에 남아 있는 글씨로 넣은 글. 칸의 글씨를 다시 읽을 때마다 이 부분을 바꿔 쓴다.
    @State private var sessionText = ""
    @State private var dictatedSegment = ""
    @State private var alternatives: [String] = []
    @State private var lastInserted = ""
    @State private var message: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if useKeyboard {
                    TextField(placeholder, text: $text, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($focused)
                } else {
                    Text(text.isEmpty ? placeholder : text)
                        .foregroundColor(text.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button {
                    endSession()
                    stopDictation()
                    useKeyboard.toggle()
                    focused = useKeyboard
                } label: {
                    Image(systemName: useKeyboard ? "pencil.line" : "keyboard")
                        .frame(width: 36, height: 32)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !useKeyboard {
                Divider()
                statusBar
                InkPad(controller: pad, onUpdate: padUpdated, onCommit: padCommitted)
                    .frame(height: verticalSizeClass == .compact ? 96 : 170)
                keyRow
            }
        }
        .background(Color(.systemBackground))
        .onChange(of: target) { _ in
            stopDictation()
            pad.clear()
            recognizer.enqueue {
                sessionText = ""
                alternatives = []
            }
            if useKeyboard {
                focused = true
            }
        }
        .onChange(of: dictation.errorMessage) { error in
            if let error {
                message = error
                dictation.errorMessage = nil
            }
        }
        .onDisappear {
            dictation.stop()
        }
        .alert("알림", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        Group {
            if dictation.isListening {
                Text("듣는 중 (\(recognizer.language == .english ? "English" : "한국어")) · 마이크를 다시 누르면 끝납니다")
                    .foregroundColor(.red)
            } else if case .failed(let reason) = recognizer.state {
                Text(reason)
                    .foregroundColor(.red)
            } else if recognizer.state == .downloading {
                Text("인식 모델을 내려받는 중입니다 (언어별 최초 1회)")
                    .foregroundColor(.secondary)
            } else if alternatives.isEmpty {
                Text("칸을 누르고, 아래에 글씨를 쓰세요")
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
        .font(.footnote)
        .frame(maxWidth: .infinity, minHeight: 36)
    }

    private var keyRow: some View {
        HStack(spacing: 0) {
            key(text: recognizer.language.label) {
                stopDictation()
                endSession()
                recognizer.language = recognizer.language.next
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
                backspace()
            }
            key(icon: "return") { type("\n") }
        }
        .frame(height: 46)
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

    /// 칸 끝에 있는 `old`를 `new`로 바꾼다. 끝이 `old`가 아니면 그냥 이어 붙인다.
    private func replaceEnd(_ old: String, with new: String) {
        var value = text
        if !old.isEmpty, value.hasSuffix(old) {
            value.removeLast(old.count)
        }
        text = value + new
    }

    /// 글씨 칸의 글씨를 확정하고 칸을 비운다.
    /// 뒤따르는 동작은 `recognizer.enqueue`로 넣어야, 아직 끝나지 않은 인식 결과보다 먼저 실행되지 않는다.
    private func endSession() {
        pad.finish()
        recognizer.enqueue {
            sessionText = ""
        }
    }

    private func type(_ string: String) {
        endSession()
        recognizer.enqueue {
            text += string
            alternatives = []
        }
    }

    private func backspace() {
        endSession()
        recognizer.enqueue {
            if !text.isEmpty {
                text.removeLast()
            }
            alternatives = []
        }
    }

    /// 글씨 칸의 글씨 전체를 다시 읽어, 이 칸으로 넣었던 글을 새 결과로 바꿔 쓴다.
    private func padUpdated(_ strokes: [[StrokeSample]]) {
        guard !strokes.isEmpty else {
            recognizer.enqueue {
                replaceEnd(sessionText, with: "")
                sessionText = ""
                alternatives = []
            }
            return
        }
        var preceding = text
        if preceding.hasSuffix(sessionText) {
            preceding.removeLast(sessionText.count)
        }
        recognizer.recognize(strokes, area: pad.size, preceding: preceding) { texts in
            guard let best = texts.first else { return }
            replaceEnd(sessionText, with: best)
            sessionText = best
            lastInserted = best
            alternatives = Array(texts.dropFirst().prefix(5))
        }
    }

    /// 글씨 칸이 비워지고 다음 글로 넘어갔다.
    private func padCommitted(wrapped: Bool) {
        recognizer.enqueue {
            // 칸을 다 채우고 왼쪽에서 이어 쓴 경우에는 다음 글과 붙지 않게 한 칸 띄운다.
            if wrapped, !sessionText.isEmpty {
                text += " "
            }
            sessionText = ""
        }
    }

    private func choose(_ candidate: String) {
        // 고른 후보가 다음 인식 결과로 덮이지 않도록 글씨 칸을 비우고 확정한다.
        pad.clear()
        sessionText = ""
        let trailingSpace = text.hasSuffix(lastInserted + " ") ? " " : ""
        guard text.hasSuffix(lastInserted + trailingSpace) else {
            alternatives = []
            return
        }
        replaceEnd(lastInserted + trailingSpace, with: candidate + trailingSpace)
        alternatives = alternatives.map { $0 == candidate ? lastInserted : $0 }
        lastInserted = candidate
    }

    private func toggleDictation() {
        if dictation.isListening {
            stopDictation()
            return
        }
        endSession()
        alternatives = []
        dictatedSegment = ""
        dictation.start(locale: recognizer.language == .english ? "en-US" : "ko-KR") { spoken, segmentEnded in
            guard !spoken.isEmpty else { return }
            replaceEnd(dictatedSegment, with: spoken)
            dictatedSegment = spoken
            if segmentEnded {
                text += " "
                dictatedSegment = ""
            }
        }
    }

    private func stopDictation() {
        guard dictation.isListening else { return }
        dictation.stop()
        dictatedSegment = ""
    }
}
