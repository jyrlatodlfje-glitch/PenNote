import CoreImage
import UIKit
import Vision

/// 책 스캔 보정: 펼친 두 쪽 나누기 → 손가락 지우기 → 휜 글줄 펴기.
/// 학습된 전용 AI가 아니라 화면 분석과 계산으로 하는 근사 보정이라, 결과는 책과 조명에 따라 달라진다.
enum BookScan {
    /// 한 장을 보정한다. 펼친 책이면 두 장이 되어 나온다.
    static func process(_ page: UIImage) -> [UIImage] {
        guard let whole = normalized(page) else { return [page] }
        return split(whole).map { half in
            let cleaned = removeFingers(from: half) ?? half
            let flat = straightenLines(in: cleaned) ?? cleaned
            return UIImage(cgImage: flat)
        }
    }

    // MARK: - 준비

    /// RGBA 8비트 버퍼. 0번 줄이 그림의 맨 윗줄이다.
    private final class Bitmap {
        let width: Int
        let height: Int
        let context: CGContext
        let data: UnsafeMutablePointer<UInt8>

        init?(width: Int, height: Int) {
            guard width > 0, height > 0,
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let raw = context.data else { return nil }
            self.width = width
            self.height = height
            self.context = context
            self.data = raw.bindMemory(to: UInt8.self, capacity: width * height * 4)
        }

