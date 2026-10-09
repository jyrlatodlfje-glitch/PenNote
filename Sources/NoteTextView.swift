import SwiftUI
import UIKit

/// 글씨 칸에서 인식된 글자를 커서 위치에 넣고 지우는 통로.
final class EditorController: ObservableObject {
    fileprivate(set) weak var textView: UITextView?

    func insert(_ string: String) {
        guard let textView else { return }
        textView.insertText(string)
        notifyChange(textView)
    }

    func backspace() {
        guard let textView else { return }
        textView.deleteBackward()
        notifyChange(textView)
    }

    /// 커서 바로 앞이 `old`일 때만 `new`로 바꾼다.
    func replaceBeforeCursor(_ old: String, with new: String) -> Bool {
        guard let textView,
              let selection = textView.selectedTextRange, selection.isEmpty,
              let start = textView.position(from: selection.start, offset: -(old as NSString).length),
              let range = textView.textRange(from: start, to: selection.start),
              textView.text(in: range) == old else { return false }
        textView.replace(range, withText: new)
        notifyChange(textView)
        return true
    }

    private func notifyChange(_ textView: UITextView) {
        textView.delegate?.textViewDidChange?(textView)
    }
}

struct NoteTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: EditorController
    let useKeyboard: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.delegate = context.coordinator
        textView.text = text
        // 빈 inputView를 주면 커서는 유지되고 시스템 키보드만 숨겨진다.
        textView.inputView = useKeyboard ? nil : UIView()
        controller.textView = textView
        DispatchQueue.main.async { textView.becomeFirstResponder() }
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
        let keyboardHidden = textView.inputView != nil
        if keyboardHidden == useKeyboard {
            textView.inputView = useKeyboard ? nil : UIView()
            textView.reloadInputViews()
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            if text.wrappedValue != textView.text {
                text.wrappedValue = textView.text
            }
        }
    }
}
