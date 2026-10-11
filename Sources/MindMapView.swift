import SwiftUI

/// 마인드맵 화면.
/// 칸을 누르면 그 칸에 글을 쓰고, [하위]·[옆]으로 가지를 계속 늘린다. 배치는 앱이 알아서 가지런히 한다.
struct MindMapEditorView: View {
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss

    @State private var note: Note
    @State private var titleText: String
    @State private var selected: UUID?
    @State private var scale: CGFloat = 1
    @State private var pinchStart: CGFloat?
    @State private var confirmDelete = false
    @State private var sharedItem: SharedItem?
    /// 새로 만든 가지가 화면에 보이도록 그쪽으로 넘길 때 쓴다.
    @State private var reveal: UUID?
    @FocusState private var titleFocused: Bool

    init(note: Note) {
        _note = State(initialValue: note)
        _titleText = State(initialValue: note.name ?? "")
        _selected = State(initialValue: note.mindMap?.id)
    }

    private var root: MindNode { note.mindMap ?? MindNode() }

    var body: some View {
        let root = self.root
        let layout = MindLayout(root: root, scale: scale)
        VStack(spacing: 0) {
            TextField("제목", text: $titleText)
                .font(.title3.weight(.semibold))
                .submitLabel(.done)
                .focused($titleFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            Divider()
            controlRow(root)
            Divider()
            ScrollViewReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    map(root, layout)
                }
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let start = pinchStart ?? scale
                            pinchStart = start
                            scale = min(2.5, max(0.4, start * value))
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .onChange(of: reveal) { id in
                    guard let id else { return }
                    // 배치가 끝난 다음에 넘겨야 새 가지의 자리를 찾는다.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .bottomTrailing)
                        }
                        reveal = nil
                    }
                }
            }
            .background(Color(.secondarySystemBackground))

            if let selected, !titleFocused, root.find(selected) != nil {
                CellInputPanel(text: nodeText(selected),
                               placeholder: selected == root.id ? "중심 주제" : "생각나는 것",
                               target: selected.uuidString)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // 지도를 옆으로 넘기거나 글씨를 쓸 때 '밀어서 뒤로 가기'에 걸리지 않게, 뒤로 가기는 버튼으로만 한다.
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
                        share(BoardExport.mindMapPDF(root), "pdf")
                    } label: {
                        Label("PDF 내보내기", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        share(BoardExport.textData(BoardExport.mindMapText(root)), "txt")
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
        .confirmationDialog("이 가지와 아래 가지를 모두 지울까요?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("지우기", role: .destructive) {
                deleteSelected()
            }
            Button("취소", role: .cancel) {}
        }
        .onChange(of: titleText) { name in
            note.name = name
            save()
        }
    }

    // MARK: - 화면 조각

    private func controlRow(_ root: MindNode) -> some View {
        let node = selected.flatMap { root.find($0) }
        return HStack(spacing: 6) {
            Button {
                addChild()
            } label: {
                Label("하위", systemImage: "plus").font(.footnote)
            }
            .buttonStyle(.borderedProminent)
            .disabled(node == nil)
            Button {
                addSibling()
            } label: {
                Label("옆", systemImage: "plus").font(.footnote)
            }
            .buttonStyle(.bordered)
            .disabled(node == nil)
            if let node, !node.children.isEmpty {
                Button {
                    toggleCollapsed(node.id)
                } label: {
                    Text(node.collapsed == true ? "펼치기" : "접기").font(.footnote)
                }
                .buttonStyle(.bordered)
            }
            if let node, node.id != root.id {
                Button(role: .destructive) {
                    if node.children.isEmpty {
                        deleteSelected()
                    } else {
                        confirmDelete = true
                    }
                } label: {
                    Image(systemName: "trash").font(.footnote)
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 4)
            Button {
                scale = max(0.4, scale - 0.15)
            } label: {
                Image(systemName: "minus.magnifyingglass").frame(width: 32, height: 32)
            }
            Button {
                scale = min(2.5, scale + 0.15)
            } label: {
                Image(systemName: "plus.magnifyingglass").frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }

    private func map(_ root: MindNode, _ layout: MindLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                for link in layout.links {
                    let bend = (link.to.x - link.from.x) / 2
                    path.move(to: link.from)
                    path.addCurve(to: link.to,
                                  control1: CGPoint(x: link.from.x + bend, y: link.from.y),
                                  control2: CGPoint(x: link.to.x - bend, y: link.to.y))
                }
            }
            .stroke(Color.secondary, lineWidth: 1.2)

            ForEach(root.visible()) { item in
                if let frame = layout.frames[item.node.id] {
                    box(item.node, depth: item.depth, isRoot: item.node.id == root.id, size: frame.size)
                        // 왼쪽 위에서부터의 여백으로 자리를 잡는다. 이렇게 해야 '그 가지로 넘기기'가 자리를 안다.
                        .padding(.leading, frame.minX)
                        .padding(.top, frame.minY)
                        .id(item.node.id)
                }
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func box(_ node: MindNode, depth: Int, isRoot: Bool, size: CGSize) -> some View {
        let isSelected = selected == node.id
        let hidden = node.collapsed == true ? node.children.count : 0
        return Text(node.text.isEmpty ? (isRoot ? "중심 주제" : "…") : node.text)
            .font(.system(size: MindLayout.fontSize(depth: depth, scale: scale), weight: depth < 2 ? .semibold : .regular))
            .foregroundColor(node.text.isEmpty ? .secondary : .primary)
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(depth == 0 ? Color.accentColor.opacity(0.35)
                          : (depth == 1 ? Color.accentColor.opacity(0.14) : Color(.systemBackground)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? Color.accentColor : Color(.separator), lineWidth: isSelected ? 2.5 : 0.8)
            )
            .overlay(alignment: .topTrailing) {
                if hidden > 0 {
                    Text("+\(hidden)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 8, y: -8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                titleFocused = false
                selected = node.id
            }
    }

    // MARK: - 바꾸기

    private func nodeText(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.root.find(id)?.text ?? "" },
            set: { text in
                change { $0.update(id) { $0.text = text } }
            }
        )
    }

    private func change(_ edit: (inout MindNode) -> Void) {
        var root = self.root
        edit(&root)
        guard root != note.mindMap else { return }
        note.mindMap = root
        save()
    }

    private func addChild() {
        guard let selected else { return }
        let new = MindNode()
        change {
            $0.update(selected) { node in
                node.children.append(new)
                node.collapsed = nil
            }
        }
        select(new.id)
    }

    /// 고른 가지와 같은 줄, 바로 아래에 새 가지를 만든다. 중심 주제에서는 하위 가지를 만든다.
    private func addSibling() {
        guard let selected else { return }
        guard let parent = root.parent(of: selected) else {
            addChild()
            return
        }
        let new = MindNode()
        change {
            $0.update(parent.id) { node in
                let index = node.children.firstIndex { $0.id == selected } ?? node.children.count - 1
                node.children.insert(new, at: index + 1)
            }
        }
        select(new.id)
    }

    private func toggleCollapsed(_ id: UUID) {
        change {
            $0.update(id) { node in
                node.collapsed = node.collapsed == true ? nil : true
            }
        }
    }

    private func deleteSelected() {
        guard let selected, selected != root.id else { return }
        let parent = root.parent(of: selected)
        change { $0.remove(selected) }
        self.selected = parent?.id ?? root.id
    }

    private func select(_ id: UUID) {
        selected = id
        reveal = id
    }

    private func save() {
        note.modified = Date()
        store.update(note)
    }

    private func share(_ data: Data, _ fileExtension: String) {
        sharedItem = BoardExport.file(data, name: note.title, fileExtension: fileExtension)
    }
}
