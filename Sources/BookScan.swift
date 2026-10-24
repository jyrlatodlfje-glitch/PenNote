import CoreImage
import UIKit
import Vision

/// 책 스캔 보정: 방향 바로 세우기 → 손가락 지우기 → 휜 글줄 펴기.
/// 학습된 전용 AI가 아니라 화면 분석과 계산으로 하는 근사 보정이라, 결과는 책과 조명에 따라 달라진다.
enum BookScan {
    /// 한 장을 보정한다. 가로로 찍은 펼친 책은 나누지 않고 가로 한 장 그대로 둔다
    /// (2026-10-24 사용자: "스캔을 가로로 찍으면 노트에 보이는것도 가로로 보고 싶은데").
    /// `held`: 스캔하는 동안 휴대폰을 들고 있던 방향.
    static func process(_ page: UIImage, held: UIDeviceOrientation = .portrait) -> [UIImage] {
        guard let normal = normalized(page) else { return [page] }
        let whole = upright(normal, held: held)
        let cleaned = removeFingers(from: whole) ?? whole
        let flat = straightenLines(in: cleaned) ?? cleaned
        return [UIImage(cgImage: flat)]
    }

    /// 문서 스캔용: 찍은 방향 그대로 보이게 돌리기만 한다(손가락 지우기·글줄 펴기는 하지 않음).
    /// (2026-10-24 사용자: 문서 스캔도 "찍은 방향 그대로"로 — "응.")
    static func orient(_ page: UIImage, held: UIDeviceOrientation) -> UIImage {
        guard held.isLandscape, let normal = normalized(page) else { return page }
        let turned = upright(normal, held: held)
        return turned === normal ? page : UIImage(cgImage: turned)
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

    // MARK: - 글자 방향 바로 세우기

    /// 찍은 방향 그대로 보이게 돌린다: 세로로 들고 찍으면 세로, 가로로 들고 찍으면 가로
    /// (2026-10-24 사용자: "가로로 스캔하면 노트에도 가로로 나오고, 세로로 찍으면 노트에서 세로로 나오게").
    /// 스캔 화면은 세로로만 보여서, 가로로 들고 찍은 사진은 옆으로 누워 나오므로 그것을 바로 세운다.
    /// 들고 있던 방향이 먼저다: 세로로 들고 찍었으면 돌리지 않고, 가로로 들고 찍었는데 사진이 세로로 길면 90° 돌린다.
    /// (전에는 글자가 "읽히면" 돌리지 않았는데, 애플의 글자 인식은 옆으로 누운 글자도 읽어 내서 돌리지 않는 일이 있었다.
    ///  2026-10-24 사용자: "가로로 찍은 책이 노트에서는 세로로 나온다는거야. 그래서 볼때마다 내가 가로로 돌려줘야해.")
    /// 왼쪽·오른쪽 중 어느 쪽으로 돌릴지는 ① 글자가 이어지는 방향 ② 더 잘 읽히는 쪽 ③ 들고 있던 방향 순서로 정한다.
    private static func upright(_ image: CGImage, held: UIDeviceOrientation) -> CGImage {
        guard held.isLandscape, image.height > image.width else { return image }
        // 휴대폰 위쪽이 왼쪽으로 가게 들면(landscapeLeft) 사진 속 책은 시계 방향으로 누워 있다.
        var best: CGImagePropertyOrientation = held == .landscapeLeft ? .left : .right
        // 펼친 책 두 쪽이 한 사진에 들어가 글자가 작으므로 줄이지 않고 읽는다(긴 변 2200픽셀 이하).
        let (upScore, direction) = readText(image, as: .up)
        if direction > 20 {
            best = .right  // 글자가 아래에서 위로 이어진다 → 시계 반대 방향으로 누움 → 시계 방향으로 돌린다
        } else if direction < -20 {
            best = .left   // 글자가 위에서 아래로 이어진다 → 시계 방향으로 누움 → 시계 반대 방향으로 돌린다
        } else if upScore < 150 {
            let rightScore = readText(image, as: .right).score
            let leftScore = readText(image, as: .left).score
            if max(rightScore, leftScore) > 20, max(rightScore, leftScore) > min(rightScore, leftScore) * 1.5 {
                best = rightScore > leftScore ? .right : .left
            }
        }
        let rotated = CIImage(cgImage: image).oriented(best)
        return CIContext().createCGImage(rotated, from: rotated.extent) ?? image
    }

    /// 그림을 `orientation` 방향으로 놓고 읽는다.
    /// `score`: 읽힌 글자 수 × 확신도. `direction`: 세로로 이어지는 글줄의 글자 수 합(아래→위는 +, 위→아래는 −).
    private static func readText(_ image: CGImage, as orientation: CGImagePropertyOrientation) -> (score: Double, direction: Double) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:]).perform([request])) != nil
        else { return (0, 0) }
        var score = 0.0
        var direction = 0.0
        for observation in request.results ?? [] {
            guard let top = observation.topCandidates(1).first else { continue }
            let count = Double(top.string.count)
            score += Double(top.confidence) * count
            // 글줄의 왼쪽 위 → 오른쪽 위가 글자가 이어지는 방향이다. Vision 좌표는 위쪽이 + 다.
            let dx = Double(observation.topRight.x - observation.topLeft.x) * Double(image.width)
            let dy = Double(observation.topRight.y - observation.topLeft.y) * Double(image.height)
            if count >= 3, abs(dy) > abs(dx) * 2 {
                direction += dy > 0 ? count : -count
            }
        }
        return (score, direction)
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

    /// 손가락을 찾아 종이 색으로 덮는다. 손가락이 가린 글자는 되살릴 수 없다.
    /// 두 가지로 찾는다: ① 가장자리 근처의 살색 덩어리(종이보다 뚜렷이 붉은 것) ② 애플의 손 인식(손가락 마디 위치).
    private static func removeFingers(from image: CGImage) -> CGImage? {
        let smallWidth = 320
        let smallHeight = max(8, smallWidth * image.height / image.width)
        guard let small = Bitmap(image: image, width: smallWidth, height: smallHeight) else { return nil }
        let count = smallWidth * smallHeight

        // 종이 색: 밝은 점들의 평균. 누런 종이를 살색으로 보지 않도록 종이의 붉은 정도를 기준으로 삼는다.
        var paper = (r: 0.0, g: 0.0, b: 0.0, n: 0.0)
        for index in 0..<count {
            let pixel = small.data + index * 4
            let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
            if r + g + b > 480 {
                paper.r += r
                paper.g += g
                paper.b += b
                paper.n += 1
            }
        }
        guard paper.n > 0 else { return nil }
        let paperRedness = (paper.r - paper.b) / paper.n

        var skin = [Bool](repeating: false, count: count)
        var warm = [Bool](repeating: false, count: count)
        for index in 0..<count {
            let pixel = small.data + index * 4
            let r = Double(pixel[0]), g = Double(pixel[1]), b = Double(pixel[2])
            let cb = 128 - 0.168736 * r - 0.331264 * g + 0.5 * b
            let cr = 128 + 0.5 * r - 0.418688 * g - 0.081312 * b
            warm[index] = r > g && r > b && r - b > paperRedness + 10
            skin[index] = r > 60 && r > g && r > b && r - b > max(15, paperRedness + 18)
                && cr >= 135 && cr <= 185 && cb >= 80 && cb <= 135
        }

        // 이어진 덩어리별로, 가장자리 근처에 있고 크기가 손가락만 한 것만 남긴다.
        // (책을 잡은 손가락은 쪽의 가장자리에서 들어온다.)
        let band = max(3, min(smallWidth, smallHeight) * 8 / 100)
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
                if x < band || y < band || x >= smallWidth - band || y >= smallHeight - band {
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
            if touchesEdge, share > 0.0008, share < 0.20 {
                found = true
                for index in blob {
                    mask[index] = 255
                }
            }
        }
        if let hand = handMask(in: image, width: smallWidth, height: smallHeight, warm: warm) {
            for index in 0..<count where hand[index] != 0 {
                mask[index] = 255
                found = true
            }
        }
        guard found else { return nil }

        // 손가락 테두리와 그림자까지 덮이도록 조금 넓힌다.
        let radius = 5
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

    /// 애플의 손 인식으로 손가락 마디를 찾아, 마디를 잇는 굵은 선으로 손가락 자리를 표시한다.
    /// 글자를 손가락으로 잘못 보는 일을 막으려고, 표시한 자리의 4분의 1 이상이 붉은 기를 띨 때만 쓴다.
    private static func handMask(in image: CGImage, width: Int, height: Int, warm: [Bool]) -> [UInt8]? {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 4
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let hands = request.results, !hands.isEmpty,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let raw = context.data else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let fingers: [[VNHumanHandPoseObservation.JointName]] = [
            [.thumbTip, .thumbIP, .thumbMP, .thumbCMC],
            [.indexTip, .indexDIP, .indexPIP, .indexMCP],
            [.middleTip, .middleDIP, .middlePIP, .middleMCP],
            [.ringTip, .ringDIP, .ringPIP, .ringMCP],
            [.littleTip, .littleDIP, .littlePIP, .littleMCP],
        ]
        var drew = false
        for hand in hands {
            guard let points = try? hand.recognizedPoints(.all) else { continue }
            // Vision과 CGContext 모두 왼쪽 아래가 원점이라 그대로 그린다.
            func spot(_ name: VNHumanHandPoseObservation.JointName) -> CGPoint? {
                guard let point = points[name], point.confidence > 0.5 else { return nil }
                return CGPoint(x: point.location.x * CGFloat(width), y: point.location.y * CGFloat(height))
            }
            // 손가락 굵기: 검지와 새끼 손가락 뿌리 사이의 3분의 1. 모르면 그림 짧은 변의 4%.
            var thickness = CGFloat(min(width, height)) * 0.04
            if let index = spot(.indexMCP), let little = spot(.littleMCP) {
                thickness = max(3, hypot(index.x - little.x, index.y - little.y) / 3)
            }
            context.setLineWidth(thickness)
            for finger in fingers {
                let spots = finger.compactMap(spot)
                guard spots.count >= 2 else { continue }
                context.addLines(between: spots)
                context.strokePath()
                drew = true
            }
        }
        guard drew else { return nil }

        let pixels = raw.bindMemory(to: UInt8.self, capacity: width * height)
        var mask = [UInt8](repeating: 0, count: width * height)
        var marked = 0
        var warmMarked = 0
        for index in 0..<(width * height) where pixels[index] > 127 {
            mask[index] = 255
            marked += 1
            if warm[index] { warmMarked += 1 }
        }
        guard marked > 0, Double(warmMarked) / Double(marked) >= 0.25 else { return nil }
        return mask
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
