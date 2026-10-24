import AVFoundation
import Speech

/// 들어오는 소리를 계속 글자로 바꾼다. 소리는 아이폰 마이크든 워치에서 온 것이든 상관없다.
/// 인식 작업은 침묵이나 시간 제한으로 끝나므로, 끝날 때마다 앞의 글을 이어 붙이고 다시 시작한다.
final class LiveTranscriber {
    /// 지금까지 받아 적은 글 전체 (말하는 중인 부분 포함)
    private(set) var text = ""
    var onText: ((String) -> Void)?

    private var finished = ""
    private var locale = VoiceLink.korean
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var running = false
    private var taskStarted = Date()
    private var quickFailures = 0
    /// `append`는 소리 스레드에서 불린다.
    private let lock = NSLock()

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { done(status == .authorized) }
        }
    }

    @discardableResult
    func start(locale: String = VoiceLink.korean) -> Bool {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            return false
        }
        self.locale = locale
        self.recognizer = recognizer
        finished = ""
        text = ""
        quickFailures = 0
        running = true
        beginTask()
        return true
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    func stop() {
        guard running else { return }
        running = false
        lock.lock()
        let request = self.request
        self.request = nil
        lock.unlock()
        request?.endAudio()
        // 마지막 말이 확정될 시간을 조금 준 뒤 끝낸다.
        let task = self.task
        self.task = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { task?.cancel() }
    }

    /// 받아 적은 글은 그대로 두고, 이어지는 말부터 다른 언어로 받는다.
    func change(locale: String) {
        guard running, locale != self.locale,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else { return }
        self.locale = locale
        self.recognizer = recognizer
        lock.lock()
        let old = request
        request = nil
        lock.unlock()
        old?.endAudio()
        task?.cancel()
        finished = text
        quickFailures = 0
        beginTask()
    }

    private var currentRequest: SFSpeechAudioBufferRecognitionRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }

    private func beginTask() {
        guard let recognizer else { return }
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
        let base = finished
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                // 언어를 바꾸며 버린 작업의 늦은 결과는 받지 않는다. 멈춘 뒤의 마지막 결과는 받는다.
                guard let self, self.currentRequest === request || !self.running else { return }
                if let result {
                    self.text = Self.join(base, result.bestTranscription.formattedString)
                    self.onText?(self.text)
                }
                guard result?.isFinal == true || error != nil else { return }
                self.finished = self.text
                guard self.running else { return }
                self.quickFailures = Date().timeIntervalSince(self.taskStarted) < 1 ? self.quickFailures + 1 : 0
                if self.quickFailures < 3 {
                    self.beginTask()
                }
            }
        }
    }

    private static func join(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    /// 녹음 파일 전체를 글자로 바꾼다. 실시간으로 다 받지 못했을 때 쓴다.
    static func transcribeFile(_ url: URL, locale: String = VoiceLink.korean, done: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            done("")
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        var reported = false
        recognizer.recognitionTask(with: request) { result, error in
            _ = recognizer // 작업이 끝날 때까지 붙잡아 둔다
            guard !reported, result?.isFinal == true || error != nil else { return }
            reported = true
            let text = result?.bestTranscription.formattedString ?? ""
            DispatchQueue.main.async { done(text) }
        }
    }
}