        convenience init?(image: CGImage, width: Int, height: Int) {
            self.init(width: width, height: height)
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// 방향을 바로 세우고, 계산이 너무 오래 걸리지 않게 긴 변을 2200픽셀로 줄인다.
    private static func normalized(_ image: UIImage) -> CGImage? {
        let longSide = max(image.size.width, image.size.height) * image.scale
        guard longSide > 0 else { return nil }
        let scale = min(1, 2200 / longSide)
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(),
                          height: (image.size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    // MARK: - 두 쪽 나누기

    /// 가로로 긴 사진에서 가운데 근처의 어두운 세로 띠(책이 접히는 곳)를 찾아 좌우로 나눈다.
    private static func split(_ image: CGImage) -> [CGImage] {
        let width = image.width
        let height = image.height
        guard Double(width) > Double(height) * 1.25 else { return [image] }
        let smallWidth = 256
        let smallHeight = max(8, smallWidth * height / width)
        guard let small = Bitmap(image: image, width: smallWidth, height: smallHeight) else { return [image] }

        let rows = (smallHeight / 5)..<(smallHeight * 4 / 5)
        var columns = [Double](repeating: 0, count: smallWidth)
        for y in rows {
            for x in 0..<smallWidth {
                let pixel = small.data + (y * smallWidth + x) * 4
                columns[x] += (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3
            }
        }
        let rowCount = Double(rows.count)
        var gutter = smallWidth / 2
        var darkest = Double.infinity
        for x in (smallWidth * 35 / 100)..<(smallWidth * 65 / 100) {
            let value = (columns[x - 2] + columns[x - 1] + columns[x] + columns[x + 1] + columns[x + 2]) / 5 / rowCount
            if value < darkest {
                darkest = value
                gutter = x
            }
        }
        let median = columns.sorted()[smallWidth / 2] / rowCount
        // 접힌 곳이 뚜렷하게 어두울 때만 나눈다. 그냥 가로로 긴 문서를 반으로 자르지 않기 위해서다.
        guard median - darkest > 8 else { return [image] }

        let cut = gutter * width / smallWidth
        guard let left = image.cropping(to: CGRect(x: 0, y: 0, width: cut, height: height)),
              let right = image.cropping(to: CGRect(x: cut, y: 0, width: width - cut, height: height)) else {
            return [image]
        }
        return [left, right]
    }

    // MARK: - 손가락 지우기

    /// 가장자리에 걸친 살색 덩어리를 손가락으로 보고 종이 색으로 덮는다.
    private static func removeFingers(from image: CGImage) -> CGImage? {
        let smallWidth = 320
        let smallHeight = max(8, smallWidth * image.height / image.width)
        guard let small = Bitmap(image: image, width: smallWidth, height: smallHeight) else { return nil }
        let count = smallWidth * smallHeight

        var skin = [Bool](repeating: false, count: count)
        var paper = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        for index in 0..<count {
            let pixel = small.data + index * 4
            let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
            let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            // 누런 종이를 살색으로 잘못 보지 않도록, 붉은 기가 뚜렷한 것만 고른다.
            skin[index] = r > 80 && r - b > 30 && r > g && g > b
                && cr >= 140 && cr <= 180 && cb >= 77 && cb <= 127
            if !skin[index], r + g + b > 540 {
                paper.r += r
                paper.g += g
                paper.b += b
                paper.n += 1
            }
        }
        guard paper.n > 0 else { return nil }

        // 이어진 덩어리별로, 가장자리에 닿아 있고 크기가 손가락만 한 것만 남긴다.
        var mask = [UInt8](repeating: 0, count: count)
        var seen = [Bool](repeating: false, count: count)
        var found = false
        for start in 0..<count where skin[start] && !seen[start] {
            var blob = [start]
            var cursor = 0
            var touchesEdge = false
            seen[start] = true
            while cursor < blob.count {
                let index = blob[cursor]
                cursor += 1
                let x = index % smallWidth
                let y = index / smallWidth
                if x < 2 || y < 2 || x >= smallWidth - 2 || y >= smallHeight - 2 {
                    touchesEdge = true
                }
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, ny >= 0, nx < smallWidth, ny < smallHeight else { continue }
                    let next = ny * smallWidth + nx
                    if skin[next], !seen[next] {
                        seen[next] = true
                        blob.append(next)
                    }
                }
            }
            let share = Double(blob.count) / Double(count)
            if touchesEdge, share > 0.0015, share < 0.10 {
                found = true
                for index in blob {
                    mask[index] = 255
                }
            }
        }
        guard found else { return nil }

        // 손가락 테두리와 그림자까지 덮이도록 조금 넓힌다.
        let radius = 4
        var widened = mask
        for y in 0..<smallHeight {
            for x in 0..<smallWidth where mask[y * smallWidth + x] == 0 {
                var hit = false
                for ny in max(0, y - radius)...min(smallHeight - 1, y + radius) where !hit {
                    for nx in max(0, x - radius)...min(smallWidth - 1, x + radius) where mask[ny * smallWidth + nx] != 0 {
                        hit = true
                        break
                    }
                }
                if hit {
                    widened[y * smallWidth + x] = 255
                }
            }
        }

        guard let maskImage = widened.withUnsafeMutableBytes({ bytes -> CGImage? in
            CGContext(data: bytes.baseAddress, width: smallWidth, height: smallHeight, bitsPerComponent: 8,
                      bytesPerRow: smallWidth, space: CGColorSpaceCreateDeviceGray(),
                      bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage()
        }) else { return nil }

        let source = CIImage(cgImage: image)
        let enlarge = CGFloat(image.width) / CGFloat(smallWidth)
        let softMask = CIImage(cgImage: maskImage)
            .transformed(by: CGAffineTransform(scaleX: enlarge, y: CGFloat(image.height) / CGFloat(smallHeight)))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(enlarge) * 1.5)
            .cropped(to: source.extent)
        let cover = CIImage(color: CIColor(red: CGFloat(paper.r / paper.n / 255),
                                           green: CGFloat(paper.g / paper.n / 255),
                                           blue: CGFloat(paper.b / paper.n / 255)))
            .cropped(to: source.extent)
        let result = cover.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: source,
            kCIInputMaskImageKey: softMask,
        ])
        return CIContext().createCGImage(result, from: source.extent)
    }

    // MARK: - 휜 글줄 펴기

    /// 글줄 하나가 휜 모양을 다항식으로 나타낸 것
    private struct TextLine {
        let minX: Double
        let maxX: Double
        let coefficients: [Double]
        var target = 0.0

        /// 가로 위치 x에서 이 글줄의 세로 위치. 글줄 밖의 x는 양 끝의 값으로 본다.
        func y(at x: Double) -> Double {
            let clamped = min(max(x, minX), maxX)
            let t = (clamped - (minX + maxX) / 2) / max(1, (maxX - minX) / 2)
            return coefficients.reversed().reduce(0) { $0 * t + $1 }
        }
    }

    /// 글자 위치를 따라 글줄이 휜 모양을 재고, 각 글줄이 수평이 되도록 그림을 위아래로 당겨 편다.
    /// 책 가운데로 갈수록 글자 폭이 좁아지는 것까지는 펴지 못한다.
    private static func straightenLines(in image: CGImage) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 8, height > 8 else { return nil }
        let lines = textLines(in: image)
        guard lines.count >= 3 else { return nil }

        // 이미 반듯하면 건드리지 않는다.
        let worst = lines.map { line -> Double in
            stride(from: line.minX, through: line.maxX, by: max(1, (line.maxX - line.minX) / 16))
                .map { abs(line.y(at: $0) - line.target) }.max() ?? 0
        }.max() ?? 0
        guard worst > 2 else { return nil }

        /// (x, y)에 있는 점이 원래 자리에서 아래로 얼마나 밀려 있는지
        func shift(_ x: Double, _ y: Double) -> Double {
            let samples = lines.map { (y: $0.y(at: x), shift: $0.y(at: x) - $0.target) }.sorted { $0.y < $1.y }
            guard let first = samples.first, let last = samples.last else { return 0 }
            if y <= first.y { return first.shift }
            if y >= last.y { return last.shift }
            for index in 1..<samples.count where y <= samples[index].y {
                let above = samples[index - 1]
                let below = samples[index]
                let ratio = (y - above.y) / max(0.001, below.y - above.y)
                return above.shift + (below.shift - above.shift) * ratio
            }
            return last.shift
        }

        // 성긴 격자에서만 계산해 두고, 픽셀마다는 격자 사이를 보간한다.
        let gridX = 32
        let gridY = 64
        var grid = [Double](repeating: 0, count: (gridX + 1) * (gridY + 1))
        for gy in 0...gridY {
            for gx in 0...gridX {
                let x = Double(gx) / Double(gridX) * Double(width - 1)
                let y = Double(gy) / Double(gridY) * Double(height - 1)
                // 편 그림의 (x, y)에 올 점을 원본에서 찾는다.
                var source = y
                for _ in 0..<3 {
                    source = y + shift(x, source)
                }
                grid[gy * (gridX + 1) + gx] = source - y
            }
        }

        guard let input = Bitmap(image: image, width: width, height: height),
              let output = Bitmap(width: width, height: height) else { return nil }
        var rowShift = [Double](repeating: 0, count: gridX + 1)
        for y in 0..<height {
            let gyPosition = Double(y) / Double(height - 1) * Double(gridY)
            let gy = min(gridY - 1, Int(gyPosition))
            let gyRatio = gyPosition - Double(gy)
            for gx in 0...gridX {
                let above = grid[gy * (gridX + 1) + gx]
                let below = grid[(gy + 1) * (gridX + 1) + gx]
                rowShift[gx] = above + (below - above) * gyRatio
            }
            for x in 0..<width {
                let gxPosition = Double(x) / Double(width - 1) * Double(gridX)
                let gx = min(gridX - 1, Int(gxPosition))
                let moved = rowShift[gx] + (rowShift[gx + 1] - rowShift[gx]) * (gxPosition - Double(gx))
                let sourceY = min(max(Double(y) + moved, 0), Double(height - 1))
                let top = min(height - 2, Int(sourceY))
                let ratio = sourceY - Double(top)
                let upper = input.data + (top * width + x) * 4
                let lower = input.data + ((top + 1) * width + x) * 4
                let target = output.data + (y * width + x) * 4
                for channel in 0..<3 {
                    target[channel] = UInt8(Double(upper[channel]) * (1 - ratio) + Double(lower[channel]) * ratio)
                }
                target[3] = 255
            }
        }
        return output.context.makeImage()
    }

