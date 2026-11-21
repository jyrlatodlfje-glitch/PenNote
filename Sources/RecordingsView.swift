import SwiftUI
import UniformTypeIdentifiers

struct RecordingsView: View {
    @ObservedObject var audio: AudioRecorder
    let onTranscript: (String) -> Void

    @ObservedObject private var transcriber = Transcriber.shared
    @State private var showImporter = false
    @State private var recordingsToDelete: [URL] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(audio.recordings, id: \.self) { url in
                    HStack(spacing: 16) {
                        Button {
                            audio.togglePlayback(url)
                        } label: {
                            Label(url.deletingPathExtension().lastPathComponent,
                                  systemImage: audio.playing == url ? "stop.circle.fill" : "play.circle")
                        }
                        .disabled(audio.isRecording)
                        Spacer()
                        if transcriber.busy == url {
                            ProgressView()
                        } else {
                            Menu {
                                Button("한국어 (빠름)") { transcribe(url, mode: .fast("ko-KR")) }
                                Button("English (빠름)") { transcribe(url, mode: .fast("en-US")) }
                                Button("한·영 혼합 (느림)") { transcribe(url, mode: .mixed) }
                                Section("누가 말했는지 나누기 (회의용)") {
                                    Button("한국어 + 화자 구분") {
                                        transcribe(url, mode: .fast("ko-KR"), speakers: true)
                                    }
                                    Button("English + 화자 구분") {
                                        transcribe(url, mode: .fast("en-US"), speakers: true)
                                    }
                                    Button("한·영 혼합 + 화자 구분 (느림)") {
                                        transcribe(url, mode: .mixed, speakers: true)
                                    }
                                }
                            } label: {
                                Image(systemName: "text.bubble")
                            }
                            .disabled(transcriber.busy != nil || audio.isRecording)
                        }
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(.borderless)
                }
                .onDelete { offsets in
                    // 바로 지우지 않고 묻는다 — 1시간 회의 녹음도 되살릴 수 없게 지워지므로(2026-11-21).
                    recordingsToDelete = offsets.map { audio.recordings[$0] }
                }
            }
            .confirmationDialog("녹음을 지울까요?",
                                isPresented: Binding(get: { !recordingsToDelete.isEmpty },
                                                     set: { if !$0 { recordingsToDelete = [] } }),
                                titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    let urls = recordingsToDelete
                    recordingsToDelete = []
                    urls.forEach(audio.delete)
                }
                Button("취소", role: .cancel) { recordingsToDelete = [] }
            } message: {
                Text("녹음 파일이 지워지고 되살릴 수 없습니다.")
            }
            .overlay {
                if audio.recordings.isEmpty {
                    Text("이 노트에는 녹음이 없습니다")
                        .foregroundColor(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if transcriber.busy != nil {
                    Text(transcriber.continuesInBackground
                         ? "\(transcriber.status) · 화면을 꺼도 계속됩니다 (잠금 화면에 진행 표시). 이 창은 닫지 마세요"
                         : "\(transcriber.status) · 끝날 때까지 이 화면을 열어 두세요")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .navigationTitle("녹음")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("불러오기") { showImporter = true }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
                if case .success(let url) = result {
                    audio.importFile(url)
                }
            }
            .alert("음성 변환", isPresented: Binding(
                get: { transcriber.errorMessage != nil },
                set: { if !$0 { transcriber.errorMessage = nil } }
            )) {
                Button("확인", role: .cancel) {}
            } message: {
                Text(transcriber.errorMessage ?? "")
            }
            .onDisappear {
                transcriber.cancel()
            }
        }
    }

    private func transcribe(_ url: URL, mode: Transcriber.Mode, speakers: Bool = false) {
        transcriber.transcribe(url, mode: mode, speakers: speakers) { text in
            onTranscript(text)
            dismiss()
        }
    }
}
