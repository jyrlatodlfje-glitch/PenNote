import SwiftUI
import UIKit

// MARK: - 만다라트

/// 만다라트 표 한 장 (9×9 = 81칸).
/// 가운데 3×3의 한가운데가 핵심 목표, 그 둘레 8칸이 세부 목표다.
/// 세부 목표 8개는 바깥 3×3 여덟 개의 한가운데에도 똑같이 적힌다 (두 칸은 항상 같은 글).
/// 어느 칸이든 그 칸을 핵심 목표로 하는 새 표를 펼칠 수 있어서, 끝없이 이어 갈 수 있다.
struct MandalaBoard: Codable, Equatable {
    /// 왼쪽 위부터 가로로 81칸
    var cells: [String] = Array(repeating: "", count: 81)
    /// 칸 번호 → 그 칸에서 펼친 표
    var children: [String: MandalaBoard] = [:]

    static let center = 40

    /// 가운데 3×3의 세부 목표 칸과 바깥 3×3의 한가운데 칸은 짝이다. 짝이 있으면 그 칸 번호.
    static func link(_ index: Int) -> Int? {
        let row = index / 9, column = index % 9
        guard index != center else { return nil }
        if (3...5).contains(row) && (3...5).contains(column) {
            return ((row - 3) * 3 + 1) * 9 + (column - 3) * 3 + 1
        }
        if row % 3 == 1 && column % 3 == 1 {
            return (3 + row / 3) * 9 + 3 + column / 3
        }
        return nil
    }

    /// 핵심 목표나 세부 목표가 적히는 칸인지
    static func isGoal(_ index: Int) -> Bool {
        index == center || link(index) != nil
    }

    /// 펼친 표를 찾을 때 쓰는 칸 번호. 짝인 두 칸은 같은 표를 가리키도록 바깥쪽 칸으로 통일한다.
    static func key(_ index: Int) -> Int {
        let row = index / 9, column = index % 9
        if index != center, (3...5).contains(row), (3...5).contains(column), let outer = link(index) {
            return outer
        }
        return index
    }

    func child(at index: Int) -> MandalaBoard? {
        children[String(Self.key(index))]
    }

    /// 칸에 글을 쓴다. 짝인 칸과, 그 칸에서 펼친 표의 한가운데도 같은 글로 맞춘다.
    mutating func setCell(_ index: Int, _ text: String) {
        for target in [index, Self.link(index)].compactMap({ $0 }) {
            cells[target] = text
            children[String(target)]?.cells[Self.center] = text
        }
    }

    /// 펼쳐 들어간 경로(칸 번호들)를 따라가서 그 표를 읽거나 바꾼다.
    subscript(path path: ArraySlice<Int>) -> MandalaBoard {
        get {
            guard let first = path.first else { return self }
            return (children[String(first)] ?? MandalaBoard())[path: path.dropFirst()]
        }
        set {
            guard let first = path.first else {
                self = newValue
                return
            }
            var child = children[String(first)] ?? MandalaBoard()
            child[path: path.dropFirst()] = newValue
            children[String(first)] = child
        }
    }
}

/// 글자에 맞춰 정한 칸 크기. 엑셀처럼 같은 열은 폭이, 같은 행은 높이가 함께 커진다.
struct MandalaLayout {
    static let pad: CGFloat = 6
    static let blockGap: CGFloat = 5

    let widths: [CGFloat]
    let heights: [CGFloat]
    let fontSize: CGFloat

    init(cells: [String], scale: CGFloat) {
        let pointSize = 14 * scale
        fontSize = pointSize
        let font = UIFont.systemFont(ofSize: pointSize, weight: .semibold)
        let minSide = 62 * scale
        let maxWidth = 150 * scale
        let inset = Self.pad * 2 + 2

        var widths = Array(repeating: minSide, count: 9)
        for index in 0..<min(cells.count, 81) {
            let width = BoardText.size(cells[index], font: font, maxWidth: maxWidth - inset).width + inset
            widths[index % 9] = max(widths[index % 9], min(width, maxWidth))
        }
        var heights = Array(repeating: minSide, count: 9)
        for index in 0..<min(cells.count, 81) {
            let height = BoardText.size(cells[index], font: font, maxWidth: widths[index % 9] - inset).height + inset
            heights[index / 9] = max(heights[index / 9], height)
        }
        self.widths = widths
        self.heights = heights
    }

