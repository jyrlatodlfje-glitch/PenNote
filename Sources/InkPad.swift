import SwiftUI
import UIKit

struct StrokeSample {
    let x: CGFloat
    let y: CGFloat
    let t: Int
}

/// 글씨 쓰는 칸.
/// 쓴 글씨는 바로 지우지 않고 칸에 남겨 두며, 잠깐 멈출 때마다 칸의 글씨 **전체**를 다시 읽게 한다.
/// 그래서 "남대"까지 쓰고 멈췄다가 이어서 "문에서"를 써도 "남대문에서"로 한 번에 읽힌다.
/// 칸을 비우고 다음 글로 넘어가는 때는 (1) 왼쪽으로 크게 돌아와 새로 쓰기 시작할 때, (2) 한동안 쓰지 않을 때다.
final class InkPadView: UIView, UIGestureRecognizerDelegate {
    /// 칸에 있는 글씨 전체를 다시 읽어 달라는 요청. 획을 모두 지웠으면 빈 배열.
    var onUpdate: (([[StrokeSample]]) -> Void)?
    /// 칸을 비우고 다음 글로 넘어갔음. 왼쪽으로 돌아와 이어 쓴 경우 true.
    var onCommit: ((Bool) -> Void)?
    var readDelay: TimeInterval = 0.4
    var settleDelay: TimeInterval = 2.0

    private var strokes: [[StrokeSample]] = []
    private var current: [StrokeSample] = []
    private var readTimer: Timer?
    private var settleTimer: Timer?
    private var needsRead = false
    /// 글씨를 왼쪽으로 밀어낸 거리. 획의 x좌표는 이 값을 더한 "밀기 전 위치"로 저장한다.
    private var offsetX: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        isMultipleTouchEnabled = false
        contentMode = .redraw

        // 최신 iOS는 화면 어디서든 오른쪽으로 밀면 '뒤로 가기'가 된다. 글씨의 가로획이 그 동작에 먹히면
        // 목록 화면이 나오고 획도 중간에 끊긴다. 칸을 누르는 순간 인식되는 제스처를 하나 두고,
        // 다른 제스처는 이것이 실패해야만 시작하도록 해서 칸 안의 터치를 글씨 쓰기에만 쓴다.
        let guardGesture = UILongPressGestureRecognizer(target: self, action: #selector(ignoreGesture))
        guardGesture.minimumPressDuration = 0
        guardGesture.allowableMovement = .greatestFiniteMagnitude
        guardGesture.cancelsTouchesInView = false
        guardGesture.delaysTouchesBegan = false
        guardGesture.delaysTouchesEnded = false
        guardGesture.delegate = self
        addGestureRecognizer(guardGesture)
    }

