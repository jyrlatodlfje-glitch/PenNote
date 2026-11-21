import AVFoundation
import BackgroundTasks
import Speech
import UIKit
import WhisperKit

/// 녹음 파일을 텍스트로 바꾼다. 모두 기기 안에서 처리한다.
final class Transcriber: ObservableObject {
    enum Mode {
        /// Apple의 새 음성 엔진(iOS 26 이상). 빠르지만 한 번에 한 언어만 듣는다. 값은 "ko-KR" 같은 언어 코드.
        case fast(String)
        /// Whisper. 느리지만 한국어에 섞인 영어 단어를 영어 철자로 적는 편이다.
        case mixed
    }

    /// 인식 모델을 한 번만 올려 두고 함께 쓴다.
    static let shared = Transcriber()

    @Published private(set) var busy: URL?
    @Published private(set) var status = ""
    @Published var errorMessage: String?

    private var pipe: WhisperKit?
    private var task: Task<Void, Never>?
    /// 지금 돌고 있는 변환의 표. 그만둔 옛 변환이 늦게 끝나며 새 변환의 화면 잠금 막기를 풀지 않게 한다.
    private var currentRun = UUID()

    /// 화면을 꺼도 이어 하는 중인지(iOS 26 "계속 처리" 작업으로 돌고 있으면 참).
    @Published private(set) var continuesInBackground = false
    /// iOS 26의 BGContinuedProcessingTask. 낮은 iOS에서도 컴파일되게 AnyObject로 둔다.
    private var backgroundTask: AnyObject?
    /// 같은 변환을 새 표로 다시 시작하는 길(시작하자마자 아이폰이 끊으면 앞에서 다시 하려고).
    private var relaunch: ((UUID) -> Void)?
    private var backgroundStartedAt = Date.distantPast
    /// 마지막으로 진행이 오른 때. 오래 그대로면 아이폰이 "멈춘 작업"으로 보고 끊을 수 있다.
    private var lastProgressAt = Date()

