import AVFoundation

/// 워치와 아이폰이 음성 메모를 주고받을 때 쓰는 약속. 아이폰·워치 앱이 함께 쓴다.
enum VoiceLink {
    /// 워치가 아이폰으로 보내는 소리: 16kHz 한 채널 16비트 정수
    static let sampleRate: Double = 16_000
    static let streamFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                            channels: 1, interleaved: true)!

    // 메시지 열쇠
    static let kind = "kind"
    static let session = "session"
    static let started = "started"
    static let text = "text"
    static let locale = "locale"

    // kind 값
    static let start = "start"
    static let stop = "stop"
    static let live = "live"
    /// 받아 적는 도중 언어를 바꿈
    static let language = "language"

    /// 받아 적는 언어. 평소에는 한국어(영어 낱말이 섞여도 가장 정확), 외국 분과 대화할 때 English.
    static let korean = "ko-KR"
    static let english = "en-US"
    /// 마지막으로 고른 언어를 기억해 두는 열쇠
    static let savedLocaleKey = "voiceMemoLocale"

    static var savedLocale: String {
        UserDefaults.standard.string(forKey: savedLocaleKey) ?? korean
    }

    static func languageName(_ locale: String) -> String {
        locale == english ? "English" : "한국어"
    }

    /// 음성 메모 노트의 제목. 예: "10-24 14:05 워치 메모"
    static func title(for date: Date, fromWatch: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date) + (fromWatch ? " 워치 메모" : " 음성 메모")
    }
}
