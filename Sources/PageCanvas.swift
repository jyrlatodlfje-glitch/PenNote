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
