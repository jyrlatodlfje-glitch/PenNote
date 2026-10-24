import SwiftUI

/// 애플워치 PenNote: 워치 마이크로 음성 메모. 말하는 대로 아이폰이 바꾼 글자가 보이고,
/// 멈추면 소리 파일과 함께 아이폰 PenNote에 새 노트("MM-dd HH:mm 워치 메모")로 저장된다.
@main
struct PenNoteWatchApp: App {
    @StateObject private var recorder = WatchRecorder()

    var body: some Scene {
        WindowGroup {
            WatchMemoView()
                .environmentObject(recorder)
                // 시계화면 바로가기(컴플리케이션)로 열면 바로 받아 적기를 시작한다.
                .onOpenURL { url in
                    if url.host == "record" {
                        recorder.start()
                    }
                }
        }
    }
}

struct WatchMemoView: View {
    @EnvironmentObject private var recorder: WatchRecorder

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 8) {
                    Button {
                        recorder.toggle()
                    } label: {
                        Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                            .font(.title)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .tint(recorder.isRecording ? .red : .blue)

                    // 평소 한국어(NFPA 같은 영어 낱말도 받아 적음), 외국 분과 대화할 때 English
                    Button {
                        recorder.toggleLanguage()
                    } label: {
                        Label(VoiceLink.languageName(recorder.locale), systemImage: "globe")
                            .font(.caption)
                    }

                    if recorder.isRecording {
                        Text(recorder.started, style: .timer)
                            .font(.caption)
                            .monospacedDigit()
                        if !recorder.phoneReachable {
                            Text("아이폰과 연결되지 않아 녹음만 합니다. 끝나면 아이폰이 글자로 바꿉니다.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !recorder.text.isEmpty {
                        Text(recorder.text)
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if recorder.isRecording {
                        Text("말씀하시면 여기에 글자가 나옵니다.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    if let message = recorder.message {
                        Text(message)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 4)
            }
            .onChange(of: recorder.text) { _ in
                proxy.scrollTo("end", anchor: .bottom)
            }
        }
    }
}
