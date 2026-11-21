import CoreML
import Foundation
import FluidAudio

/// 받아 적은 글 한 토막과 그 말이 녹음에서 나온 시각(초).
struct SpokenPiece {
    let start: Double
    let end: Double
    let text: String
}

/// 녹음에서 누가 언제 말했는지 나누고(FluidAudio, 기기 안에서), 받아 적은 글에 "화자 1·2·3"을 붙인다.
/// 모델은 처음 한 번만 인터넷으로 내려받고, 그 뒤에는 인터넷 없이 돈다.
/// 이 파일에서만 FluidAudio를 쓴다(WhisperKit과 같은 이름의 형식이 있어도 겹치지 않게).
enum SpeakerLabeler {
    private struct Turn {
        let speaker: String
        let start: Double
        let end: Double
    }

    /// 녹음 파일을 화자별로 나눠 글을 붙여 돌려준다.
    /// progress 는 0~1(어느 스레드에서 불릴지 모름).
    static func label(_ pieces: [SpokenPiece], audio url: URL,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> String {
        let manager = OfflineDiarizerManager()
        // 그래픽 칩(GPU)은 화면이 꺼지면 따로 허락이 있어야 쓸 수 있어, CPU와 뉴럴 엔진만 쓴다.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        try await manager.prepareModels(configuration: configuration)
        let result = try await manager.process(url) { done, total in
            progress(total > 0 ? Double(done) / Double(total) : 0)
        }
        let turns = result.segments.map {
            Turn(speaker: $0.speakerId,
                 start: Double($0.startTimeSeconds),
                 end: Double($0.endTimeSeconds))
        }
        // 시작이 같으면 끝·화자 이름으로 — 정렬 순서에 따라 결과가 바뀌지 않게.
        .sorted { ($0.start, $0.end, $0.speaker) < ($1.start, $1.end, $1.speaker) }
        // 사람을 하나도 못 찾았는데 모두 "화자 1"로 적으면 잘 나뉜 것처럼 보이므로, 실패로 알린다.
        guard !turns.isEmpty else {
            throw NSError(domain: "PenNote", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "녹음에서 말하는 사람을 찾지 못했습니다",
            ])
        }
        return format(pieces, turns: turns)
    }

    private static func format(_ pieces: [SpokenPiece], turns: [Turn]) -> String {
        // 처음 말한 사람부터 화자 1, 2, 3 … 으로 부른다.
        var numbers: [String: Int] = [:]
        var blocks: [(number: Int, start: Double, text: String)] = []
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let number: Int
            if let speaker = speaker(for: piece, in: turns) {
                if let known = numbers[speaker] {
                    number = known
                } else {
                    number = numbers.count + 1
                    numbers[speaker] = number
                }
            } else {
                // 화자를 못 찾으면 바로 앞 사람의 말로 이어 붙인다.
                number = blocks.last?.number ?? 1
            }
            if let last = blocks.last, last.number == number {
                blocks[blocks.count - 1].text = last.text + " " + text
            } else {
                blocks.append((number, piece.start, text))
            }
        }
        return blocks
            .map { "[\(clock($0.start))] 화자 \($0.number): \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// 글 토막의 화자. turns 는 시작 시각 순으로 정렬돼 있어야 한다(같으면 먼저 나온 구간).
    /// ① 기본: 겹친 시간이 가장 긴 사람.
    /// ② 예외(맞장구): 1.2초 미만 짧은 토막을, 1등 구간 길이의 1/4보다 짧은 다른 구간이 절반 이상 덮으면
    ///    그 사람 — 남이 길게 말하는 중 끼어든 "네"를 끼어든 사람에게.
    /// ③ 길이가 0이거나 끝이 시작보다 앞이면: 그 시각에 걸친 구간 중 가장 짧은 것.
    /// ④ 겹치는 사람이 없으면 시각이 가장 가까운 사람.
    /// (2026-11-21 4차 검토 — 가상 회의 2,000개에서 이 방식이 가장 많이 맞힘)
    private static func speaker(for piece: SpokenPiece, in turns: [Turn]) -> String? {
        let length = piece.end - piece.start
        if length <= 0 {
            let time = (piece.start + piece.end) / 2
            let covering = turns.filter { $0.start <= time && time <= $0.end }
            if let shortest = covering.min(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
                return shortest.speaker
            }
            return nearest(time, in: turns)
        }
        var top: (turn: Turn, overlap: Double)?
        var overlaps: [(turn: Turn, overlap: Double)] = []
        for turn in turns {
            let overlap = min(piece.end, turn.end) - max(piece.start, turn.start)
            guard overlap > 0 else { continue }
            overlaps.append((turn, overlap))
            if overlap > (top?.overlap ?? 0) {
                top = (turn, overlap)
            }
        }
        guard let top else {
            return nearest((piece.start + piece.end) / 2, in: turns)
        }
        if length < 1.2 {
            let topLength = top.turn.end - top.turn.start
            let backchannel = overlaps
                .filter { $0.overlap >= length * 0.5 && ($0.turn.end - $0.turn.start) < topLength / 4 }
                .min { ($0.turn.end - $0.turn.start) < ($1.turn.end - $1.turn.start) }
            if let backchannel {
                return backchannel.turn.speaker
            }
        }
        return top.turn.speaker
    }

    private static func nearest(_ time: Double, in turns: [Turn]) -> String? {
        turns.min { distance(time, $0) < distance(time, $1) }?.speaker
    }

    private static func distance(_ time: Double, _ turn: Turn) -> Double {
        if time < turn.start { return turn.start - time }
        if time > turn.end { return time - turn.end }
        return 0
    }

    private static func clock(_ seconds: Double) -> String {
        // 시각 값이 이상하면(NaN·무한대·너무 큼) Int로 바꿀 때 앱이 멈추므로 00:00으로 둔다.
        guard seconds.isFinite, seconds < 1_000_000 else { return "00:00" }
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%02d:%02d", minutes, secs)
    }
}
