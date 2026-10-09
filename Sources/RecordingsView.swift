import SwiftUI

struct RecordingsView: View {
    @ObservedObject var audio: AudioRecorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(audio.recordings, id: \.self) { url in
                    HStack {
                        Button {
                            audio.togglePlayback(url)
                        } label: {
                            Label(url.deletingPathExtension().lastPathComponent,
                                  systemImage: audio.playing == url ? "stop.circle.fill" : "play.circle")
                        }
                        .disabled(audio.isRecording)
                        Spacer()
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
            .navigationTitle("녹음")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("닫기") { dismiss() }
                }
            }
        }
    }
}
