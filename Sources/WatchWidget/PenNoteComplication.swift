import SwiftUI
import WidgetKit

/// 시계화면 바로가기(컴플리케이션): 누르면 워치 PenNote가 열리며 바로 받아 적기를 시작한다.
struct MemoEntry: TimelineEntry {
    let date: Date
}

struct MemoProvider: TimelineProvider {
    func placeholder(in context: Context) -> MemoEntry {
        MemoEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (MemoEntry) -> Void) {
        completion(MemoEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MemoEntry>) -> Void) {
        completion(Timeline(entries: [MemoEntry(date: Date())], policy: .never))
    }
}

struct MemoComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("PenNote 메모", systemImage: "mic.fill")
        case .accessoryRectangular:
            HStack {
                Image(systemName: "mic.fill")
                Text("PenNote 메모")
            }
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "mic.fill")
                    .font(.title3)
            }
        }
    }
}

@main
struct PenNoteComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PenNoteMemo", provider: MemoProvider()) { _ in
            MemoComplicationView()
                .widgetURL(URL(string: "pennote://record"))
                .containerBackground(Color.clear, for: .widget)
        }
        .configurationDisplayName("PenNote 음성 메모")
        .description("누르면 바로 받아 적기를 시작합니다.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}