    var size: CGSize {
        CGSize(width: widths.reduce(0, +) + Self.blockGap * 2, height: heights.reduce(0, +) + Self.blockGap * 2)
    }

    func frame(of index: Int) -> CGRect {
        let row = index / 9, column = index % 9
        let x = widths[..<column].reduce(0, +) + CGFloat(column / 3) * Self.blockGap
        let y = heights[..<row].reduce(0, +) + CGFloat(row / 3) * Self.blockGap
        return CGRect(x: x, y: y, width: widths[column], height: heights[row])
    }
}

// MARK: - 마인드맵

/// 마인드맵의 가지 하나. 아래로 가지를 끝없이 달 수 있다.
struct MindNode: Codable, Equatable, Identifiable {
    var id = UUID()
    var text = ""
    var children: [MindNode] = []
    /// 아래 가지를 접어 두었는지
    var collapsed: Bool?

    func find(_ id: UUID) -> MindNode? {
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id) { return found }
        }
        return nil
    }

    func parent(of id: UUID) -> MindNode? {
        if children.contains(where: { $0.id == id }) { return self }
        for child in children {
            if let found = child.parent(of: id) { return found }
        }
        return nil
    }

    @discardableResult
    mutating func update(_ id: UUID, _ change: (inout MindNode) -> Void) -> Bool {
        if self.id == id {
            change(&self)
            return true
        }
        for index in children.indices {
            if children[index].update(id, change) {
                return true
            }
        }
        return false
    }

    @discardableResult
    mutating func remove(_ id: UUID) -> Bool {
        if let index = children.firstIndex(where: { $0.id == id }) {
            children.remove(at: index)
            return true
        }
        for index in children.indices {
            if children[index].remove(id) {
                return true
            }
        }
        return false
    }

    /// 보이는 가지들을 위에서부터 차례로 (접힌 가지의 아래는 뺀다)
    func visible(depth: Int = 0) -> [MindItem] {
        var result = [MindItem(node: self, depth: depth)]
        if collapsed != true {
            for child in children {
                result += child.visible(depth: depth + 1)
            }
        }
        return result
    }
}

/// 화면에 그릴 가지 하나와 그 깊이 (중심 주제가 0)
struct MindItem: Identifiable {
    let node: MindNode
    let depth: Int
    var id: UUID { node.id }
}

/// 마인드맵의 자동 배치. 가운데 주제가 왼쪽에 있고 가지가 오른쪽으로 뻗는다.
/// 칸의 크기는 글자에 맞춰 정하고, 가지가 늘면 전체가 알아서 다시 놓인다.
struct MindLayout {
    static let margin: CGFloat = 24

    private(set) var frames: [UUID: CGRect] = [:]
    private(set) var links: [(from: CGPoint, to: CGPoint)] = []
    private(set) var size = CGSize.zero
    let scale: CGFloat

    private var boxes: [UUID: CGSize] = [:]
    private var heights: [UUID: CGFloat] = [:]

    init(root: MindNode, scale: CGFloat) {
        self.scale = scale
        measure(root, depth: 0)
        place(root, x: Self.margin, top: Self.margin)
        let right = frames.values.map(\.maxX).max() ?? 0
        let bottom = frames.values.map(\.maxY).max() ?? 0
        size = CGSize(width: right + Self.margin, height: bottom + Self.margin)
    }

    static func fontSize(depth: Int, scale: CGFloat) -> CGFloat {
        (depth == 0 ? 17 : 15) * scale
    }

    private var horizontalGap: CGFloat { 36 * scale }
    private var verticalGap: CGFloat { 10 * scale }

