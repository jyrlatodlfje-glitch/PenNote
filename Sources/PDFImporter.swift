import PDFKit
import UIKit

enum PDFImporter {
    /// PDF의 각 쪽을 이미지로 바꿔 세로로 이어 붙인 노트를 만든다. 쪽은 배경으로 고정되어 그 위에 필기한다.
    static func makeNote(from url: URL, pageWidth: CGFloat, folderID: UUID?) -> Note? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }

        var note = Note()
        note.template = .blank
        note.name = url.deletingPathExtension().lastPathComponent
        note.folderID = folderID
        let folder = NoteStore.imageFolder(for: note.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let pixelWidth: CGFloat = 1200
        var top: CGFloat = 0
        var breaks: [CGFloat] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var box = page.bounds(for: .mediaBox).size
            if page.rotation % 180 != 0 {
                box = CGSize(width: box.height, height: box.width)
            }
            guard box.width > 0, box.height > 0 else { continue }

            let scale = pixelWidth / box.width
            let pixelSize = CGSize(width: pixelWidth, height: (box.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: pixelSize))
                // PDF 좌표는 아래가 원점이라 위아래를 뒤집어 그린다.
                context.cgContext.translateBy(x: 0, y: pixelSize.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
            guard let data = image.jpegData(compressionQuality: 0.8) else { continue }
            let fileName = "page-\(index + 1).jpg"
            guard (try? data.write(to: folder.appendingPathComponent(fileName))) != nil else { continue }

            let height = (pageWidth * box.height / box.width).rounded()
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
