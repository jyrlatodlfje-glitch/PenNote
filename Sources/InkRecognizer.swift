import MLKitCommon
import MLKitDigitalInkRecognition
import UIKit

enum InkLanguage: String, CaseIterable {
    case auto
    case korean = "ko"
    case english = "en-US"

    var label: String {
        switch self {
        case .auto: return "자동"
        case .korean: return "한"
        case .english: return "EN"
        }
    }

    var next: InkLanguage {
        switch self {
        case .auto: return .korean
        case .korean: return .english
        case .english: return .auto
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
    @Published var language: InkLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: "inkLanguage")
            refreshState()
        }
    }

    private var recognizers: [InkLanguage: DigitalInkRecognizer] = [:]
    private var downloadFailed = false
    private var jobs: [(@escaping () -> Void) -> Void] = []
    private var jobRunning = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let saved = UserDefaults.standard.string(forKey: "inkLanguage").flatMap(InkLanguage.init(rawValue:))
        language = saved ?? .auto

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .mlkitModelDownloadDidSucceed, object: nil, queue: .main) { [weak self] _ in
            self?.prepare()
        })
        observers.append(center.addObserver(forName: .mlkitModelDownloadDidFail, object: nil, queue: .main) { [weak self] _ in
            self?.downloadFailed = true
            self?.refreshState()
        })
        prepare()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 한국어·영어 모델을 모두 준비한다. 없는 모델은 내려받기를 시작한다.
    func prepare() {
        let manager = ModelManager.modelManager()
        for language in [InkLanguage.korean, .english] where recognizers[language] == nil {
            guard let identifier = DigitalInkRecognitionModelIdentifier.allModelIdentifiers()
                .first(where: { $0.languageTag == language.rawValue }) else { continue }
            let model = DigitalInkRecognitionModel(modelIdentifier: identifier)
            if manager.isModelDownloaded(model) {
                recognizers[language] = DigitalInkRecognizer.digitalInkRecognizer(
                    options: DigitalInkRecognizerOptions(model: model))
            } else {
                manager.download(model, conditions: ModelDownloadConditions(
                    allowsCellularAccess: true, allowsBackgroundDownloading: true))
            }
        }
        refreshState()
    }

    /// 인식 후보를 가능성 높은 순서로 돌려준다. 모델이 준비되지 않았으면 빈 배열.
    /// `area`는 글씨 칸의 크기, `preceding`은 커서 앞의 글. 둘 다 기호와 대소문자 판별을 돕는다.
    func recognize(_ strokes: [[StrokeSample]], area: CGSize, preceding: String,
                   completion: @escaping ([String]) -> Void) {
        // 이어서 쓴 글이 순서대로 들어가도록, 앞 요청이 끝난 뒤에 다음 요청을 처리한다.
        jobs.append { [weak self] done in
            guard let self else { return }
            self.perform(strokes, area: area, preceding: preceding) { texts in
                completion(texts)
                done()
            }
        }
        runNextJob()
    }

    private func runNextJob() {
        guard !jobRunning, !jobs.isEmpty else { return }
        jobRunning = true
        let job = jobs.removeFirst()
        job { [weak self] in
            self?.jobRunning = false
            self?.runNextJob()
        }
    }

    private func perform(_ strokes: [[StrokeSample]], area: CGSize, preceding: String,
                         completion: @escaping ([String]) -> Void) {
        guard !strokes.isEmpty else {
            completion([])
            return
        }
        // 점·짧은 줄처럼 모양만으로 알 수 있는 기호는 인식 결과보다 앞에 둔다.
        let symbol = Self.symbol(for: strokes)
        let finish: ([String]) -> Void = { texts in
            if let symbol {
                completion([symbol] + texts.filter { $0 != symbol })
            } else {
                completion(texts)
            }
        }
        let ink = Ink(strokes: strokes.map { samples in
            Stroke(points: samples.map { StrokePoint(x: Float($0.x), y: Float($0.y), t: $0.t) })
        })
        let context = DigitalInkRecognitionContext(
            preContext: String(preceding.suffix(20)),
            writingArea: WritingArea(width: Float(area.width), height: Float(area.height)))
        guard language == .auto else {
            run(language, ink: ink, context: context, completion: finish)
            return
        }
        // 자동: 두 언어로 모두 읽은 뒤 더 그럴듯한 쪽을 고른다.
        run(.korean, ink: ink, context: context) { [weak self] korean in
            guard let self else { return }
            self.run(.english, ink: ink, context: context) { english in
                finish(Self.merge(korean: korean, english: english))
            }
        }
    }

    private func run(_ language: InkLanguage, ink: Ink, context: DigitalInkRecognitionContext,
                     completion: @escaping ([String]) -> Void) {
        guard let recognizer = recognizers[language] else {
            completion([])
            return
        }
        recognizer.recognize(ink: ink, context: context) { result, _ in
            let texts = result?.candidates.map { $0.text } ?? []
            DispatchQueue.main.async { completion(texts) }
        }
    }

    private func refreshState() {
        let ready = language == .auto ? !recognizers.isEmpty : recognizers[language] != nil
        if ready {
            state = .ready
        } else if downloadFailed {
            state = .failed("인식 모델을 내려받지 못했습니다. 인터넷 연결을 확인하세요.")
        } else {
            state = .downloading
        }
    }

    // MARK: - 기호

    /// 획의 모양만으로 `.` `-` `:` `=` 를 가려낸다. 해당하지 않으면 nil.
    private static func symbol(for strokes: [[StrokeSample]]) -> String? {
        let boxes = strokes.map { stroke -> CGRect in
            let xs = stroke.map { $0.x }
            let ys = stroke.map { $0.y }
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
                return .zero
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        func isDot(_ box: CGRect) -> Bool {
            max(box.width, box.height) < 10
        }
        func isDash(_ box: CGRect) -> Bool {
            box.width >= 14 && box.height < max(8, box.width * 0.2)
        }

        if boxes.count == 1 {
            if isDot(boxes[0]) { return "." }
            if isDash(boxes[0]) { return "-" }
        } else if boxes.count == 2 {
            let gap = abs(boxes[0].midY - boxes[1].midY)
            if isDot(boxes[0]), isDot(boxes[1]), abs(boxes[0].midX - boxes[1].midX) < 14, gap > 8 {
                return ":"
            }
            if isDash(boxes[0]), isDash(boxes[1]), boxes[0].minX < boxes[1].maxX, boxes[1].minX < boxes[0].maxX,
               gap > 5, gap < 45 {
                return "="
            }
        }
        return nil
    }

    // MARK: - 언어 자동 판별

    /// 고른 언어의 후보를 앞에 두고, 다른 언어의 1순위를 바로 뒤에 두어 한 번 눌러 고칠 수 있게 한다.
    private static func merge(korean: [String], english: [String]) -> [String] {
        guard let bestKorean = korean.first else { return english }
        guard let bestEnglish = english.first else { return korean }
        let useEnglish = prefersEnglish(korean: bestKorean, english: bestEnglish)
        let primary = useEnglish ? english : korean
        let secondary = useEnglish ? korean : english

        var merged: [String] = []
        for text in [primary[0], secondary[0]] + primary.dropFirst() + secondary.dropFirst()
        where !merged.contains(text) {
            merged.append(text)
        }
        return merged
    }

    private static func prefersEnglish(korean: String, english: String) -> Bool {
        let hasHangul = korean.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value)
                || (0x3131...0x318E).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value)
        }
        // 한국어 모델조차 한글을 하나도 읽지 못했으면 영어·숫자로 본다.
        guard hasHangul else { return true }
        // 한글로도 읽히지만, 영어로 읽은 결과가 모두 사전에 있는 단어면 영어로 본다.
        return isEnglishWords(english)
    }

    private static func isEnglishWords(_ text: String) -> Bool {
        guard UITextChecker.availableLanguages.contains("en_US") else { return false }
        let words = text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.contains(where: { $0.count >= 2 }) else { return false }
        let checker = UITextChecker()
        return words.allSatisfy { word in
            guard word.allSatisfy({ $0.isASCII }) else { return false }
            if word.count == 1 {
                return ["a", "i"].contains(word.lowercased())
            }
            let range = NSRange(location: 0, length: (word as NSString).length)
            let misspelled = checker.rangeOfMisspelledWord(
                in: word, range: range, startingAt: 0, wrap: false, language: "en_US")
            return misspelled.location == NSNotFound
        }
    }
}
