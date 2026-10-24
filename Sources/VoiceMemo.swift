import AVFoundation
import SwiftUI

/// 음성 메모를 새 노트로 저장한다. 제목은 날짜·시간, 소리 파일은 노트의 녹음 목록에 들어간다.
enum VoiceMemoSaver {
    static func newRecordingURL(noteID: UUID, date: Date) -> URL {
        let folder = AudioRecorder.folder(for: noteID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return folder.appendingPathComponent(formatter.string(from: date) + ".m4a")
    }

    /// m4a(AAC)로 쓸 파일을 연다. 안 되면 caf(압축 없음)로 연다.
    static func openFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let aac: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        if let file = try? AVAudioFile(forWriting: url, settings: aac,
                                       commonFormat: format.commonFormat, interleaved: format.isInterleaved) {
            return file
        }
        let caf = url.deletingPathExtension().appendingPathExtension("caf")
        return try AVAudioFile(forWriting: caf, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    }

    @discardableResult
    static func save(id: UUID, date: Date, text: String, fromWatch: Bool, folderID: UUID?, store: NoteStore) -> Note {
        var note = Note()
        note.id = id
        note.folderID = folderID
        note.name = VoiceLink.title(for: date, fromWatch: fromWatch)
        note.texts = [textItem(text)]
        store.add(note)
        return note
    }

    /// 녹음 파일을 다시 글자로 바꿔, 실시간으로 받은 글보다 길면 바꿔 넣는다.
    static func refine(noteID: UUID, liveText: String, locale: String, store: NoteStore) {
        let folder = AudioRecorder.folder(for: noteID)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        guard let audio = files.first(where: { ["m4a", "caf"].contains($0.pathExtension) }) else { return }
        LiveTranscriber.transcribeFile(audio, locale: locale) { result in
            let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.count > liveText.trimmingCharacters(in: .whitespacesAndNewlines).count,
                  var note = store.notes.first(where: { $0.id == noteID }) else { return }
            note.texts = [textItem(result)]
            store.update(note)
        }
    }

    private static func textItem(_ text: String) -> TextItem {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return TextItem(x: 12, y: PageCanvasView.lineHeight,
                        text: body.isEmpty ? "(글자로 바꾸는 중이거나 바꾼 내용이 없습니다. 녹음을 들어 보세요.)" : body)
    }
}

/// 아이폰 마이크로 하는 음성 메모: 말하는 대로 글자가 보이고, 소리 파일도 남긴다.
/// 화면이 꺼져도 계속된다(백그라운드 오디오). 전화가 오면 멈췄다가 끊으면 이어서 받는다.
final class PhoneVoiceMemo: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var isRecording = false
    @Published private(set) var started = Date()
    @Published private(set) var locale = VoiceLink.savedLocale
    @Published var errorMessage: String?

    let noteID = UUID()
    private let engine = AVAudioEngine()
    private let transcriber = LiveTranscriber()
    private var file: AVAudioFile?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: nil, queue: .main) { [weak self] notification in
            guard let self, self.isRecording,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.engine.start()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 받아 적는 도중에도 바꿀 수 있다. 고른 언어는 다음 메모에도 쓴다.
    func setLocale(_ locale: String) {
        self.locale = locale
        UserDefaults.standard.set(locale, forKey: VoiceLink.savedLocaleKey)
        transcriber.change(locale: locale)
    }

    func start() {
        LiveTranscriber.requestPermission { [weak self] speechAllowed in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard granted else {
                        self?.errorMessage = "설정 > PenNote에서 마이크를 허용해 주세요."
                        return
                    }
                    if !speechAllowed {
                        self?.errorMessage = "음성 인식이 꺼져 있어 녹음만 합니다. 설정 > PenNote에서 음성 인식을 허용해 주세요."
                    }
                    self?.begin()
                }
            }
        }
    }

    private func begin() {
        guard !isRecording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            let now = Date()
            file = try VoiceMemoSaver.openFile(at: VoiceMemoSaver.newRecordingURL(noteID: noteID, date: now), format: format)
            transcriber.onText = { [weak self] text in self?.text = text }
            transcriber.start(locale: locale)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.file?.write(from: buffer)
                self.transcriber.append(buffer)
            }
            engine.prepare()
            try engine.start()
            started = now
            isRecording = true
        } catch {
            errorMessage = "음성 메모를 시작하지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 멈추고 새 노트로 저장한다.
    func stop(into store: NoteStore, folderID: UUID?) -> Note? {
        guard isRecording else { return nil }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        transcriber.stop()
        file = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let note = VoiceMemoSaver.save(id: noteID, date: started, text: text, fromWatch: false,
                                       folderID: folderID, store: store)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VoiceMemoSaver.refine(noteID: noteID, liveText: "", locale: locale, store: store)
        }
        return note
    }
}

/// 음성 메모 화면: 말하는 대로 글자가 나오고, [멈추고 저장]을 누르면 새 노트가 된다.
struct VoiceMemoView: View {
    let folderID: UUID?
    var onSaved: (Note) -> Void

    @EnvironmentObject private var store: NoteStore
    @StateObject private var memo = PhoneVoiceMemo()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundColor(memo.isRecording ? .red : .secondary)
                Text(memo.isRecording ? "받아 적는 중" : "준비 중")
                Spacer()
                if memo.isRecording {
                    Text(memo.started, style: .timer)
                        .monospacedDigit()
                }
            }
            .font(.headline)

            Picker("언어", selection: Binding(get: { memo.locale }, set: { memo.setLocale($0) })) {
                Text("한국어").tag(VoiceLink.korean)
                Text("English").tag(VoiceLink.english)
            }
            .pickerStyle(.segmented)
            Text("평소에는 한국어(NFPA 같은 영어 낱말도 받아 적음), 외국 분과 대화할 때만 English")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(memo.text.isEmpty ? "말씀하시면 여기에 글자가 나옵니다." : memo.text)
                        .foregroundColor(memo.text.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("end")
                }
                .onChange(of: memo.text) { _ in
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }

            if let message = memo.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
            Text("화면이 꺼져도 계속 받아 적습니다. 소리 파일도 함께 남습니다.")
                .font(.footnote)
                .foregroundColor(.secondary)

            Button {
                if let note = memo.stop(into: store, folderID: folderID) {
                    onSaved(note)
                }
                dismiss()
            } label: {
                Label(memo.isRecording ? "멈추고 저장" : "닫기", systemImage: "stop.circle.fill")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding()
        .interactiveDismissDisabled()
        .onAppear { memo.start() }
    }
}
