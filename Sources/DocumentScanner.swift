import CoreMotion
import SwiftUI
import VisionKit

/// 문서 스캔 화면. 종이의 가장자리를 찾아 잘라내고, 비스듬히 찍힌 것을 반듯하게 펴 준다 (iOS 기본 기능).
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    /// 지난 스캔 동안 휴대폰을 주로 어느 방향으로 들고 있었는지.
    /// 스캔 화면은 세로로만 보여서, 가로로 들고 찍은 사진은 옆으로 누워 나온다. 책 스캔이 이것으로 바로 세운다.
    static var heldOrientation = UIDeviceOrientation.portrait

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        context.coordinator.startWatchingOrientation()
        return scanner
    }

    func updateUIViewController(_ scanner: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let parent: DocumentScanner
        private let motion = CMMotionManager()
        private var counts: [UIDeviceOrientation: Int] = [:]

        init(_ parent: DocumentScanner) {
            self.parent = parent
        }

        /// 스캔하는 동안 0.3초마다 휴대폰이 어느 쪽으로 기울어 있는지 세어 둔다.
        /// 화면 방향 표시(UIDevice.orientation)는 책상 위 책을 내려다보며 찍으면 "바닥을 향함"이 되고,
        /// 화면 세로 고정을 켜 두면 세로로만 나와서 쓰지 않는다. 대신 중력 방향을 직접 본다.
        func startWatchingOrientation() {
            counts = [:]
            guard motion.isDeviceMotionAvailable else { return }
            motion.deviceMotionUpdateInterval = 0.3
            motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
                guard let self, let gravity = data?.gravity else { return }
                // 휴대폰 화면 기준: x는 오른쪽, y는 위쪽. 위쪽이 왼쪽으로 가게 들면(landscapeLeft) 오른쪽이 위가 되어 x가 음수.
                let x = gravity.x, y = gravity.y
                if abs(x) > abs(y) + 0.05 {
                    self.counts[x < 0 ? .landscapeLeft : .landscapeRight, default: 0] += 1
                } else if abs(y) > abs(x) + 0.05 {
                    self.counts[.portrait, default: 0] += 1
                }
            }
        }

        private func stopWatchingOrientation() {
            motion.stopDeviceMotionUpdates()
            DocumentScanner.heldOrientation = counts.max { $0.value < $1.value }?.key ?? .portrait
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            stopWatchingOrientation()
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            parent.dismiss()
            parent.onScan(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            stopWatchingOrientation()
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            stopWatchingOrientation()
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