    private mutating func measure(_ node: MindNode, depth: Int) {
        let font = UIFont.systemFont(ofSize: Self.fontSize(depth: depth, scale: scale), weight: .semibold)
        let text = BoardText.size(node.text, font: font, maxWidth: 190 * scale)
        let box = CGSize(width: max(72 * scale, text.width + 26), height: max(38 * scale, text.height + 18))
        boxes[node.id] = box

        let children = node.collapsed == true ? [] : node.children
        var total: CGFloat = 0
        for child in children {
            measure(child, depth: depth + 1)
            total += heights[child.id] ?? 0
        }
        total += verticalGap * CGFloat(max(0, children.count - 1))
        heights[node.id] = max(box.height, total)
    }

    private mutating func place(_ node: MindNode, x: CGFloat, top: CGFloat) {
        let box = boxes[node.id] ?? .zero
        let height = heights[node.id] ?? box.height
        let frame = CGRect(x: x, y: top + (height - box.height) / 2, width: box.width, height: box.height)
        frames[node.id] = frame

        let children = node.collapsed == true ? [] : node.children
        guard !children.isEmpty else { return }
        let total = children.reduce(0) { $0 + (heights[$1.id] ?? 0) } + verticalGap * CGFloat(children.count - 1)
        var y = top + (height - total) / 2
        for child in children {
            place(child, x: frame.maxX + horizontalGap, top: y)
            if let childFrame = frames[child.id] {
                links.append((from: CGPoint(x: frame.maxX, y: frame.midY),
                              to: CGPoint(x: childFrame.minX, y: childFrame.midY)))
            }
            y += (heights[child.id] ?? 0) + verticalGap
        }
    }
}

// MARK: - 공통

enum BoardText {
    /// 글을 `maxWidth` 안에서 줄바꿈했을 때 차지하는 크기
    static func size(_ text: String, font: UIFont, maxWidth: CGFloat) -> CGSize {
        guard !text.isEmpty else { return .zero }
        let box = (text as NSString).boundingRect(
            with: CGSize(width: max(maxWidth, 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return CGSize(width: ceil(box.width), height: ceil(box.height))
    }

    static func draw(_ text: String, in rect: CGRect, font: UIFont) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: UIColor.black, .paragraphStyle: style,
        ]
        let needed = size(text, font: font, maxWidth: rect.width)
        let box = CGRect(x: rect.minX, y: rect.midY - needed.height / 2, width: rect.width, height: needed.height)
        (text as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes, context: nil)
    }
}

enum BoardExport {
    private static let tint = UIColor(red: 0.16, green: 0.45, blue: 0.9, alpha: 1)

    /// 제목을 파일 이름으로 한 임시 파일을 만들어 공유 화면에 넘길 것을 돌려준다.
    static func file(_ data: Data, name: String, fileExtension: String) -> SharedItem? {
        let safe = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(safe.isEmpty ? "PenNote" : safe)
            .appendingPathExtension(fileExtension)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return SharedItem(item: url)
    }

    /// PC의 메모장에서 한글이 깨지지 않도록 UTF-8 표식(BOM)을 붙이고 줄바꿈도 Windows 방식으로 쓴다.
    static func textData(_ text: String) -> Data {
        Data([0xEF, 0xBB, 0xBF]) + Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    // MARK: 만다라트

    /// 표마다 한 쪽씩. 펼친 표가 있으면 뒤쪽에 이어서 넣는다.
    static func mandalaPDF(_ root: MandalaBoard, title: String) -> Data {
        var pages: [(heading: String, board: MandalaBoard)] = []
        func collect(_ board: MandalaBoard, heading: String) {
            pages.append((heading, board))
            for key in board.children.keys.compactMap({ Int($0) }).sorted() {
                guard let child = board.children[String(key)] else { continue }
                let name = board.cells[key].isEmpty ? "(빈 칸)" : board.cells[key]
                collect(child, heading: heading + " › " + name)
            }
        }
        collect(root, heading: title)

        let margin: CGFloat = 28
        let headingFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        return UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 600, height: 800)).pdfData { context in
            for page in pages {
                let layout = MandalaLayout(cells: page.board.cells, scale: 1)
                let font = UIFont.systemFont(ofSize: layout.fontSize, weight: .semibold)
                let bounds = CGRect(x: 0, y: 0, width: layout.size.width + margin * 2,
                                    height: layout.size.height + margin * 2 + 24)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                (page.heading as NSString).draw(at: CGPoint(x: margin, y: margin - 8),
                                                 withAttributes: [.font: headingFont, .foregroundColor: UIColor.darkGray])
                for index in 0..<81 {
                    let frame = layout.frame(of: index).offsetBy(dx: margin, dy: margin + 24)
                    if index == MandalaBoard.center {
                        tint.withAlphaComponent(0.35).setFill()
                    } else if MandalaBoard.isGoal(index) {
                        tint.withAlphaComponent(0.13).setFill()
                    } else {
                        UIColor.white.setFill()
                    }
                    context.fill(frame)
                    UIColor.gray.setStroke()
                    let border = UIBezierPath(rect: frame)
                    border.lineWidth = 0.5
                    border.stroke()
                    BoardText.draw(page.board.cells[index],
                                   in: frame.insetBy(dx: MandalaLayout.pad, dy: MandalaLayout.pad), font: font)
                }
            }
        }
    }