    /// `speakers` 가 참이면 받아 적은 뒤 누가 말했는지 나눠 "화자 1: …" 으로 적는다.
    func transcribe(_ url: URL, mode: Mode, speakers: Bool = false, completion: @escaping (String) -> Void) {
        guard busy == nil else { return }
        busy = url
        status = "시작하는 중"
        // 화면을 켜 둔 채 기다릴 때 저절로 잠기지 않게 한다.
        UIApplication.shared.isIdleTimerDisabled = true
        let run = UUID()
        currentRun = run
        let launch: (UUID) -> Void = { [weak self] runID in
            self?.startWork(url, mode: mode, speakers: speakers, run: runID, completion: completion)
        }
        relaunch = launch
        let start = { launch(run) }
        // 애플 엔진(빠름)일 때만 화면을 꺼도 이어 하게 맡긴다. Whisper(한·영 혼합)는 그래픽 칩을 써서
        // 화면이 꺼지면 막힐 수 있어 예전처럼 화면을 켜 두고 한다.
        if #available(iOS 26.0, *), case .fast(_) = mode, submitContinuedTask(run: run, start: start) {
            return
        }
        start()
    }

    private func startWork(_ url: URL, mode: Mode, speakers: Bool, run: UUID,
                           completion: @escaping (String) -> Void) {
        guard currentRun == run else { return }
        task = Task { @MainActor in
            var succeeded = false
            // 모델을 처음 내려받는 동안처럼 진행이 한참 그대로일 때, 8초마다 1%씩 살짝 올려
            // 아이폰이 "멈춘 작업"으로 보고 화면 꺼진 동안 끊지 않게 한다(다음 단계 몫은 넘지 않음).
            let heartbeat = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    self?.nudgeProgress()
                }
            }
            defer {
                heartbeat.cancel()
                if self.currentRun == run {
                    UIApplication.shared.isIdleTimerDisabled = false
                    self.endBackgroundTask(success: succeeded)
                }
            }
            do {
                let started = Date()
                var text = ""
                var pieces: [SpokenPiece] = []
                // 진행 몫: 받아 적기 → (화자 구분이면) 0~70%, 아니면 0~95%.
                let writeShare = speakers ? 0.7 : 0.95
                if #available(iOS 26.0, *), case .fast(let language) = mode {
                    (text, pieces) = try await transcribeWithApple(url, language: language, share: writeShare)
                } else if case .fast(let language) = mode {
                    (text, pieces) = try await transcribeWithWhisper(url, language: String(language.prefix(2)))
                } else {
                    (text, pieces) = try await transcribeWithWhisper(url, language: "ko")
                }
                guard !Task.isCancelled else { return }
                if speakers, !pieces.isEmpty {
                    report(writeShare, "누가 말했는지 나누는 중 (처음 한 번은 모델 내려받기 — 인터넷 필요)")
                    do {
                        text = try await SpeakerLabeler.label(pieces, audio: url) { fraction in
                            Task { @MainActor [weak self] in
                                self?.report(writeShare + (0.98 - writeShare) * fraction,
                                             "누가 말했는지 나누는 중 \(Int(fraction * 100))%")
                            }
                        }
                    } catch {
                        // 화자 구분만 실패하면 받아 적은 글은 그대로 넣고 까닭을 맨 위에 적는다.
                        text = "[화자 구분은 하지 못했습니다: \(error.localizedDescription)]\n\n"
                            + text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    guard !Task.isCancelled else { return }
                }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                busy = nil
                if text.isEmpty {
                    errorMessage = "변환된 내용이 없습니다."
                } else {
                    report(1, "변환에 \(Int(Date().timeIntervalSince(started)))초 걸렸습니다")
                    succeeded = true
                    completion(text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                busy = nil
                errorMessage = "변환하지 못했습니다: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        busy = nil
        // 그만두면 화면 잠금 막기를 바로 푼다(옛 작업이 뒤에서 끝날 때까지 기다리지 않음).
        currentRun = UUID()
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask(success: false)
    }

    /// 화면 아래 글과(있으면) 잠금 화면의 진행 표시를 함께 고친다. fraction 은 0~1.
    private func report(_ fraction: Double, _ text: String) {
        status = text
        if #available(iOS 26.0, *), let bg = backgroundTask as? BGContinuedProcessingTask {
            let done = Int64((min(max(fraction, 0), 1) * 100).rounded())
            if done > bg.progress.completedUnitCount {
                bg.progress.completedUnitCount = done
                lastProgressAt = Date()
            }
            bg.updateTitle(bg.title, subtitle: text)
        }
    }

    /// 8초 넘게 진행이 그대로면 1% 올린다. 97%를 넘기지 않는다(끝은 실제로 끝났을 때만 100%).
    private func nudgeProgress() {
        guard #available(iOS 26.0, *), let bg = backgroundTask as? BGContinuedProcessingTask else { return }
        guard Date().timeIntervalSince(lastProgressAt) >= 8, bg.progress.completedUnitCount < 97 else { return }
        bg.progress.completedUnitCount += 1
        lastProgressAt = Date()
    }

    // MARK: 화면을 꺼도 이어 하기 (iOS 26 BGContinuedProcessingTask)

    /// 한 번 쓴 표는 다시 쓰지 않는다(같은 이름을 두 번 등록하면 앱이 멈춤). 시작하지 못하면 false → 예전처럼 화면을 켜 두고 한다.
    @available(iOS 26.0, *)
    private func submitContinuedTask(run: UUID, start: @escaping () -> Void) -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let identifier = "\(bundleID).transcribe.\(run.uuidString)"
        // SideStore가 번들 ID 끝에 팀 번호를 붙이므로, Info.plist에 적어 둔 허락 이름과 맞는지 먼저 본다.
        // 맞지 않는데 등록하면 거절되므로(멈추지는 않음) 미리 걸러 예전 방식으로 돌린다.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(where: { $0.hasSuffix(".*") && identifier.hasPrefix(String($0.dropLast())) }) else {
            return false
        }
        let started = StartFlag()
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask,
                  let self, self.currentRun == run, !started.value else {
                task.setTaskCompleted(success: false)
                return
            }
            started.value = true
            self.backgroundTask = continued
            self.continuesInBackground = true
            self.backgroundStartedAt = Date()
            self.lastProgressAt = Date()
            continued.progress.totalUnitCount = 100
            // 안쪽 클로저가 바깥의 weak self(변수)를 잡으면 동시성 검사에 걸릴 수 있어, 안쪽에서 직접 weak로 잡는다.
            continued.expirationHandler = {
                DispatchQueue.main.async { [weak self] in self?.expire(run: run) }
            }
            start()
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                       title: "녹음을 글자로 바꾸는 중",
                                                       subtitle: "시작하는 중")
        // 바로 시작할 수 없으면 줄 세우지 말고 실패시킨다 → 예전처럼 화면을 켜 두고 한다.
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            return false
        }
        // 제출은 됐는데 3초 안에 시작되지 않으면(애플 게시판에 이런 경우가 보고됨) 그냥 앞에서 시작한다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.currentRun == run, !started.value else { return }
            started.value = true
            start()
        }
        return true
    }

    /// 잠금 화면에서 취소했거나 아이폰이 시간을 끝냈을 때.
    private func expire(run: UUID) {
        guard currentRun == run else { return }
        task?.cancel()
        task = nil
        // 시작하자마자(5초 안) 끊겼고 회원님이 아직 앱을 보고 있으면, 예전처럼 앞에서 다시 한다.
        if UIApplication.shared.applicationState == .active,
           Date().timeIntervalSince(backgroundStartedAt) < 5,
           let relaunch {
            endBackgroundTask(success: false)
            let again = UUID()
            currentRun = again
            status = "화면을 켜 둔 채 다시 시작합니다"
            relaunch(again)
            return
        }
        busy = nil
        currentRun = UUID()
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTask(success: false)
        errorMessage = "화면이 꺼진 동안 하던 변환이 멈췄습니다(잠금 화면에서 취소했거나 아이폰이 멈춤). 다시 눌러 주세요."
    }

    private func endBackgroundTask(success: Bool) {
        if #available(iOS 26.0, *), let bg = backgroundTask as? BGContinuedProcessingTask {
            if success { bg.progress.completedUnitCount = bg.progress.totalUnitCount }
            bg.setTaskCompleted(success: success)
        }
        backgroundTask = nil
        continuesInBackground = false
    }

    @available(iOS 26.0, *)
    @MainActor
    private func transcribeWithApple(_ url: URL, language: String,
                                     share: Double) async throws -> (String, [SpokenPiece]) {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw NSError(domain: "PenNote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "이 언어는 빠른 변환을 지원하지 않습니다. '한·영 혼합'으로 변환해 보세요.",
            ])
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status = "음성 모델을 내려받는 중 (최초 1회)"
            try await request.downloadAndInstall()
        }
        report(0.02, "변환 중")

        let file = try AVAudioFile(forReading: url)
        // 녹음 길이(초) — 받아 적은 구간의 끝 시각으로 몇 % 했는지 셈.
        let duration = Double(file.length) / max(file.processingFormat.sampleRate, 1)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // 결과는 구간별로 차례로 나온다. 분석과 동시에 받아 모은다.
        // 화자 구분에 쓰려고 구간마다 녹음 속 시각(초)도 함께 모은다.
        let collector = Task { () -> (String, [SpokenPiece]) in
            var text = ""
            var pieces: [SpokenPiece] = []
            for try await result in transcriber.results {
                let piece = String(result.text.characters)
                text += piece
                let start = result.range.start.seconds
                let end = CMTimeRangeGetEnd(result.range).seconds
                pieces.append(SpokenPiece(start: start.isFinite ? start : 0,
                                          end: end.isFinite ? end : 0,
                                          text: piece))
                if duration > 0, end.isFinite {
                    let fraction = min(max(end / duration, 0), 1)
                    self.report(0.02 + (share - 0.02) * fraction, "글자로 바꾸는 중 \(Int(fraction * 100))%")
                }
            }
            return (text, pieces)
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    @MainActor
    private func transcribeWithWhisper(_ url: URL, language: String) async throws -> (String, [SpokenPiece]) {
        if pipe == nil {
            status = "인식 모델 준비 중 (최초 1회 내려받기, 몇 분 걸릴 수 있음)"
            pipe = try await WhisperKit()
        }
        guard let pipe else { return ("", []) }
        status = "변환 중 (느린 방식)"
        var options = DecodingOptions()
        options.language = language
        options.detectLanguage = false
        let results: [TranscriptionResult] = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let text = results.map { $0.text }.joined(separator: " ")
        // 구간 글에 섞여 나오는 <|…|> 표시는 빼고 쓴다.
        let pieces = results.flatMap { $0.segments }.map { segment in
            SpokenPiece(start: segment.start.isFinite ? Double(segment.start) : 0,
                        end: segment.end.isFinite ? Double(segment.end) : 0,
                        text: segment.text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "",
                                                                options: .regularExpression))
        }
        return (text, pieces)
    }
}

/// 등록한 작업이 시작됐는지 두 곳(시작 신호·3초 기다림)이 함께 보는 표. 모두 메인 스레드에서만 만진다.
private final class StartFlag {
    var value = false
}
