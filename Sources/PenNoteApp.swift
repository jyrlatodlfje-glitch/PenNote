import SwiftUI

@main
struct PenNoteApp: App {
    @StateObject private var store: NoteStore

    init() {
        let store = NoteStore()
        _store = StateObject(wrappedValue: store)
        // 단축어로 음성 메모를 저장할 때도 같은 노트 저장소를 쓴다.
        VoiceMemoCenter.shared.store = store
    }

    var body: some Scene {
        WindowGroup {
            NoteListView()
                .environmentObject(store)
        }
    }
}
