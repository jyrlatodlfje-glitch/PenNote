import AVFoundation
import WatchConnectivity

/// 워치 마이크로 녹음하면서 소리를 아이폰에 보내고, 아이폰이 바꾼 글자를 받아 보여 준다.
/// 끝나면 소리 파일을 아이폰으로 보내고, 아이폰이 새 노트로 저장한다.
final class WatchRecorder: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var text = ""
    @Published private(set) var started = Date()
    @Published private(set) var phoneReachable = false
    /// 받아 적는 언어. 평소 한국어, 외국 분과 대화할 때 English. 고른 것을 기억한다.
    @Published private(set) var locale = VoiceLink.savedLocale
    @Published var message: String?

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var fileURL: URL?
    private var converter: AVAudioConverter?
    private var sessionID = UUID()
    /// 소리 스레드에서 모아 두었다가 약 0.5초씩 보낸다.
    private var pending = Data()
    private let sendQueue = DispatchQueue(label: "pennote.watch.send")

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    /// 한국어 ↔ English. 받아 적는 도중에도 바꿀 수 있다.
    func toggleLanguage() {
        locale = locale == VoiceLink.english ? VoiceLink.korean : VoiceLink.english
        UserDefaults.standard.set(locale, forKey: VoiceLink.savedLocaleKey)
        if isRecording {
            send([VoiceLink.kind: VoiceLink.language, VoiceLink.session: sessionID.uuidString, VoiceLink.locale: locale])
        }
    }

    func start() {
        guard !isRecording else { return }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else {
                    self?.message = "워치 설정 > 개인정보 보호 > 마이크에서 PenNote를 허용해 주세요."
                    return
                }
                self?.begin()
            }
        }
    }

    private func begin() {
        guard !isRecording else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            sessionID = UUID()
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let file = try Self.openFile(at: folder.appendingPathComponent(sessionID.uuidString + ".m4a"), format: format)
            self.file = file
            fileURL = file.url
            converter = AVAudioConverter(from: format, to: VoiceLink.streamFormat)
            sendQueue.sync { pending = Data() }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.handle(buffer)
            }
            engine.prepare()
            try engine.start()
            started = Date()
            text = ""
            message = nil
            isRecording = true
            send([VoiceLink.kind: VoiceLink.start, VoiceLink.session: sessionID.uuidString, VoiceLink.locale: locale])
        } catch {
            message = "녹음을 시작하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        let id = sessionID.uuidString
        let started = self.started
        let locale = self.locale
        let url = fileURL
        sendQueue.async { [weak self] in
            guard let self else { return }
            // 남은 소리를 먼저 보내고 끝을 알린다.
            if !self.pending.isEmpty, WCSession.default.isReachable {
                WCSession.default.sendMessageData(self.pending, replyHandler: nil, errorHandler: nil)
            }
            self.pending = Data()
            DispatchQueue.main.async {
                self.send([VoiceLink.kind: VoiceLink.stop, VoiceLink.session: id])
                guard let url, WCSession.default.activationState == .activated else {
                    self.message = "아이폰과 연결되지 않아 보내지 못했습니다."
                    return
                }
                WCSession.default.transferFile(url, metadata: [VoiceLink.session: id, VoiceLink.started: started,
                                                               VoiceLink.locale: locale])
                self.message = "아이폰 PenNote로 보냅니다. 새 노트로 저장됩니다."
            }
        }
    }

    /// 소리 스레드에서 불린다: 파일에 쓰고, 16kHz로 줄여 아이폰에 보낸다.
    private func handle(_ buffer: AVAudioPCMBuffer) {
        try? file?.write(from: buffer)
        guard let converter else { return }
        let ratio = VoiceLink.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: VoiceLink.streamFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData?[0] else { return }
        let data = Data(bytes: samples, count: Int(output.frameLength) * 2)
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.pending.append(data)
            guard self.pending.count >= 16_000 else { return }
            let chunk = self.pending
            self.pending = Data()
            if WCSession.default.activationState == .activated, WCSession.default.isReachable {
                WCSession.default.sendMessageData(chunk, replyHandler: nil, errorHandler: nil)
            }
        }
    }

    private func send(_ message: [String: Any]) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    /// m4a(AAC)로 쓸 파일을 연다. 안 되면 caf(압축 없음)로 연다.
    private static func openFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
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

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.phoneReachable = session.isReachable }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.phoneReachable = session.isReachable }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[VoiceLink.kind] as? String == VoiceLink.live,
              let id = message[VoiceLink.session] as? String,
              let text = message[VoiceLink.text] as? String else { return }
        DispatchQueue.main.async {
            guard id == self.sessionID.uuidString else { return }
            self.text = text
        }
    }

    func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        DispatchQueue.main.async {
            if error == nil {
                try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
                self.message = "아이폰 PenNote에 저장했습니다."
            } else {
                self.message = "아이폰으로 보내지 못했습니다. 녹음은 워치에 남아 있습니다."
            }
        }
    }
}
