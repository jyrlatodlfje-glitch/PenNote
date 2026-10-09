import AVFoundation
import UIKit

/// 노트 하나에 딸린 녹음. 전화 등으로 끊기면 같은 파일에 자동으로 이어서 녹음한다.
final class AudioRecorder: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var isInterrupted = false
    @Published private(set) var recordings: [URL] = []
    @Published private(set) var playing: URL?
    @Published var errorMessage: String?

    private let folder: URL
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []

    static func folder(for noteID: UUID) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings")
            .appendingPathComponent(noteID.uuidString)
    }

    init(noteID: UUID) {
        folder = Self.folder(for: noteID)
        super.init()

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, self.isRecording,
                  let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.isInterrupted = true
            case .ended:
                self.resumeAfterInterruption()
            @unknown default:
                break
            }
        })
        // 통화 종료 알림이 오지 않거나 백그라운드에서 재개에 실패한 경우, 앱으로 돌아올 때 다시 시도한다.
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRecording, self.isInterrupted else { return }
            self.resumeAfterInterruption()
        })
        reload()
    }

    deinit {
        recorder?.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var elapsed: TimeInterval {
        recorder?.currentTime ?? 0
    }

    func toggleRecording() {
        if isRecording {
            stop()
            return
        }
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.start()
                } else {
                    self?.errorMessage = "설정 > 펜노트에서 마이크 접근을 허용해 주세요."
                }
            }
        }
    }

    func togglePlayback(_ url: URL) {
        if playing == url {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            try activateSession()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            playing = url
        } catch {
            errorMessage = "재생하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func delete(_ url: URL) {
        if playing == url { stopPlayback() }
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playing = nil
    }

    private func start() {
        stopPlayback()
        do {
            try activateSession()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = folder.appendingPathComponent(formatter.string(from: Date()) + ".m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else {
                errorMessage = "녹음을 시작하지 못했습니다."
                return
            }
            self.recorder = recorder
            isRecording = true
            isInterrupted = false
        } catch {
            errorMessage = "녹음을 시작하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func stop() {
        recorder?.stop()
        recorder = nil
        isRecording = false
        isInterrupted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        reload()
    }

    private func resumeAfterInterruption() {
        guard let recorder else { return }
        do {
            try activateSession()
            if recorder.record() {
                isInterrupted = false
            }
        } catch {
            // 통화가 아직 진행 중이면 실패한다. 다음 알림에서 다시 시도한다.
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playing = nil
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
    }

    private func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        recordings = files
            .filter { $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
