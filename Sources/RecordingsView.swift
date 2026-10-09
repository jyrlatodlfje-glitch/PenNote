import SwiftUI
import UniformTypeIdentifiers

struct RecordingsView: View {
    @ObservedObject var audio: AudioRecorder
    let onTranscript: (String) -> Void

    @ObservedObject private var transcriber = Transcriber.shared
    @State private var showImporter = false
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
                                Button("한국어 위주 (영어 단어 섞임)") { transcribe(url, language: "ko") }
                                Button("언어 자동 판별") { transcribe(url, language: nil) }
                                Button("English") { transcribe(url, language: "en") }
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
                    offsets.map { audio.recordings[$0] }.forEach(audio.delete)
                }
            }
            .overlay {
                if audio.recordings.isEmpty {
                    Text("이 노트에는 녹음이 없습니다")
                        .foregroundColor(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if transcriber.busy != nil {
                    Text("\(transcriber.status) · 끝날 때까지 이 화면을 열어 두세요")
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

    private func transcribe(_ url: URL, language: String?) {
        transcriber.transcribe(url, language: language) { text in
            onTranscript(text)
            dismiss()
        }
    }
}
