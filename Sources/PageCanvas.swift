import SwiftUI
import UIKit

final class PageController: ObservableObject {
    @Published fileprivate(set) var hasSelection = false
    fileprivate weak var view: PageCanvasView?

    func insert(_ string: String) { view?.insertText(string) }
    func appendBlock(_ string: String) { view?.appendBlock(string) }
    func textBeforeCursor() -> String { view?.textBeforeCursor() ?? "" }
    func backspace() { view?.backspace() }
    func replaceBeforeCursor(_ old: String, with new: String) -> Bool {
        view?.replaceBeforeCursor(old, with: new) ?? false
    }
    func addImage(_ image: UIImage) { view?.addImage(image) }
    func addImages(_ images: [UIImage]) { view?.addImages(images) }
    func deleteSelected() { view?.deleteSelected() }
    func setTemplate(_ template: PaperTemplate) { view?.setTemplate(template) }
    func setName(_ name: String) { view?.setName(name) }
    func makePDF() -> Data? { view?.makePDF() }
    func plainText() -> String { view?.plainText() ?? "" }
    func undo() { view?.undo() }
    func redo() { view?.redo() }
}

struct PageCanvas: UIViewRepresentable {
    let initialNote: Note
    let controller: PageController
    let tool: PageTool
    let color: UIColor
    let useKeyboard: Bool
    let straightenLines: Bool
    let onTap: () -> Void
    let onChange: (Note) -> Void

    func makeUIView(context: Context) -> PageCanvasView {
        let view = PageCanvasView(note: initialNote)
        controller.view = view
        view.onSelectionChange = { [weak controller] hasSelection in
            DispatchQueue.main.async { controller?.hasSelection = hasSelection }
        }
        return view
    }

    func updateUIView(_ view: PageCanvasView, context: Context) {
        view.onChange = onChange
        view.onTap = onTap
        view.straightenLines = straightenLines
        view.setTool(tool, color: color)
        view.useKeyboard = useKeyboard
    }
}

/// 노트 화면에 있는 동안 '밀어서 뒤로 가기'를 모두 끈다. 뒤로 가기는 왼쪽 위의 버튼으로만 한다.
/// 글씨의 가로획, 펜으로 긋는 선, 글자 옮기기가 그 동작에 먹혀 목록 화면으로 넘어가지 않게 하기 위해서다.
struct ContentSwipeBackDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        Controller()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Controller: UIViewController {
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            setSwipeBack(enabled: false)
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            // 화면이 다시 그려질 때 시스템이 제스처를 되살리는 경우에 대비해 다시 끈다.
            if view.window != nil {
                setSwipeBack(enabled: false)
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            setSwipeBack(enabled: true)
        }

        /// 밀어서 뒤로 가는 제스처 두 가지(왼쪽 가장자리에서 밀기, 화면 어디서든 밀기)를 모두 켜거나 끈다.
        private func setSwipeBack(enabled: Bool) {
            // SwiftUI가 이 컨트롤러를 내비게이션 아래에 직접 달아 주지 않을 수 있어서, 창 전체에서 찾는다.
            var found: [UINavigationController] = []
            func collect(_ controller: UIViewController?) {
                guard let controller else { return }
                if let navigation = controller as? UINavigationController {
                    found.append(navigation)
                }
                controller.children.forEach(collect)
            }
            collect(view.window?.rootViewController)
            if let own = navigationController {
                found.append(own)
            }
            // "어디서든 밀기"는 iOS 26에서 생겼다. 옛 개발 도구로도 빌드되도록 이름으로 찾아 쓴다.
            let contentPop = "interactiveContentPopGestureRecognizer"
            for navigation in found {
                navigation.interactivePopGestureRecognizer?.isEnabled = enabled
                if navigation.responds(to: NSSelectorFromString(contentPop)),
                   let recognizer = navigation.value(forKey: contentPop) as? UIGestureRecognizer {
                    recognizer.isEnabled = enabled
                }
            }
        }
    }
}

/// 공유 화면에 넘길 것: PDF 파일의 URL 또는 텍스트
struct SharedItem: Identifiable {
    let id = UUID()
    let item: Any
}

struct ActivityView: UIViewControllerRepresentable {
    let item: Any

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
