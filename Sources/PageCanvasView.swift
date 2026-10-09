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

        for gesture in [tap, movePan, pinch] as [UIGestureRecognizer] {
            gesture.delegate = self
            canvas.addGestureRecognizer(gesture)
        }
        canvas.panGestureRecognizer.require(toFail: movePan)
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
            canvas.tool = PKLassoTool()
        }
        let selecting = tool == .select
        // pencilOnly로 두면 손가락은 그리지 않고 스크롤만 한다.
        canvas.drawingPolicy = selecting ? .pencilOnly : .anyInput
        tap.isEnabled = selecting
        movePan.isEnabled = selecting
        pinch.isEnabled = selecting
        if !selecting {
            deselect()
        }
    }

    func setTemplate(_ template: PaperTemplate) {
        guard note.template != template else { return }
        note.template = template
        applyTemplate()
        commit()
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
        select(item.id)
        commit()
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
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
        selectedID = nil
        handle.isHidden = true
        onSelectionChange?(false)
        commit()
    }

    // MARK: - 필기

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
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

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
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
        return note.images.last { imageViews[$0.id]?.frame.contains(point) == true }?.id
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
        let url = NoteStore.imageFolder(for: note.id).appendingPathComponent(item.fileName)
        let imageView = UIImageView(image: UIImage(contentsOfFile: url.path))
        imageView.contentMode = .scaleToFill
        imageView.frame = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
        // 사진은 글자 아래에 둔다.
        underlay.insertSubview(imageView, at: imageViews.count)
        imageViews[item.id] = imageView
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
        // 속지 줄이 끊기지 않게 줄 간격의 배수로 맞춘다.
        let line = Self.lineHeight
        let height = (max(bounds.height, bottom + 1200) / line).rounded(.up) * line
        let size = CGSize(width: bounds.width, height: height)
        if canvas.contentSize != size {
            canvas.contentSize = size
        }
        underlay.frame = CGRect(origin: .zero, size: size)
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
