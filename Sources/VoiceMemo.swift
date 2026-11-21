import AVFoundation
import SwiftUI

/// 음성 메모를 새 노트로 저장한다. 제목은 날짜·시간, 소리 파일은 노트의 녹음 목록에 들어간다.
enum VoiceMemoSaver {
    static func newRecordingURL(noteID: UUID, date: Date) -> URL {
        let folder = AudioRecorder.folder(for: noteID)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = formatter.string(from: date)
        // 같은 초에 파일을 또 열면(이어폰을 바로 바꾼 경우 등) 앞 파일을 덮어쓰지 않게 "-2"를 붙인다(2026-11-21).
        var url = folder.appendingPathComponent(base + ".m4a")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path)
                || FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("caf").path) {
            url = folder.appendingPathComponent("\(base)-\(number).m4a")
            number += 1
        }
        return url
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
    /// 저장하자마자 노트가 열리므로, 열린 화면에도 넣어야 옛 사본이 덮어쓰지 않는다(NoteStore.replaceText).
    /// 회원님이 그새 그 글을 고쳤으면 지우지 않고 맨 아래에 덧붙인다.
    static func refine(noteID: UUID, liveText: String, locale: String, store: NoteStore) {
        let folder = AudioRecorder.folder(for: noteID)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        // 소리 파일 가운데 가장 큰 것(빈 파일·이어폰을 바꿔 새로 연 짧은 파일은 피함).
        let sizes = files.filter { ["m4a", "caf"].contains($0.pathExtension) }.map { url in
            (url, (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard let audio = sizes.filter({ $0.1 > 0 }).max(by: { $0.1 < $1.1 })?.0 else { return }
        // 저장할 때 넣은 글(실시간 글, 비었으면 안내문) — 이 글상자를 찾아 바꾼다.
        let saved = textItem(liveText).text
        let live = liveText.trimmingCharacters(in: .whitespacesAndNewlines).count
        LiveTranscriber.transcribeFile(audio, locale: locale) { result in
            let result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            // 실시간 글이 있었으면 녹음 쪽이 눈에 띄게 길 때만(빠진 말이 있을 때만) 바꾼다 — 노트 마이크와 같은 기준.
            let enough = live == 0 ? !result.isEmpty : Double(result.count) > Double(live) * 1.2 + 20
            guard enough else { return }
            store.replaceText(saved, with: result, orAppendWith: "[녹음으로 다시 받아 적은 글]\n", in: noteID)
        }
    }

    /// 통화 중이거나 다른 앱이 마이크를 쥐고 있으면 마이크 형식이 0Hz·0채널로 온다.
    /// 그 형식으로 소리 받기(installTap)를 걸면 앱이 꺼지므로, 걸기 전에 막고 알린다(2026-11-21).
    static func checkMicrophone(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "PenNote", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "지금은 마이크를 쓸 수 없습니다(통화 중이거나 다른 앱이 마이크를 쓰는 중). 잠시 뒤 다시 눌러 주세요.",
            ])
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
    private var routeObserver: NSObjectProtocol?

    init() {
        // 에어팟을 끼거나 빼면 iOS가 소리 엔진을 멈춘다. 새 마이크로 다시 건다(2026-11-21).
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                               object: engine, queue: .main) { [weak self] _ in
            self?.restartAfterRouteChange()
        }
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
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
    }

    /// 마이크가 바뀐 뒤 새 형식으로 다시 건다. 형식이 달라지면 소리 파일을 새로 열어
    /// 녹음이 끊기지 않게 한다(같은 노트의 녹음 목록에 두 파일로 남음).
    private func restartAfterRouteChange() {
        guard isRecording else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // 아직 새 마이크가 준비되지 않았으면(0Hz) 다음 알림을 기다린다 — 걸면 앱이 꺼짐.
        guard (try? VoiceMemoSaver.checkMicrophone(format)) != nil else { return }
        // 바뀐 직후엔 출력 형식이 실제 마이크 형식과 아직 다를 수 있다 — 다르면 걸 때 앱이 꺼지므로 다음 알림을 기다린다.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate == format.sampleRate, hardware.channelCount == format.channelCount else { return }
        // 소리 받기를 먼저 떼어 소리 스레드가 파일에 쓰는 중에 파일을 바꾸지 않게 한다.
        input.removeTap(onBus: 0)
        if let file, file.processingFormat.sampleRate != format.sampleRate
            || file.processingFormat.channelCount != format.channelCount {
            self.file = try? VoiceMemoSaver.openFile(at: VoiceMemoSaver.newRecordingURL(noteID: noteID, date: Date()),
                                                     format: format)
        }
        installTap(on: input, format: format)
        engine.prepare()
        try? engine.start()
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.file?.write(from: buffer)
            self.transcriber.append(buffer)
        }
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
            try VoiceMemoSaver.checkMicrophone(format)
            let now = Date()
            file = try VoiceMemoSaver.openFile(at: VoiceMemoSaver.newRecordingURL(noteID: noteID, date: now), format: format)
            transcriber.onText = { [weak self] text in self?.text = text }
            transcriber.start(locale: locale)
            input.removeTap(onBus: 0)
            installTap(on: input, format: format)
            engine.prepare()
            try engine.start()
            started = now
            isRecording = true
        } catch {
            // 반쯤 켠 것을 정리한다(받아 적기·파일·녹음 세션). 세션을 켠 채 두면 다른 앱 소리가 멈춘 채 남는다.
            engine.inputNode.removeTap(onBus: 0)
            transcriber.stop()
            file = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        // 실시간 글이 비었거나 중간에 끊겼으면(인식 실패·이어폰 바꿈 등) 녹음 파일로 다시 받아 채운다.
        VoiceMemoSaver.refine(noteID: noteID, liveText: text, locale: locale, store: store)
        return note
    }
}

/// 지금 받아 적는 음성 메모를 한곳에 둔다. 앱 화면의 버튼뿐 아니라
/// 단축어·Siri로도 같은 메모를 시작하고 멈출 수 있게 하기 위해서다.
final class VoiceMemoCenter: ObservableObject {
    static let shared = VoiceMemoCenter()

    var store: NoteStore?
    @Published private(set) var memo: PhoneVoiceMemo?
    /// 방금 저장한 노트. 목록 화면이 이 노트를 연다.
    @Published var savedNoteID: UUID?
    private var folderID: UUID?

    var isRecording: Bool { memo?.isRecording == true }

    func start(folderID: UUID?) {
        guard memo == nil else { return }
        self.folderID = folderID
        let memo = PhoneVoiceMemo()
        self.memo = memo
        memo.start()
    }

    /// 멈추고 새 노트로 저장한다. 받아 적는 중이 아니었으면 화면만 닫고 nil.
    @discardableResult
    func stopAndSave() -> Note? {
        guard let memo else { return nil }
        self.memo = nil
        guard let store, let note = memo.stop(into: store, folderID: folderID) else { return nil }
        savedNoteID = note.id
        return note
    }
}

/// 음성 메모 화면: 말하는 대로 글자가 나오고, [멈추고 저장]을 누르면 새 노트가 된다.
struct VoiceMemoView: View {
    @ObservedObject var memo: PhoneVoiceMemo

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
                VoiceMemoCenter.shared.stopAndSave()
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
    }
}
