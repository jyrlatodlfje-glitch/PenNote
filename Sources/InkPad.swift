import SwiftUI
import UIKit

struct StrokeSample {
    let x: CGFloat
    let y: CGFloat
    let t: Int
}

/// 글씨 쓰는 칸. 펜을 떼고 `idleDelay` 동안 쉬면 쓴 획을 넘겨주고 스스로 비운다.
final class InkPadView: UIView {
    var onIdle: (([[StrokeSample]]) -> Void)?
    var idleDelay: TimeInterval = 0.8

    private var strokes: [[StrokeSample]] = []
    private var current: [StrokeSample] = []
    private var idleTimer: Timer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        isMultipleTouchEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func undoLastStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        setNeedsDisplay()
        scheduleIdle()
    }

    func clear() {
        idleTimer?.invalidate()
        strokes = []
        current = []
        setNeedsDisplay()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        idleTimer?.invalidate()
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
        return StrokeSample(x: p.x, y: p.y, t: Int(touch.timestamp * 1000))
    }

    private func finishStroke() {
        if !current.isEmpty {
            strokes.append(current)
            current = []
        }
        scheduleIdle()
    }

    private func scheduleIdle() {
        idleTimer?.invalidate()
        guard !strokes.isEmpty else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            let finished = self.strokes
            self.strokes = []
            self.setNeedsDisplay()
            self.onIdle?(finished)
        }
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
            path.move(to: CGPoint(x: first.x, y: first.y))
            if stroke.count == 1 {
                path.addLine(to: CGPoint(x: first.x + 0.5, y: first.y))
            }
            for s in stroke.dropFirst() {
                path.addLine(to: CGPoint(x: s.x, y: s.y))
            }
        }
        UIColor.label.setStroke()
        path.stroke()
    }
}

final class PadController: ObservableObject {
    fileprivate(set) weak var view: InkPadView?

    var size: CGSize { view?.bounds.size ?? .zero }

    func undoLastStroke() { view?.undoLastStroke() }
    func clear() { view?.clear() }
}

struct InkPad: UIViewRepresentable {
    let controller: PadController
    let onIdle: ([[StrokeSample]]) -> Void

    func makeUIView(context: Context) -> InkPadView {
        let view = InkPadView()
        controller.view = view
        return view
    }

    func updateUIView(_ view: InkPadView, context: Context) {
        view.onIdle = onIdle
    }
}
