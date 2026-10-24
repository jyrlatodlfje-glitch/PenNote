import SwiftUI

@main
struct PenNoteApp: App {
    @StateObject private var store: NoteStore

    init() {
        let store = NoteStore()
        _store = StateObject(wrappedValue: store)
        // 워치가 아이폰 앱을 화면 없이 깨울 수도 있으므로 화면보다 먼저 연결해 둔다.
        WatchLink.shared.activate(store: store)
    }

    var body: some Scene {
        WindowGroup {
            NoteListView()
                .environmentObject(store)
        }
    }
}
