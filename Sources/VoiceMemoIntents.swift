import AppIntents

// 단축어·Siri에서 쓰는 음성 메모 동작. 아이폰 단축어 앱에서 만든 단축어를
// "Apple Watch에서 보기"로 켜 두면 워치 단축어·시계화면에서 누를 수 있다.

/// PenNote를 열고 아이폰 마이크로 받아 적기를 시작한다. 연 뒤에는 화면을 꺼도 계속된다.
struct StartVoiceMemoIntent: AppIntent {
    static var title: LocalizedStringResource = "음성 메모 시작"
    static var description = IntentDescription("PenNote를 열고 아이폰 마이크로 받아 적기를 시작합니다.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        VoiceMemoCenter.shared.start(folderID: nil)
        return .result(dialog: "받아 적기를 시작했습니다.")
    }
}

/// 시험용: PenNote 화면을 열지 않고 시작한다. 아이폰이 잠겨 있어도 되는지 확인하려는 것.
@available(iOS 18.0, *)
struct StartVoiceMemoQuietIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "음성 메모 시작 (화면 안 열기)"
    static var description = IntentDescription("PenNote 화면을 열지 않고 아이폰 마이크로 받아 적기를 시작합니다.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        VoiceMemoCenter.shared.start(folderID: nil)
        return .result(dialog: "받아 적기를 시작했습니다.")
    }
}

/// 받아 적던 메모를 멈추고 새 노트("MM-dd HH:mm 음성 메모")로 저장한다.
struct StopVoiceMemoIntent: AppIntent {
    static var title: LocalizedStringResource = "음성 메모 멈추고 저장"
    static var description = IntentDescription("받아 적던 음성 메모를 멈추고 새 노트로 저장합니다.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let note = VoiceMemoCenter.shared.stopAndSave() else {
            return .result(dialog: "받아 적는 중인 메모가 없습니다.")
        }
        return .result(dialog: "\(note.title) 노트로 저장했습니다.")
    }
}

/// 단축어 앱에 따로 만들지 않아도 PenNote 동작이 바로 보이게 한다.
struct PenNoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartVoiceMemoIntent(),
                    phrases: ["\(.applicationName) 음성 메모 시작", "Start voice memo in \(.applicationName)"])
        AppShortcut(intent: StopVoiceMemoIntent(),
                    phrases: ["\(.applicationName) 음성 메모 저장", "Save voice memo in \(.applicationName)"])
    }
}
