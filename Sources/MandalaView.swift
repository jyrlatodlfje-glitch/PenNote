import SwiftUI

/// 만다라트 표 화면.
/// 칸을 누르면 그 칸에 글을 쓰고, 칸을 길게 누르면(또는 [펼치기]) 그 칸을 핵심 목표로 하는 새 표로 들어간다.
struct MandalaEditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    @State private var note: Note
    @State private var titleText: String
    /// 펼쳐 들어간 칸 번호들. 비어 있으면 맨 처음 표.
    @State private var path: [Int] = []
    @State private var selected: Int? = MandalaBoard.center
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var sharedItem: SharedItem?
    @FocusState private var titleFocused: Bool

    init(note: Note) {
        _note = State(initialValue: note)
        _titleText = State(initialValue: note.name ?? "")
    }

    private var root: MandalaBoard { note.mandala ?? MandalaBoard() }

    private var board: MandalaBoard {
        var board = root[path: path[...]]
        if board.cells.count != 81 {
            board.cells = Array((board.cells + Array(repeating: "", count: 81)).prefix(81))
        }
        return board
    }

    var body: some View {
        let board = self.board
        let layout = MandalaLayout(cells: board.cells, scale: scale)
        VStack(spacing: 0) {
            TextField("제목", text: $titleText)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
                .focused($titleFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            controlRow(board)
            Divider()
            GeometryReader { area in
                ScrollView([.horizontal, .vertical]) {
                    grid(board, layout)
                        .padding(12)
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let start = pinchStart ?? scale
                            pinchStart = start
                            scale = min(2.5, max(0.35, start * value))
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .onChange(of: fitRequest) { _ in
                    let natural = MandalaLayout(cells: board.cells, scale: 1).size.width + 24
                    scale = min(2.5, max(0.35, area.size.width / natural))
                }
            }
            .background(Color(.secondarySystemBackground))

            if let selected, !titleFocused {
                CellInputPanel(text: cellText(selected), placeholder: placeholder(selected),
                               target: "\(path)-\(selected)")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // 표를 옆으로 넘기거나 글씨를 쓸 때 '밀어서 뒤로 가기'에 걸리지 않게, 뒤로 가기는 버튼으로만 한다.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        share(BoardExport.mandalaPDF(root, title: note.title), "pdf")
                    } label: {
                        Label("PDF 내보내기", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        share(BoardExport.textData(BoardExport.mandalaText(root, title: note.title)), "txt")
                    } label: {
                        Label("텍스트 내보내기", systemImage: "text.alignleft")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .background(ContentSwipeBackDisabler())
        .sheet(item: $sharedItem) { shared in
            ActivityView(item: shared.item)
        }
        .onChange(of: titleText) { name in
            note.name = name
            save()
        }
    }

    @State private var fitRequest = 0

    // MARK: - 화면 조각

    private func controlRow(_ board: MandalaBoard) -> some View {
        HStack(spacing: 4) {
            if path.isEmpty {
                Text("칸을 길게 누르면 그 칸으로 새 표를 펼칩니다")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Button {
                    let from = path.removeLast()
                    selected = from
                } label: {
                    Label("상위 표", systemImage: "arrow.up.left")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                Text("\(path.count + 1)단계")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if let selected, selected != MandalaBoard.center {
                Button {
                    open(selected)
                } label: {
                    Label(board.child(at: selected) == nil ? "펼치기" : "들어가기", systemImage: "square.grid.3x3")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
            }
            Button {
                scale = max(0.35, scale - 0.15)
            } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 32, height: 32)
            }
            Button {
                scale = min(2.5, scale + 0.15)
            } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 32, height: 32)
            }
            Button {
                fitRequest += 1
            } label: {
                Image(systemName: "arrow.left.and.right.square").frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private func grid(_ board: MandalaBoard, _ layout: MandalaLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<9, id: \.self) { row in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<9, id: \.self) { column in
                        cell(row * 9 + column, board, layout)
                            .padding(.trailing, column % 3 == 2 && column < 8 ? MandalaLayout.blockGap : 0)
                    }
                }
                .padding(.bottom, row % 3 == 2 && row < 8 ? MandalaLayout.blockGap : 0)
            }
        }
    }

    private func cell(_ index: Int, _ board: MandalaBoard, _ layout: MandalaLayout) -> some View {
        let isSelected = selected == index
        return Text(board.cells[index])
            .font(.system(size: layout.fontSize, weight: MandalaBoard.isGoal(index) ? .semibold : .regular))
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .padding(MandalaLayout.pad)
            .frame(width: layout.widths[index % 9], height: layout.heights[index / 9])
            .background(fill(index))
            .overlay(
                Rectangle().stroke(isSelected ? Color.accentColor : Color(.separator),
                                   lineWidth: isSelected ? 2.5 : 0.5)
            )
            .overlay(alignment: .topTrailing) {
                if board.child(at: index) != nil {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: max(7, 9 * scale)))
                        .foregroundColor(.accentColor)
                        .padding(3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                titleFocused = false
                selected = index
            }
            .onLongPressGesture {
                open(index)
            }
    }

    private func fill(_ index: Int) -> Color {
        if index == MandalaBoard.center {
            return Color.accentColor.opacity(0.35)
        }
        if MandalaBoard.isGoal(index) {
            return Color.accentColor.opacity(0.13)
        }
        return Color(.systemBackground)
    }

    private func placeholder(_ index: Int) -> String {
        if index == MandalaBoard.center {
            return "핵심 목표"
        }
        return MandalaBoard.isGoal(index) ? "세부 목표" : "실천할 일"
    }

    // MARK: - 바꾸기

    private func cellText(_ index: Int) -> Binding<String> {
        let path = self.path
        return Binding(
            get: { self.root[path: path[...]].cells.indices.contains(index) ? self.root[path: path[...]].cells[index] : "" },
            set: { setText($0, index, at: path) }
        )
    }

    private func setText(_ text: String, _ index: Int, at path: [Int]) {
        var root = self.root
        var current = root[path: path[...]]
        guard current.cells.indices.contains(index), current.cells[index] != text else { return }
        current.setCell(index, text)
        root[path: path[...]] = current
        // 표의 한가운데는 상위 표에서 펼친 그 칸과 같은 글이다.
        if index == MandalaBoard.center, let from = path.last {
            var parent = root[path: path.dropLast()]
            parent.setCell(from, text)
            root[path: path.dropLast()] = parent
        }
        note.mandala = root
        save()
    }

    /// 칸을 핵심 목표로 하는 표로 들어간다. 아직 없으면 새로 만든다.
    private func open(_ index: Int) {
        guard index != MandalaBoard.center else { return }
        let key = MandalaBoard.key(index)
        var root = self.root
        var current = root[path: path[...]]
        if current.children[String(key)] == nil {
            var child = MandalaBoard()
            child.cells[MandalaBoard.center] = current.cells[index]
            current.children[String(key)] = child
            root[path: path[...]] = current
            note.mandala = root
            save()
        }
        path.append(key)
        selected = MandalaBoard.center
    }

    private func save() {
        note.modified = Date()
        store.update(note)
    }

    private func share(_ data: Data, _ fileExtension: String) {
        sharedItem = BoardExport.file(data, name: note.title, fileExtension: fileExtension)
    }
}
