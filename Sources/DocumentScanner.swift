import SwiftUI
import VisionKit

/// 문서 스캔 화면. 종이의 가장자리를 찾아 잘라내고, 비스듬히 찍힌 것을 반듯하게 펴 준다 (iOS 기본 기능).
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner

        init(_ parent: DocumentScanner) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.dismiss()
            parent.onScan(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}

enum ScanImporter {
    /// 스캔한 쪽들을 세로로 이어 붙인 노트를 만든다. 불러온 PDF처럼 쪽은 배경으로 고정되어 그 위에 필기한다.
    static func makeNote(from pages: [UIImage], pageWidth: CGFloat, folderID: UUID?) -> Note? {
        var note = Note()
        note.template = .blank
        note.folderID = folderID
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        note.name = "스캔 " + formatter.string(from: Date())
        let folder = NoteStore.imageFolder(for: note.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let pixelWidth: CGFloat = 1600
        var top: CGFloat = 0
        var breaks: [CGFloat] = []
        for (index, page) in pages.enumerated() where page.size.width > 0 {
            let scale = min(1, pixelWidth / page.size.width)
            let size = CGSize(width: (page.size.width * scale).rounded(), height: (page.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                page.draw(in: CGRect(origin: .zero, size: size))
            }
            let fileName = "scan-\(index + 1).jpg"
            guard let data = image.jpegData(compressionQuality: 0.85),
                  (try? data.write(to: folder.appendingPathComponent(fileName))) != nil else { continue }

            let height = (pageWidth * size.height / size.width).rounded()
            note.images.append(ImageItem(x: 0, y: top, width: pageWidth, height: height,
                                         fileName: fileName, locked: true))
            top += height
            breaks.append(top)
        }
        guard !note.images.isEmpty else { return nil }
        note.pageBreaks = breaks
        return note
    }
}
