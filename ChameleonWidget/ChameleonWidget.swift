import WidgetKit
import SwiftUI

// Slot quick-switch widget: 8 tappable slots. Each slot is a Link that
// opens the app via URL scheme (chameleonultragf://activate/N) — the app
// then activates that slot over its existing BLE connection.

struct SlotsEntry: TimelineEntry {
    let date: Date
}

struct SlotsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SlotsEntry { SlotsEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (SlotsEntry) -> Void) {
        completion(SlotsEntry(date: Date()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SlotsEntry>) -> Void) {
        completion(Timeline(entries: [SlotsEntry(date: Date())], policy: .never))
    }
}

struct SlotButton: View {
    let slot: Int

    var body: some View {
        Link(destination: URL(string: "chameleonultragf://activate/\(slot)")!) {
            VStack(spacing: 3) {
                Text("\(slot)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.green.opacity(0.8))
                    .frame(width: 12, height: 3)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan.opacity(0.8))
                    .frame(width: 12, height: 3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct SlotsGridView: View {
    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { col in
                        SlotButton(slot: row * 4 + col)
                    }
                }
            }
        }
        .padding(2)
    }
}

struct SlotsEntryView: View {
    var entry: SlotsEntry

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "sensor.tag.rfid.fill")
                    .foregroundStyle(.green)
                Text("Chameleon")
                    .font(.caption.weight(.semibold))
                Spacer()
            }
            SlotsGridView()
            Spacer(minLength: 0)
        }
        .padding(4)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

struct SlotSwitcherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SlotSwitcher", provider: SlotsProvider()) { entry in
            SlotsEntryView(entry: entry)
        }
        .configurationDisplayName("Slot quick switch")
        .description("Tap a slot to open the app and activate it.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct ChameleonWidgetBundle: WidgetBundle {
    var body: some Widget {
        SlotSwitcherWidget()
        ChameleonLiveActivity()
    }
}
