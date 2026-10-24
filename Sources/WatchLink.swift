import AVFoundation
import WatchConnectivity

/// 워치에서 시작한 음성 메모를 받는다. 워치가 보내는 소리를 글자로 바꿔 워치에 돌려주고,
/// 끝나서 소리 파일이 오면 새 노트로 저장한 뒤 파일 전체로 한 번 더 받아 적는다.
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    private var store: NoteStore?
    private var transcriber: LiveTranscriber?
    private var sessionID: String?
    /// 메모별로 실시간으로 받은 마지막 글
    private var liveTexts: [String: String] = [:]
    /// 메모별로 마지막에 고른 언어
    private var locales: [String: String] = [:]

    func activate(store: NoteStore) {
        self.store = store
        // 처음 켤 때 음성 인식 허락을 받아 둔다. 워치가 아이폰을 깨운 때(백그라운드)에는 물어볼 수 없다.
        LiveTranscriber.requestPermission { _ in }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async { self.handle(message) }
    }

    func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        guard let buffer = Self.buffer(from: messageData) else { return }
        DispatchQueue.main.async { self.transcriber?.append(buffer) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let metadata = file.metadata ?? [:]
        let id = metadata[VoiceLink.session] as? String ?? UUID().uuidString
        let started = metadata[VoiceLink.started] as? Date ?? Date()
        let locale = metadata[VoiceLink.locale] as? String ?? VoiceLink.korean
        let noteID = UUID(uuidString: id) ?? UUID()
        // 받은 파일은 이 함수가 끝나면 지워지므로 바로 옮긴다.
        var target = VoiceMemoSaver.newRecordingURL(noteID: noteID, date: started)
            .deletingPathExtension().appendingPathExtension(file.fileURL.pathExtension)
        if FileManager.default.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "." + target.pathExtension)
        }
        do {
            try FileManager.default.moveItem(at: file.fileURL, to: target)
        } catch {
            try? FileManager.default.copyItem(at: file.fileURL, to: target)
        }
        DispatchQueue.main.async { self.finish(id: id, noteID: noteID, started: started, fileLocale: locale) }
    }

    // MARK: -

    private func handle(_ message: [String: Any]) {
        guard let kind = message[VoiceLink.kind] as? String,
              let id = message[VoiceLink.session] as? String else { return }
        switch kind {
        case VoiceLink.start:
            transcriber?.stop()
            let locale = message[VoiceLink.locale] as? String ?? VoiceLink.korean
            let transcriber = LiveTranscriber()
            transcriber.onText = { [weak self] text in
                self?.liveTexts[id] = text
                self?.sendLive(id: id, text: text)
            }
            transcriber.start(locale: locale)
            self.transcriber = transcriber
            sessionID = id
            locales[id] = locale
        case VoiceLink.language:
            guard let locale = message[VoiceLink.locale] as? String else { return }
            locales[id] = locale
            if sessionID == id {
                transcriber?.change(locale: locale)
            }
        case VoiceLink.stop:
            if sessionID == id {
                transcriber?.stop()
                transcriber = nil
                sessionID = nil
            }
        default:
            break
        }
    }

    private func finish(id: String, noteID: UUID, started: Date, fileLocale: String) {
        guard let store else { return }
        if sessionID == id {
            transcriber?.stop()
            transcriber = nil
            sessionID = nil
        }
        let liveText = liveTexts.removeValue(forKey: id) ?? ""
        let locale = locales.removeValue(forKey: id) ?? fileLocale
        guard !store.notes.contains(where: { $0.id == noteID }) else { return }
        VoiceMemoSaver.save(id: noteID, date: started, text: liveText, fromWatch: true, folderID: nil, store: store)
        // 손목을 내려 실시간 전송이 끊긴 구간이 있을 수 있으므로 파일 전체로 다시 받아 적는다.
        VoiceMemoSaver.refine(noteID: noteID, liveText: liveText, locale: locale, store: store)
    }

    private func sendLive(id: String, text: String) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        // 워치 화면에는 끝부분만 보이면 된다. 메시지 크기 제한도 지킨다.
        let message: [String: Any] = [VoiceLink.kind: VoiceLink.live, VoiceLink.session: id,
                                      VoiceLink.text: String(text.suffix(600))]
        WCSession.default.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    /// 워치가 보낸 16비트 정수 소리를 음성 인식이 받는 32비트 실수 소리로 바꾼다.
    static func buffer(from data: Data) -> AVAudioPCMBuffer? {
        let count = data.count / 2
        guard count > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: VoiceLink.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let output = buffer.floatChannelData?[0] else { return nil }
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                output[index] = Float(samples[index]) / 32768
            }
        }
        buffer.frameLength = AVAudioFrameCount(count)
        return buffer
    }
}
