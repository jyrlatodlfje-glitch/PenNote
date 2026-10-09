import UIKit
import WhisperKit

/// 녹음 파일을 텍스트로 바꾼다. 여러 언어를 함께 다루는 Whisper 모델을 기기 안에서 돌린다.
final class Transcriber: ObservableObject {
    @Published private(set) var busy: URL?
    @Published private(set) var status = ""
    @Published var errorMessage: String?

    private var pipe: WhisperKit?
    private var task: Task<Void, Never>?

    /// `language`가 nil이면 구간마다 언어를 자동으로 판별한다.
    func transcribe(_ url: URL, language: String?, completion: @escaping (String) -> Void) {
        guard busy == nil else { return }
        busy = url
        // 변환 중 화면이 잠기면 작업이 멈추므로 자동 잠금을 막는다.
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task { @MainActor in
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                if pipe == nil {
                    status = "인식 모델 준비 중 (최초 1회 내려받기)"
                    pipe = try await WhisperKit()
                }
                guard let pipe else { return }
                status = "변환 중"
                var options = DecodingOptions()
                options.language = language
                options.detectLanguage = language == nil
                let results: [TranscriptionResult] = try await pipe.transcribe(
                    audioPath: url.path, decodeOptions: options)
                guard !Task.isCancelled else { return }
                let text = results.map { $0.text }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                busy = nil
                if text.isEmpty {
                    errorMessage = "변환된 내용이 없습니다."
                } else {
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
}
