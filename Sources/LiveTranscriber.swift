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
    /// 지금 작업에서 마지막으로 들은 글. 작업이 끝날 때 빈 글이 와도 이 글을 지키려고 (2026-11-15).
    private var taskHeard = ""
    /// 지금 작업에서 이미 굳힌 글(앞 작업들 + 이 작업 안에서 쉼 전에 들은 글)
    private var taskBase = ""
    private var lastResultAt = Date()
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
        lastResultAt = Date()
        taskBase = finished
        taskHeard = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                // 언어를 바꾸며 버린 작업의 늦은 결과는 받지 않는다. 멈춘 뒤의 마지막 결과는 받는다.
                guard let self, self.currentRequest === request || !self.running else { return }
                if let result {
                    let heard = result.bestTranscription.formattedString
                    let gap = Date().timeIntervalSince(self.lastResultAt)
                    self.lastResultAt = Date()
                    if !heard.isEmpty {
                        // iOS 18부터 잠깐 쉬었다 말하면 앞 글을 빼고 새 말만 보낸다.
                        // 새 글이 앞 글과 이어지지 않으면 앞 글을 굳혀 두고 뒤에 붙인다 (2026-11-15 실기기: "방금 말하는것만 남아").
                        if SpeechText.isRestart(previous: self.taskHeard, new: heard, gap: gap) {
                            self.taskBase = Self.join(self.taskBase, self.taskHeard)
                        }
                        self.taskHeard = heard
                    }
                    self.text = Self.join(self.taskBase, self.taskHeard)
                    self.onText?(self.text)
                }
                guard result?.isFinal == true || error != nil else { return }
                self.finished = self.text
                guard self.running else { return }
                self.quickFailures = Date().timeIntervalSince(self.taskStarted) < 1 ? self.quickFailures + 1 : 0
                if self.quickFailures < 3 {
                    self.beginTask()
                } else {
                    // 연달아 실패해도(전화 직후 등) 그만두지 않고 2초 쉬었다 다시 듣는다 — 노트 마이크(Dictation)와 같게.
                    // 전에는 여기서 멈춰 남은 녹음 내내 글이 안 나왔다(2026-11-21 검토).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.running, self.currentRequest === request else { return }
                        self.quickFailures = 0
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

/// 음성 인식 글을 견주는 도구 (노트 마이크 `Dictation`, 음성 메모 `LiveTranscriber` 함께 씀).
enum SpeechText {
    /// 글자와 숫자만 남긴다. 쉼표·띄어쓰기가 고쳐져도 같은 말인지 견주려고.
    static func letters(_ text: String) -> [Character] {
        Array(text.filter { $0.isLetter || $0.isNumber })
    }

    /// 새로 온 글이 앞 글을 고쳐 쓴 것(이어짐)이 아니라, 쉼 뒤에 새로 시작한 글인지.
    /// - 말하는 동안의 고쳐 쓰기는 0.1~0.3초 간격으로 오고 앞부분이 거의 같다.
    /// - 쉼 뒤 새 글은 0.8초 넘게 지나서 오고 앞부분이 다르다.
    /// 헷갈리면 "새로 시작"으로 본다 — 같은 말이 두 번 나올 수는 있어도 앞 글을 지우지는 않게.
    static func isRestart(previous: String, new: String, gap: TimeInterval) -> Bool {
        let a = letters(previous), b = letters(new)
        guard !a.isEmpty, !b.isEmpty, gap >= 0.8 else { return false }
        var common = 0
        while common < a.count, common < b.count, a[common] == b[common] { common += 1 }
        return Double(common) < Double(min(a.count, b.count)) * 0.6
    }
}
