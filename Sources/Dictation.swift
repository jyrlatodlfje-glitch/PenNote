import AVFoundation
import Speech

/// 말하는 대로 글자를 내보내는 실시간 음성 입력 (노트 화면 글씨 칸 아래의 마이크).
/// 화면이 꺼져도 계속 듣는다(백그라운드 오디오). 2026-11-15부터 소리를 노트의 녹음 목록에 파일로도 남겨,
/// 실시간으로 못 받은 말이 있으면 멈춘 뒤 그 파일로 다시 받아 적을 수 있게 한다.
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published var errorMessage: String?

    /// 이번에 듣는 동안 받아 적은 글 전체 (말하는 중인 부분 포함)
    private(set) var transcript = ""
    /// 이번에 듣는 동안 남긴 소리 파일
    private(set) var recordingURL: URL?
    private(set) var locale = "ko-KR"

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var file: AVAudioFile?
    private var onText: ((String, Bool) -> Void)?
    private var lastEndedText = ""
    private var endedTranscript = ""
    /// 지금 인식 작업에서 말하는 중인(아직 구간이 닫히지 않은) 글
    private var pendingPartial = ""
    private var taskStarted = Date()
    /// 마지막으로 인식 결과가 온 때. 쉼 뒤 새로 시작한 글인지 가리려고 (2026-11-15).
    private var lastResultAt = Date()
    private var quickFailures = 0
    /// 소리 스레드와 화면 스레드가 함께 `request`를 쓴다.
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    init() {
        // 전화가 오면 마이크가 멈춘다. 전화가 끝나면 다시 듣는다.
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: nil, queue: .main) { [weak self] notification in
            guard let self, self.isListening,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.engine.start()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// `onText(글, 구간종료)`: 같은 구간의 글은 말하는 동안 계속 고쳐져서 다시 온다.
    /// `recordInto`: 소리 파일을 남길 노트. 파일은 그 노트의 녹음 목록에 들어간다.
    func start(locale: String, recordInto noteID: UUID?, onText: @escaping (String, Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard status == .authorized, granted else {
                        self?.errorMessage = "설정 > PenNote에서 마이크와 음성 인식을 허용해 주세요."
                        return
                    }
                    self?.begin(locale: locale, noteID: noteID, onText: onText)
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil // 파일을 닫는다
        lock.lock()
        let request = self.request
        self.request = nil
        lock.unlock()
        request?.endAudio()
        task?.cancel()
        task = nil
        onText = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var currentRequest: SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    private func begin(locale: String, noteID: UUID?, onText: @escaping (String, Bool) -> Void) {
        guard !isListening else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            errorMessage = "이 언어의 음성 인식을 지금 사용할 수 없습니다."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            file = nil
            recordingURL = nil
            if let noteID {
                // 파일을 못 만들어도 받아 적기는 그대로 한다.
                file = try? VoiceMemoSaver.openFile(at: VoiceMemoSaver.newRecordingURL(noteID: noteID, date: Date()),
                                                    format: format)
                recordingURL = file?.url
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                try? self.file?.write(from: buffer)
                self.currentRequest?.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            file = nil
            errorMessage = "음성 입력을 시작하지 못했습니다: \(error.localizedDescription)"
            return
        }
        self.recognizer = recognizer
        self.locale = locale
        self.onText = onText
        lastEndedText = ""
        endedTranscript = ""
        pendingPartial = ""
        transcript = ""
        quickFailures = 0
        isListening = true
        beginTask()
    }

    private func beginTask() {
        guard let recognizer, isListening else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        lock.lock()
        self.request = request
        lock.unlock()
        taskStarted = Date()
        lastResultAt = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isListening, self.currentRequest === request else { return }
                if let result {
                    var text = result.bestTranscription.formattedString
                    let ended = result.speechRecognitionMetadata != nil || result.isFinal
                    let gap = Date().timeIntervalSince(self.lastResultAt)
                    self.lastResultAt = Date()
                    // 끝날 때 빈 글이 오면(화면이 꺼질 때 등) 마지막에 들은 글을 쓴다.
                    if ended && text.isEmpty {
                        text = self.pendingPartial
                    }
                    // iOS 18부터 잠깐 쉬었다 말하면 앞 글을 빼고 새 말만 보낸다. 그대로 두면 새 글이 앞 글 자리를 덮어쓴다
                    // (2026-11-15 실기기: "기존에 있던게 없어지고, 지금 말하는게 나와"). 앞 글을 한 구간으로 닫고 새 글은 뒤에 붙인다.
                    if SpeechText.isRestart(previous: self.pendingPartial, new: text, gap: gap) {
                        let closing = self.pendingPartial
                        self.pendingPartial = ""
                        self.lastEndedText = closing
                        self.endedTranscript = Self.join(self.endedTranscript, closing)
                        self.transcript = self.endedTranscript
                        self.onText?(closing, true)
                    }
                    if !ended {
                        if !text.isEmpty { self.pendingPartial = text }
                        self.transcript = Self.join(self.endedTranscript, text)
                        self.onText?(text, false)
                    } else {
                        self.pendingPartial = ""
                        if !text.isEmpty && text != self.lastEndedText {
                            self.lastEndedText = text
                            self.endedTranscript = Self.join(self.endedTranscript, text)
                            self.transcript = self.endedTranscript
                            self.onText?(text, true)
                        }
                    }
                }
                guard result?.isFinal == true || error != nil else { return }
                // 작업이 오류로 끝나 구간이 닫히지 않았으면 마지막에 들은 글로 닫는다.
                // 안 닫으면 다음 작업의 글이 그 자리를 덮어쓴다 (2026-11-15 실기기: 화면을 끄고 켜니 "1,2,3은 없어지고, 4,5,6만").
                if !self.pendingPartial.isEmpty {
                    let closing = self.pendingPartial
                    self.pendingPartial = ""
                    self.lastEndedText = closing
                    self.endedTranscript = Self.join(self.endedTranscript, closing)
                    self.transcript = self.endedTranscript
                    self.onText?(closing, true)
                }
                // 인식 작업은 침묵이나 시간 제한으로 끝나므로, 듣는 중이면 이어서 다시 시작한다.
                // 계속 실패해도 듣기(녹음)는 멈추지 않고 잠깐 쉬었다가 다시 시도한다 — 놓친 말은 멈춘 뒤 녹음 파일로 채운다.
                self.quickFailures = Date().timeIntervalSince(self.taskStarted) < 1 ? self.quickFailures + 1 : 0
                self.lastEndedText = ""
                if self.quickFailures < 3 {
                    self.beginTask()
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.isListening, self.currentRequest === request else { return }
                        self.beginTask()
                    }
                }
            }
        }
    }

    private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }
}
