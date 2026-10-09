import AVFoundation
import Speech

/// 말하는 대로 글자를 내보내는 실시간 음성 입력.
final class Dictation: ObservableObject {
    @Published private(set) var isListening = false
    @Published var errorMessage: String?

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var onText: ((String, Bool) -> Void)?
    private var lastEndedText = ""
    private var taskStarted = Date()
    private var quickFailures = 0

    /// `onText(글, 구간종료)`: 같은 구간의 글은 말하는 동안 계속 고쳐져서 다시 온다.
    func start(locale: String, onText: @escaping (String, Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    guard status == .authorized, granted else {
                        self?.errorMessage = "설정 > PenNote에서 마이크와 음성 인식을 허용해 주세요."
                        return
                    }
                    self?.begin(locale: locale, onText: onText)
                }
            }
        }
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        onText = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func begin(locale: String, onText: @escaping (String, Bool) -> Void) {
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
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            errorMessage = "음성 입력을 시작하지 못했습니다: \(error.localizedDescription)"
            return
        }
        self.recognizer = recognizer
        self.onText = onText
        lastEndedText = ""
        quickFailures = 0
        isListening = true
        beginTask()
    }

    private func beginTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        taskStarted = Date()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.isListening, self.request === request else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    let ended = result.speechRecognitionMetadata != nil || result.isFinal
                    if !ended {
                        self.onText?(text, false)
                    } else if text != self.lastEndedText {
                        self.lastEndedText = text
                        self.onText?(text, true)
                    }
                }
                guard result?.isFinal == true || error != nil else { return }
                // 인식 작업은 침묵이나 시간 제한으로 끝나므로, 듣는 중이면 이어서 다시 시작한다.
                self.quickFailures = Date().timeIntervalSince(self.taskStarted) < 1 ? self.quickFailures + 1 : 0
                if self.quickFailures >= 3 {
                    self.stop()
                    self.errorMessage = "음성 인식이 계속 중단됩니다. \(error?.localizedDescription ?? "")"
                } else {
                    self.lastEndedText = ""
                    self.beginTask()
                }
            }
        }
    }
}
