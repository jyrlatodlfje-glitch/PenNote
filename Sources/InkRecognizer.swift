import Foundation
import MLKitCommon
import MLKitDigitalInkRecognition

enum InkLanguage: String, CaseIterable {
    case korean = "ko"
    case english = "en-US"

    var label: String {
        switch self {
        case .korean: return "한"
        case .english: return "EN"
        }
    }
}

final class InkRecognizer: ObservableObject {
    enum ModelState: Equatable {
        case downloading
        case ready
        case failed(String)
    }

    @Published private(set) var state: ModelState = .downloading
    @Published var language: InkLanguage = .korean {
        didSet { prepare() }
    }

    private var recognizer: DigitalInkRecognizer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mlkitModelDownloadDidSucceed, object: nil, queue: .main) { [weak self] _ in
            self?.prepare()
        })
        observers.append(center.addObserver(forName: .mlkitModelDownloadDidFail, object: nil, queue: .main) { [weak self] _ in
            self?.state = .failed("인식 모델을 내려받지 못했습니다. 인터넷 연결을 확인하세요.")
        })
        prepare()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func prepare() {
        recognizer = nil
        let tag = language.rawValue
        guard let identifier = DigitalInkRecognitionModelIdentifier.allModelIdentifiers()
            .first(where: { $0.languageTag == tag }) else {
            state = .failed("지원하지 않는 언어입니다: \(tag)")
            return
        }
        let model = DigitalInkRecognitionModel(modelIdentifier: identifier)
        let manager = ModelManager.modelManager()
        if manager.isModelDownloaded(model) {
            recognizer = DigitalInkRecognizer.digitalInkRecognizer(
                options: DigitalInkRecognizerOptions(model: model))
            state = .ready
        } else {
            state = .downloading
            manager.download(model, conditions: ModelDownloadConditions(
                allowsCellularAccess: true, allowsBackgroundDownloading: true))
        }
    }

    /// 인식 후보를 가능성 높은 순서로 돌려준다. 모델이 준비되지 않았으면 빈 배열.
    func recognize(_ strokes: [[StrokeSample]], completion: @escaping ([String]) -> Void) {
        guard let recognizer, !strokes.isEmpty else {
            completion([])
            return
        }
        let ink = Ink(strokes: strokes.map { samples in
            Stroke(points: samples.map { StrokePoint(x: Float($0.x), y: Float($0.y), t: $0.t) })
        })
        recognizer.recognize(ink: ink) { result, _ in
            let texts = result?.candidates.map { $0.text } ?? []
            DispatchQueue.main.async { completion(texts) }
        }
    }
}
