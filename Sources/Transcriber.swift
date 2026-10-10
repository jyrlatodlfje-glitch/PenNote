import AVFoundation
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

    func transcribe(_ url: URL, mode: Mode, completion: @escaping (String) -> Void) {
        guard busy == nil else { return }
        busy = url
        // 변환 중 화면이 잠기면 작업이 멈추므로 자동 잠금을 막는다.
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { @MainActor in
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let started = Date()
                var text = ""
                if #available(iOS 26.0, *), case .fast(let language) = mode {
                    text = try await transcribeWithApple(url, language: language)
                } else if case .fast(let language) = mode {
                    text = try await transcribeWithWhisper(url, language: String(language.prefix(2)))
                } else {
                    text = try await transcribeWithWhisper(url, language: "ko")
                }
                guard !Task.isCancelled else { return }
                text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                busy = nil
                if text.isEmpty {
                    errorMessage = "변환된 내용이 없습니다."
                } else {
                    status = "변환에 \(Int(Date().timeIntervalSince(started)))초 걸렸습니다"
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
    }

    @available(iOS 26.0, *)
    @MainActor
    private func transcribeWithApple(_ url: URL, language: String) async throws -> String {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw NSError(domain: "PenNote", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "이 언어는 빠른 변환을 지원하지 않습니다. '한·영 혼합'으로 변환해 보세요.",
            ])
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [], attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status = "음성 모델을 내려받는 중 (최초 1회)"
            try await request.downloadAndInstall()
        }
        status = "변환 중"

        let file = try AVAudioFile(forReading: url)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        // 결과는 구간별로 차례로 나온다. 분석과 동시에 받아 모은다.
        let collector = Task { () -> String in
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
            }
            return text
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return try await collector.value
    }

    @MainActor
    private func transcribeWithWhisper(_ url: URL, language: String) async throws -> String {
        if pipe == nil {
            status = "인식 모델 준비 중 (최초 1회 내려받기, 몇 분 걸릴 수 있음)"
            pipe = try await WhisperKit()
        }
        guard let pipe else { return "" }
        status = "변환 중 (느린 방식)"
        var options = DecodingOptions()
        options.language = language
        options.detectLanguage = false
        let results: [TranscriptionResult] = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ")
    }
}