    /// 핵심 목표 → 세부 목표 8개 → 각각의 실천 항목 순서로 적는다.
    static func mandalaText(_ root: MandalaBoard, title: String) -> String {
        var lines: [String] = []
        func write(_ board: MandalaBoard, heading: String) {
            lines.append("■ " + heading)
            lines.append("핵심: " + board.cells[MandalaBoard.center])
            var number = 0
            for block in 0..<9 where block != 4 {
                let centerIndex = ((block / 3) * 3 + 1) * 9 + (block % 3) * 3 + 1
                let around = (0..<9).filter { $0 != 4 }.map { offset in
                    ((block / 3) * 3 + offset / 3) * 9 + (block % 3) * 3 + offset % 3
                }
                let items = around.map { board.cells[$0] }.filter { !$0.isEmpty }
                guard !board.cells[centerIndex].isEmpty || !items.isEmpty else { continue }
                number += 1
                lines.append("\(number). " + board.cells[centerIndex])
                lines += items.map { "   - " + $0.replacingOccurrences(of: "\n", with: " ") }
            }
            lines.append("")
            for key in board.children.keys.compactMap({ Int($0) }).sorted() {
                guard let child = board.children[String(key)] else { continue }
                let name = board.cells[key].isEmpty ? "(빈 칸)" : board.cells[key]
                write(child, heading: heading + " › " + name)
            }
        }
        write(root, heading: title)
        return lines.joined(separator: "\n")
    }

    // MARK: 마인드맵

    static func mindMapPDF(_ root: MindNode) -> Data {
        var open = root
        expandAll(&open)
        let layout = MindLayout(root: open, scale: 1)
        let bounds = CGRect(origin: .zero, size: layout.size)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.gray.setStroke()
            for link in layout.links {
                let path = UIBezierPath()
                let bend = (link.to.x - link.from.x) / 2
                path.move(to: link.from)
                path.addCurve(to: link.to,
                              controlPoint1: CGPoint(x: link.from.x + bend, y: link.from.y),
                              controlPoint2: CGPoint(x: link.to.x - bend, y: link.to.y))
                path.lineWidth = 1.2
                path.stroke()
            }
            for item in open.visible() {
                guard let frame = layout.frames[item.node.id] else { continue }
                let box = UIBezierPath(roundedRect: frame, cornerRadius: 9)
                tint.withAlphaComponent(item.depth == 0 ? 0.35 : (item.depth == 1 ? 0.14 : 0.04)).setFill()
                box.fill()
                tint.withAlphaComponent(0.6).setStroke()
                box.lineWidth = 0.8
                box.stroke()
                let font = UIFont.systemFont(ofSize: MindLayout.fontSize(depth: item.depth, scale: 1), weight: .semibold)
                BoardText.draw(item.node.text, in: frame.insetBy(dx: 10, dy: 6), font: font)
            }
        }
    }

    /// 들여쓰기한 목록으로 적는다.
    static func mindMapText(_ root: MindNode) -> String {
        var open = root
        expandAll(&open)
        return open.visible()
            .map { String(repeating: "  ", count: $0.depth) + "- " + $0.node.text.replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\n")
    }

    private static func expandAll(_ node: inout MindNode) {
        node.collapsed = nil
        for index in node.children.indices {
            expandAll(&node.children[index])
        }
    }
}