    /// 그림에서 글줄을 찾아, 글자들의 위치로 각 글줄이 휜 모양을 구한다.
    private static func textLines(in image: CGImage) -> [TextLine] {
        let width = Double(image.width)
        let height = Double(image.height)
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = true
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observations = request.results else { return [] }

        // 찾은 글 조각마다 글자 중심점을 모은다. Vision 좌표는 왼쪽 아래가 원점이라 위아래를 뒤집는다.
        struct Piece {
            var points: [(x: Double, y: Double)]
            var size: Double
        }
        let pieces: [Piece] = observations.compactMap { observation in
            var points: [(x: Double, y: Double)]
            var size = Double(observation.boundingBox.height) * height
            if let boxes = observation.characterBoxes, boxes.count >= 2 {
                points = boxes.map { (Double($0.boundingBox.midX) * width, (1 - Double($0.boundingBox.midY)) * height) }
                size = boxes.map { Double($0.boundingBox.height) * height }.sorted()[boxes.count / 2]
            } else {
                points = [
                    (Double(observation.topLeft.x + observation.bottomLeft.x) / 2 * width,
                     (1 - Double(observation.topLeft.y + observation.bottomLeft.y) / 2) * height),
                    (Double(observation.topRight.x + observation.bottomRight.x) / 2 * width,
                     (1 - Double(observation.topRight.y + observation.bottomRight.y) / 2) * height),
                ]
            }
            points.sort { $0.x < $1.x }
            return points.isEmpty ? nil : Piece(points: points, size: max(4, size))
        }.sorted { $0.points[0].x < $1.points[0].x }

        // 낱말 단위로 찾아진 조각들을 왼쪽부터 이어 붙여 한 줄로 묶는다.
        var groups: [Piece] = []
        for piece in pieces {
            guard let head = piece.points.first else { continue }
            var best: Int?
            var bestGap = Double.infinity
            for (index, group) in groups.enumerated() {
                guard let tail = group.points.last else { continue }
                let size = max(group.size, piece.size)
                let gapX = head.x - tail.x
                let gapY = abs(head.y - tail.y)
                if gapX > -size * 0.5, gapX < size * 4, gapY < size * 0.6, gapY < bestGap {
                    best = index
                    bestGap = gapY
                }
            }
            if let best {
                groups[best].points.append(contentsOf: piece.points)
            } else {
                groups.append(piece)
            }
        }

        return groups.compactMap { group -> TextLine? in
            guard group.points.count >= 6, let first = group.points.first, let last = group.points.last,
                  last.x - first.x > width * 0.3 else { return nil }
            let middle = (first.x + last.x) / 2
            let half = max(1, (last.x - first.x) / 2)
            let scaled = group.points.map { (x: ($0.x - middle) / half, y: $0.y) }
            guard let coefficients = fit(scaled, degree: group.points.count >= 10 ? 3 : 2) else { return nil }
            var line = TextLine(minX: first.x, maxX: last.x, coefficients: coefficients)
            // 다항식이 글자 위치를 잘 따라가지 못하는 줄(잘못 묶인 줄)은 버린다.
            let error = (group.points.map { pow(line.y(at: $0.x) - $0.y, 2) }.reduce(0, +)
                / Double(group.points.count)).squareRoot()
            guard error < group.size * 0.5 else { return nil }
            let samples = stride(from: first.x, through: last.x, by: (last.x - first.x) / 16).map { line.y(at: $0) }
            line.target = samples.reduce(0, +) / Double(samples.count)
            return line
        }
    }

    /// 최소제곱법으로 다항식 계수(낮은 차수부터)를 구한다.
    private static func fit(_ points: [(x: Double, y: Double)], degree: Int) -> [Double]? {
        let size = degree + 1
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: size + 1), count: size)
        for point in points {
            var powers = [Double](repeating: 1, count: size * 2)
            for index in 1..<(size * 2) {
                powers[index] = powers[index - 1] * point.x
            }
            for row in 0..<size {
                for column in 0..<size {
                    matrix[row][column] += powers[row + column]
                }
                matrix[row][size] += powers[row] * point.y
            }
        }
        for index in 0..<size {
            var pivot = index
            for row in index..<size where abs(matrix[row][index]) > abs(matrix[pivot][index]) {
                pivot = row
            }
            guard abs(matrix[pivot][index]) > 1e-9 else { return nil }
            matrix.swapAt(index, pivot)
            for row in 0..<size where row != index {
                let factor = matrix[row][index] / matrix[index][index]
                for column in index...size {
                    matrix[row][column] -= factor * matrix[index][column]
                }
            }
        }
        return (0..<size).map { matrix[$0][size] / matrix[$0][$0] }
    }
}