    @objc private func ignoreGesture() {}

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func undoLastStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        needsRead = true
        setNeedsDisplay()
        schedule()
    }

    /// 아직 읽지 않은 글씨가 있으면 읽게 한 뒤 칸을 비운다. 키를 눌러 글을 확정할 때 쓴다.
    func finish() {
        readNow()
        reset()
    }

    /// 칸을 그냥 비운다.
    func clear() {
        reset()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        readTimer?.invalidate()
        settleTimer?.invalidate()
        // 쓴 글씨의 오른쪽 끝에서 왼쪽으로 크게 돌아와 시작하면 새 글로 보고 칸을 비운다.
        // 받침이나 점처럼 방금 쓴 글자로 돌아가는 획은 글자 한 개 폭(대략 글씨 높이) 안이므로 걸리지 않는다.
        let samples = strokes.flatMap { $0 }
        if let inkRight = samples.map({ $0.x }).max(),
           let inkTop = samples.map({ $0.y }).min(), let inkBottom = samples.map({ $0.y }).max() {
            let glyphSize = max(30, inkBottom - inkTop)
            let jumpBack = max(glyphSize * 1.8, bounds.width * 0.35)
            if touch.location(in: self).x < inkRight - offsetX - jumpBack {
                readNow()
                reset()
                onCommit?(true)
            }
        }
        current = [sample(touch)]
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let all = event?.coalescedTouches(for: touch) ?? [touch]
        current.append(contentsOf: all.map(sample))
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishStroke()
    }

    private func sample(_ touch: UITouch) -> StrokeSample {
        let p = touch.location(in: self)
        return StrokeSample(x: p.x + offsetX, y: p.y, t: Int(touch.timestamp * 1000))
    }

    private func finishStroke() {
        if !current.isEmpty {
            strokes.append(current)
            current = []
            needsRead = true
        }
        // 오른쪽 끝에 거의 닿았으면 다음 획을 쓸 자리가 없으니 바로 민다.
        makeRoom(ifBeyond: 0.85)
        schedule()
    }

    /// 글씨의 오른쪽 끝이 칸 폭의 `fraction`을 넘었으면, 글씨를 왼쪽으로 밀어 오른쪽에 쓸 자리를 만든다.
    /// 밀려난 글씨는 보이지 않을 뿐 그대로 남아 있어서 함께 읽힌다.
    private func makeRoom(ifBeyond fraction: CGFloat) {
        guard let inkRight = strokes.flatMap({ $0 }).map({ $0.x }).max(),
              inkRight - offsetX > bounds.width * fraction else { return }
        UIView.transition(with: self, duration: 0.15, options: .transitionCrossDissolve) {
            self.offsetX = inkRight - self.bounds.width * 0.3
            self.setNeedsDisplay()
            self.layer.displayIfNeeded()
        }
    }

    private func schedule() {
        readTimer?.invalidate()
        settleTimer?.invalidate()
        readTimer = Timer.scheduledTimer(withTimeInterval: readDelay, repeats: false) { [weak self] _ in
            self?.readNow()
        }
        settleTimer = Timer.scheduledTimer(withTimeInterval: settleDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.readNow()
            self.reset()
            self.onCommit?(false)
        }
    }

    private func readNow() {
        readTimer?.invalidate()
        guard needsRead else { return }
        needsRead = false
        // 잠깐 멈춘 틈에는 조금 더 일찍 밀어 둔다. 글자를 쓰는 도중에 밀리는 일을 줄이기 위해서다.
        makeRoom(ifBeyond: 0.6)
        onUpdate?(strokes)
    }

    private func reset() {
        readTimer?.invalidate()
        settleTimer?.invalidate()
        strokes = []
        current = []
        needsRead = false
        offsetX = 0
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        let baseline = UIBezierPath()
        let y = bounds.height * 0.72
        baseline.move(to: CGPoint(x: 12, y: y))
        baseline.addLine(to: CGPoint(x: bounds.width - 12, y: y))
        baseline.setLineDash([4, 4], count: 2, phase: 0)
        UIColor.separator.setStroke()
        baseline.stroke()

        let path = UIBezierPath()
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for stroke in strokes + [current] {
            guard let first = stroke.first else { continue }
            path.move(to: CGPoint(x: first.x - offsetX, y: first.y))
            if stroke.count == 1 {
                path.addLine(to: CGPoint(x: first.x - offsetX + 0.5, y: first.y))
            }
            for s in stroke.dropFirst() {
                path.addLine(to: CGPoint(x: s.x - offsetX, y: s.y))
            }
        }
        if offsetX > 0 {
            // 왼쪽에 밀려난 글씨가 더 있다는 표시
            UIColor.tertiaryLabel.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: 8, width: 3, height: bounds.height - 16)).fill()
        }
        UIColor.label.setStroke()
        path.stroke()
    }
}

final class PadController: ObservableObject {
    fileprivate(set) weak var view: InkPadView?

    var size: CGSize { view?.bounds.size ?? .zero }

    func undoLastStroke() { view?.undoLastStroke() }
    func finish() { view?.finish() }
    func clear() { view?.clear() }
}

struct InkPad: UIViewRepresentable {
    let controller: PadController
    let onUpdate: ([[StrokeSample]]) -> Void
    let onCommit: (Bool) -> Void

    func makeUIView(context: Context) -> InkPadView {
        let view = InkPadView()
        controller.view = view
        return view
    }

    func updateUIView(_ view: InkPadView, context: Context) {
        view.onUpdate = onUpdate
        view.onCommit = onCommit
    }
}
