import SwiftUI

struct OneNoteSettingsView: View {
    @ObservedObject private var client = OneNoteClient.shared
    @State private var sections: [OneNoteSection] = []
    @State private var busy = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Application (client) ID", text: $client.clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("1. 앱 등록 ID")
                } footer: {
                    Text("Microsoft Entra에서 앱을 등록하고 받은 ID를 붙여넣으세요.")
                }

                Section("2. 로그인") {
                    if client.isSignedIn {
                        Label("로그인됨", systemImage: "checkmark.circle.fill")
                        Button("로그아웃", role: .destructive) {
                            client.signOut()
                            sections = []
                        }
                    } else {
                        Button("Microsoft 계정으로 로그인") {
                            run {
                                try await client.signIn()
                                sections = try await client.sections()
                            }
                        }
                    }
                }

                if client.isSignedIn {
                    Section {
                        ForEach(sections) { section in
                            Button {
                                client.select(section)
                            } label: {
                                HStack {
                                    Text(section.label)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if client.sectionID == section.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Button("섹션 목록 새로 고침") {
                            run { sections = try await client.sections() }
                        }
                    } header: {
                        Text("3. 보낼 위치")
                    } footer: {
                        if !client.sectionName.isEmpty {
                            Text("현재: \(client.sectionName)")
                        }
                    }
                }
            }
            .disabled(busy)
            .overlay {
                if busy {
                    ProgressView()
                }
            }
            .navigationTitle("OneNote 연결")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .task {
                if client.isSignedIn {
                    run { sections = try await client.sections() }
                }
            }
            .alert("OneNote", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task { @MainActor in
            do {
                try await work()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}
