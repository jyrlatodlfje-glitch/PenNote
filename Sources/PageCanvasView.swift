import PencilKit
import UIKit

enum PageTool: Equatable {
    case select, pen, highlighter, eraser, lasso
}

/// 노트 한 장. 속지·사진·글자는 필기 레이어 아래에 깔리고, 그 위에 PencilKit으로 그린다.
final class PageCanvasView: UIView, PKCanvasViewDelegate, UITextViewDelegate, UIGestureRecognizerDelegate {
    static let lineHeight: CGFloat = 30

    private static let textAttributes: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return [
            .font: UIFont.systemFont(ofSize: 17),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph,
        ]
    }()

    var onChange: ((Note) -> Void)?
    var onSelectionChange: ((Bool) -> Void)?
    var useKeyboard = false {
        didSet { if oldValue != useKeyboard { applyInputView() } }
    }

    private(set) var note: Note
    private let canvas = PKCanvasView()
    private let underlay = UIView()
    private let handle = UIView()
    private var textViews: [UUID: UITextView] = [:]
    private var imageViews: [UUID: UIImageView] = [:]
    private var selectedID: UUID?
    private var currentTool: PageTool?
    private var currentColor: UIColor?
    private var laidOutWidth: CGFloat = 0
    private var dragStart = CGRect.zero
    private var isResizing = false

    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    private lazy var movePan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
    private lazy var lassoPan = UIPanGestureRecognizer(target: self, action: #selector(handleLasso))

    // 올가미: 둘러싼 글자·사진·필기를 한꺼번에 옮긴다.
    private let overlay = UIView()
    private let lassoLayer = CAShapeLayer()
    private var lassoPath: UIBezierPath?
    private var lassoItems: [UUID] = []
    private var lassoStrokes: [Int] = []
    private var lassoMoving = false
    private var lassoMoved = CGPoint.zero
    private var lastLassoPoint = CGPoint.zero
    private var hasLassoSelection: Bool { !lassoItems.isEmpty || !lassoStrokes.isEmpty }

    init(note: Note) {
        self.note = note
        super.init(frame: .zero)
        // 종이는 다크 모드에서도 흰색으로 둔다.
        overrideUserInterfaceStyle = .light
        backgroundColor = .white

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = true
        canvas.delegate = self
        if let drawing = try? PKDrawing(data: note.drawing) {
            canvas.drawing = drawing
        }
        addSubview(canvas)
        canvas.insertSubview(underlay, at: 0)

        handle.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        handle.backgroundColor = .systemBlue
        handle.layer.cornerRadius = 10
        handle.isHidden = true
        underlay.addSubview(handle)

        for item in note.images {
            addImageView(for: item)
        }
        for item in note.texts {
            addTextView(for: item)
        }
        applyTemplate()

        overlay.isUserInteractionEnabled = false
        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]
        overlay.layer.addSublayer(lassoLayer)
        canvas.addSubview(overlay)

        lassoPan.maximumNumberOfTouches = 1
        for gesture in [tap, movePan, pinch, lassoPan] as [UIGestureRecognizer] {
            gesture.delegate = self
            canvas.addGestureRecognizer(gesture)
        }
        canvas.panGestureRecognizer.require(toFail: movePan)
        canvas.panGestureRecognizer.require(toFail: lassoPan)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        if laidOutWidth != bounds.width {
            laidOutWidth = bounds.width
            note.texts.forEach { layoutText($0.id) }
        }
        updateContentSize()
        updateVisibleImages()
    }

    // MARK: - 도구

    func setTool(_ tool: PageTool, color: UIColor) {
        guard tool != currentTool || color != currentColor else { return }
        currentTool = tool
        currentColor = color
        switch tool {
        case .select:
            break
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: color, width: 3)
        case .highlighter:
            canvas.tool = PKInkingTool(.marker, color: .yellow, width: 18)
        case .eraser:
            canvas.tool = PKEraserTool(.vector)
        case .lasso:
            break
        }
        let selecting = tool == .select
        let lassoing = tool == .lasso
        // pencilOnly로 두면 손가락은 그리지 않고 스크롤만 한다.
        canvas.drawingPolicy = selecting || lassoing ? .pencilOnly : .anyInput
        tap.isEnabled = selecting || lassoing
        movePan.isEnabled = selecting
        pinch.isEnabled = selecting
        lassoPan.isEnabled = lassoing
        if !selecting {
            deselect()
        }
        if !lassoing {
            clearLasso()
        }
    }

    func setTemplate(_ template: PaperTemplate) {
        guard note.template != template else { return }
        note.template = template
        applyTemplate()
        commit()
    }

    func setName(_ name: String) {
        guard note.name != name else { return }
        note.name = name
        commit()
    }

    /// 페이지를 A4 비율로 나눠 PDF로 만든다. 글자는 텍스트로, 필기와 사진은 이미지로 들어간다.
    func makePDF() -> Data {
        let line = Self.lineHeight
        let width = max(bounds.width, 100)
        // 줄 중간에서 쪽이 나뉘지 않게 쪽 높이를 줄 간격의 배수로 맞춘다.
        let pageHeight = (width * 297 / 210 / line).rounded(.down) * line
        let bottom = contentBottom()
        let drawing = canvas.drawing
        let imageFolder = NoteStore.imageFolder(for: note.id)

        // 불러온 PDF는 원래 쪽 경계대로, 그 밖의 부분은 A4 비율로 나눈다.
        var pages: [CGRect] = []
        var top: CGFloat = 0
        for pageEnd in note.pageBreaks ?? [] where pageEnd > top {
            pages.append(CGRect(x: 0, y: top, width: width, height: pageEnd - top))
            top = pageEnd
        }
        while pages.isEmpty || bottom > top + 10 {
            pages.append(CGRect(x: 0, y: top, width: width, height: pageHeight))
            top += pageHeight
        }

        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pages[0].size)).pdfData { context in
            for visible in pages {
                context.beginPage(withBounds: CGRect(origin: .zero, size: visible.size), pageInfo: [:])
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: 0, y: -visible.minY)

                if note.template != .blank {
                    UIColor(white: 0.8, alpha: 1).setFill()
                    var y = ((visible.minY + 1) / line).rounded(.up) * line - 1
                    while y < visible.maxY {
                        context.fill(CGRect(x: 0, y: y, width: width, height: 1))
                        y += line
                    }
                    if note.template == .grid {
                        var x = line - 1
                        while x < width {
                            context.fill(CGRect(x: x, y: visible.minY, width: 1, height: visible.height))
                            x += line
                        }
                    }
                }
                for item in note.images {
                    if let view = imageViews[item.id], view.frame.intersects(visible) {
                        UIImage(contentsOfFile: imageFolder.appendingPathComponent(item.fileName).path)?
                            .draw(in: view.frame)
                    }
                }
                for item in note.texts {
                    if let view = textViews[item.id], view.frame.intersects(visible) {
                        view.attributedText.draw(in: view.frame)
                    }
                }
                var ink: UIImage?
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    ink = drawing.image(from: visible, scale: 2)
                }
                ink?.draw(in: visible)

                context.cgContext.restoreGState()
            }
        }
    }

    func undo() { canvas.undoManager?.undo() }
    func redo() { canvas.undoManager?.redo() }

    // MARK: - 글자 입력

    func insertText(_ string: String) {
        if selectedTextView == nil {
            createText(at: CGPoint(x: 16, y: canvas.contentOffset.y + Self.lineHeight))
        }
        guard let textView = selectedTextView else { return }
        textView.typingAttributes = Self.textAttributes
        textView.insertText(string)
        textViewDidChange(textView)
    }

    /// 커서 앞에 있는 글. 선택된 글상자가 없으면 빈 문자열.
    func textBeforeCursor() -> String {
        guard let textView = selectedTextView else { return "" }
        let text = textView.text as NSString
        return text.substring(to: min(textView.selectedRange.location, text.length))
    }

    /// 기존 내용과 겹치지 않게 페이지 맨 아래에 새 글상자로 넣는다.
    func appendBlock(_ string: String) {
        deselect()
        createText(at: CGPoint(x: 16, y: contentBottom() + Self.lineHeight * 1.5))
        insertText(string)
    }

    func backspace() {
        guard let textView = selectedTextView else { return }
        textView.deleteBackward()
        textViewDidChange(textView)
    }

    /// 커서 바로 앞이 `old`일 때만 `new`로 바꾼다.
    func replaceBeforeCursor(_ old: String, with new: String) -> Bool {
        guard let textView = selectedTextView,
              let selection = textView.selectedTextRange, selection.isEmpty,
              let start = textView.position(from: selection.start, offset: -(old as NSString).length),
              let range = textView.textRange(from: start, to: selection.start),
              textView.text(in: range) == old else { return false }
        textView.replace(range, withText: new)
        textViewDidChange(textView)
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let id = textViews.first(where: { $0.value === textView })?.key,
              let index = note.texts.firstIndex(where: { $0.id == id }),
              note.texts[index].text != textView.text else { return }
        note.texts[index].text = textView.text
        layoutText(id)
        commit()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        textView.typingAttributes = Self.textAttributes
    }

    // MARK: - 사진

    func addImage(_ image: UIImage) {
        let maxSide: CGFloat = 1600
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = resized.jpegData(compressionQuality: 0.8) else { return }
        let folder = NoteStore.imageFolder(for: note.id)
        let fileName = UUID().uuidString + ".jpg"
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent(fileName))
        } catch {
            return
        }
        let width = max(60, bounds.width - 40)
        let item = ImageItem(x: 20, y: canvas.contentOffset.y + 20,
                             width: width, height: width * size.height / size.width,
                             fileName: fileName)
        note.images.append(item)
        addImageView(for: item)
        updateVisibleImages()
        select(item.id)
        commit()
    }

    func deleteSelected() {
        if hasLassoSelection {
            lassoItems.forEach(removeItem)
            if !lassoStrokes.isEmpty {
                var strokes = canvas.drawing.strokes
                for index in lassoStrokes.sorted(by: >) where index < strokes.count {
                    strokes.remove(at: index)
                }
                canvas.drawing = PKDrawing(strokes: strokes)
                note.drawing = canvas.drawing.dataRepresentation()
            }
            clearLasso()
            commit()
            return
        }
        guard let id = selectedID else { return }
        removeItem(id)
        selectedID = nil
        handle.isHidden = true
        onSelectionChange?(false)
        commit()
    }

    private func removeItem(_ id: UUID) {
        if let view = textViews.removeValue(forKey: id) {
            view.removeFromSuperview()
            note.texts.removeAll { $0.id == id }
        }
        if let view = imageViews.removeValue(forKey: id) {
            view.removeFromSuperview()
            if let item = note.images.first(where: { $0.id == id }) {
                try? FileManager.default.removeItem(
                    at: NoteStore.imageFolder(for: note.id).appendingPathComponent(item.fileName))
            }
            note.images.removeAll { $0.id == id }
        }
    }

    // MARK: - 필기

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !lassoMoving else { return }
        let data = canvasView.drawing.dataRepresentation()
        guard data != note.drawing else { return }
        note.drawing = data
        commit()
    }

    // MARK: - 선택·이동·크기

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === movePan {
            guard let id = selectedID, let view = itemView(id) else { return false }
            return view.frame.insetBy(dx: -20, dy: -20).contains(gestureRecognizer.location(in: underlay))
        }
        if gestureRecognizer === pinch {
            guard let id = selectedID else { return false }
            return imageViews[id] != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleLasso(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: underlay)
        switch gesture.state {
        case .began:
            if hasLassoSelection, let path = lassoPath, path.bounds.insetBy(dx: -12, dy: -12).contains(point) {
                lassoMoving = true
                lassoMoved = .zero
            } else {
                clearLasso()
                let path = UIBezierPath()
                path.move(to: point)
                lassoPath = path
            }
            lastLassoPoint = point
        case .changed:
            if lassoMoving {
                translateLasso(by: CGPoint(x: point.x - lastLassoPoint.x, y: point.y - lastLassoPoint.y))
            } else {
                lassoPath?.addLine(to: point)
                lassoLayer.path = lassoPath?.cgPath
            }
            lastLassoPoint = point
        case .ended, .cancelled:
            if lassoMoving {
                finishLassoMove()
            } else {
                finishLassoLoop()
            }
        default:
            break
        }
    }

    private func finishLassoLoop() {
        guard let path = lassoPath else { return }
        path.close()
        let loopCenter = CGPoint(x: path.bounds.midX, y: path.bounds.midY)

        // 글상자는 통째로 고른다: 글자 중심이 올가미 안이거나, 올가미가 글상자 안에 그려졌을 때.
        let texts = note.texts.filter { item in
            guard let view = textViews[item.id] else { return false }
            let rect = view.layoutManager.usedRect(for: view.textContainer)
                .offsetBy(dx: view.frame.minX, dy: view.frame.minY)
            return path.contains(CGPoint(x: rect.midX, y: rect.midY)) || rect.contains(loopCenter)
        }
        let images = note.images.filter { item in
            guard item.locked != true, let frame = imageViews[item.id]?.frame else { return false }
            return path.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        lassoItems = texts.map { $0.id } + images.map { $0.id }
        lassoStrokes = canvas.drawing.strokes.enumerated().compactMap { index, stroke in
            var inside = 0
            var total = 0
            for strokePoint in stroke.path {
                total += 1
                if path.contains(strokePoint.location.applying(stroke.transform)) {
                    inside += 1
                }
            }
            return total > 0 && inside * 2 > total ? index : nil
        }

        if hasLassoSelection {
            lassoLayer.path = path.cgPath
            onSelectionChange?(true)
        } else {
            clearLasso()
        }
    }

    private func translateLasso(by delta: CGPoint) {
        for id in lassoItems {
            if let view = itemView(id) {
                view.frame.origin = CGPoint(x: view.frame.minX + delta.x, y: view.frame.minY + delta.y)
            }
        }
        let move = CGAffineTransform(translationX: delta.x, y: delta.y)
        if !lassoStrokes.isEmpty {
            var strokes = canvas.drawing.strokes
            for index in lassoStrokes where index < strokes.count {
                strokes[index].transform = strokes[index].transform.concatenating(move)
            }
            canvas.drawing = PKDrawing(strokes: strokes)
        }
        lassoPath?.apply(move)
        lassoLayer.path = lassoPath?.cgPath
        lassoMoved = CGPoint(x: lassoMoved.x + delta.x, y: lassoMoved.y + delta.y)
    }

    private func finishLassoMove() {
        // 줄노트·모눈에서는 줄 간격 단위로 옮겨서 글자가 줄에서 벗어나지 않게 한다.
        if note.template != .blank {
            let line = Self.lineHeight
            let snapped = (lassoMoved.y / line).rounded() * line
            translateLasso(by: CGPoint(x: 0, y: snapped - lassoMoved.y))
        }
        for id in lassoItems {
            guard let frame = itemView(id)?.frame else { continue }
            if let index = note.texts.firstIndex(where: { $0.id == id }) {
                note.texts[index].x = max(0, frame.minX)
                note.texts[index].y = max(0, frame.minY)
                layoutText(id)
            } else if let index = note.images.firstIndex(where: { $0.id == id }) {
                note.images[index].x = frame.minX
                note.images[index].y = max(0, frame.minY)
            }
        }
        lassoMoving = false
        note.drawing = canvas.drawing.dataRepresentation()
        commit()
    }

    private func clearLasso() {
        let hadSelection = hasLassoSelection
        lassoPath = nil
        lassoLayer.path = nil
        lassoItems = []
        lassoStrokes = []
        lassoMoving = false
        if hadSelection {
            onSelectionChange?(false)
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        if currentTool == .lasso {
            clearLasso()
            return
        }
        let point = gesture.location(in: underlay)
        if let id = hitItem(at: point) {
            select(id)
            if let textView = textViews[id],
               let position = textView.closestPosition(to: underlay.convert(point, to: textView)) {
                textView.selectedTextRange = textView.textRange(from: position, to: position)
            }
        } else if selectedID != nil {
            deselect()
        } else {
            createText(at: point)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let id = selectedID, let view = itemView(id) else { return }
        switch gesture.state {
        case .began:
            dragStart = view.frame
            let point = gesture.location(in: underlay)
            isResizing = imageViews[id] != nil
                && abs(point.x - dragStart.maxX) < 36 && abs(point.y - dragStart.maxY) < 36
        case .changed:
            let move = gesture.translation(in: underlay)
            if isResizing {
                let width = min(max(60, dragStart.width + move.x), bounds.width - dragStart.minX)
                view.frame = CGRect(x: dragStart.minX, y: dragStart.minY,
                                    width: width, height: width * dragStart.height / dragStart.width)
            } else {
                view.frame.origin = CGPoint(x: dragStart.minX + move.x, y: max(0, dragStart.minY + move.y))
            }
            layoutHandle()
        case .ended, .cancelled:
            storeFrame(id, view.frame)
        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let id = selectedID, let view = imageViews[id] else { return }
        switch gesture.state {
        case .began:
            dragStart = view.frame
        case .changed:
            let width = min(max(60, dragStart.width * gesture.scale), bounds.width)
            let height = width * dragStart.height / dragStart.width
            view.frame = CGRect(x: dragStart.midX - width / 2, y: max(0, dragStart.midY - height / 2),
                                width: width, height: height)
            layoutHandle()
        case .ended, .cancelled:
            storeFrame(id, view.frame)
        default:
            break
        }
    }

    private var selectedTextView: UITextView? {
        selectedID.flatMap { textViews[$0] }
    }

    private func itemView(_ id: UUID) -> UIView? {
        textViews[id] ?? imageViews[id]
    }

    private func hitItem(at point: CGPoint) -> UUID? {
        if let text = note.texts.last(where: { textViews[$0.id]?.frame.insetBy(dx: -6, dy: -6).contains(point) == true }) {
            return text.id
        }
        return note.images.last { $0.locked != true && imageViews[$0.id]?.frame.contains(point) == true }?.id
    }

    private func select(_ id: UUID) {
        if selectedID != id {
            deselect()
        }
        selectedID = id
        if let view = itemView(id) {
            view.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
            view.layer.borderWidth = 1
        }
        if let textView = textViews[id] {
            applyInputView()
            textView.becomeFirstResponder()
        }
        layoutHandle()
        onSelectionChange?(true)
    }

    private func deselect() {
        guard let id = selectedID else { return }
        selectedID = nil
        handle.isHidden = true
        if let view = itemView(id) {
            view.layer.borderWidth = 0
        }
        if let textView = textViews[id] {
            textView.resignFirstResponder()
            if textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                textView.removeFromSuperview()
                textViews[id] = nil
                note.texts.removeAll { $0.id == id }
                commit()
            }
        }
        onSelectionChange?(false)
    }

    private func createText(at point: CGPoint) {
        let line = Self.lineHeight
        let x = min(max(12, point.x), max(12, bounds.width - 80))
        let y = note.template == .blank ? max(0, point.y - line / 2) : max(0, (point.y / line).rounded(.down) * line)
        let item = TextItem(x: x, y: y)
        note.texts.append(item)
        addTextView(for: item)
        layoutText(item.id)
        select(item.id)
    }

    private func storeFrame(_ id: UUID, _ frame: CGRect) {
        if let index = note.texts.firstIndex(where: { $0.id == id }) {
            let line = Self.lineHeight
            note.texts[index].x = min(max(8, frame.minX), max(8, bounds.width - 60))
            note.texts[index].y = note.template == .blank ? frame.minY : max(0, (frame.minY / line).rounded() * line)
            layoutText(id)
        } else if let index = note.images.firstIndex(where: { $0.id == id }) {
            note.images[index].x = frame.minX
            note.images[index].y = frame.minY
            note.images[index].width = frame.width
            note.images[index].height = frame.height
        }
        layoutHandle()
        commit()
    }

    // MARK: - 배치

    private func addTextView(for item: TextItem) {
        let textView = UITextView()
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.attributedText = NSAttributedString(string: item.text, attributes: Self.textAttributes)
        textView.typingAttributes = Self.textAttributes
        textView.delegate = self
        underlay.addSubview(textView)
        textViews[item.id] = textView
    }

    private func addImageView(for item: ImageItem) {
        // 이미지 내용은 화면 근처에 올 때 읽는다(updateVisibleImages).
        let imageView = UIImageView()
        imageView.contentMode = .scaleToFill
        imageView.frame = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
        if item.locked == true {
            imageView.layer.borderColor = UIColor(white: 0.8, alpha: 1).cgColor
            imageView.layer.borderWidth = 0.5
        }
        // 사진은 글자 아래에 둔다.
        underlay.insertSubview(imageView, at: imageViews.count)
        imageViews[item.id] = imageView
    }

    /// 쪽수가 많은 PDF에서도 메모리가 넘치지 않게, 화면 근처의 이미지만 올려 둔다.
    private func updateVisibleImages() {
        let near = CGRect(origin: canvas.contentOffset, size: canvas.bounds.size)
            .insetBy(dx: 0, dy: -canvas.bounds.height)
        let folder = NoteStore.imageFolder(for: note.id)
        for item in note.images {
            guard let view = imageViews[item.id] else { continue }
            if view.frame.intersects(near) {
                if view.image == nil {
                    view.image = UIImage(contentsOfFile: folder.appendingPathComponent(item.fileName).path)
                }
            } else if view.image != nil {
                view.image = nil
            }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisibleImages()
    }

    private func layoutText(_ id: UUID) {
        guard bounds.width > 0, let textView = textViews[id],
              let item = note.texts.first(where: { $0.id == id }) else { return }
        let width = max(60, bounds.width - item.x - 12)
        let fitted = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        textView.frame = CGRect(x: item.x, y: item.y, width: width, height: max(Self.lineHeight, fitted.height))
    }

    private func layoutHandle() {
        guard let id = selectedID, let view = imageViews[id] else {
            handle.isHidden = true
            return
        }
        handle.center = CGPoint(x: view.frame.maxX, y: view.frame.maxY)
        handle.isHidden = false
        underlay.bringSubviewToFront(handle)
    }

    private func applyInputView() {
        guard let textView = selectedTextView else { return }
        // 빈 inputView를 주면 커서는 유지되고 시스템 키보드만 숨겨진다.
        textView.inputView = useKeyboard ? nil : UIView()
        textView.reloadInputViews()
    }

    private func applyTemplate() {
        guard note.template != .blank else {
            underlay.backgroundColor = .clear
            return
        }
        let line = Self.lineHeight
        let grid = note.template == .grid
        let tile = UIGraphicsImageRenderer(size: CGSize(width: line, height: line)).image { context in
            UIColor(white: 0.8, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: line - 1, width: line, height: 1))
            if grid {
                context.fill(CGRect(x: line - 1, y: 0, width: 1, height: line))
            }
        }
        underlay.backgroundColor = UIColor(patternImage: tile)
    }

    private func updateContentSize() {
        guard bounds.width > 0 else { return }
        // 속지 줄이 끊기지 않게 줄 간격의 배수로 맞춘다.
        let line = Self.lineHeight
        let height = (max(bounds.height, contentBottom() + 1200) / line).rounded(.up) * line
        let size = CGSize(width: bounds.width, height: height)
        if canvas.contentSize != size {
            canvas.contentSize = size
        }
        underlay.frame = CGRect(origin: .zero, size: size)
        overlay.frame = underlay.frame
    }

    private func contentBottom() -> CGFloat {
        var bottom: CGFloat = 0
        let inkBounds = canvas.drawing.bounds
        if !inkBounds.isNull, !inkBounds.isInfinite {
            bottom = inkBounds.maxY
        }
        for view in textViews.values {
            bottom = max(bottom, view.frame.maxY)
        }
        for view in imageViews.values {
            bottom = max(bottom, view.frame.maxY)
        }
        return bottom
    }

    private func commit() {
        note.modified = Date()
        updateContentSize()
        let snapshot = note
        DispatchQueue.main.async { [weak self] in
            self?.onChange?(snapshot)
        }
    }
}
