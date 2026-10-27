import WidgetKit
import SwiftUI

// Slot quick-switch widget: 8 tappable slots. Each slot is a Link that
// opens the app via URL scheme (chameleonultra://activate/N) — the app
// then activates that slot over its existing BLE connection.

struct SlotsEntry: TimelineEntry {
    let date: Date
    /// User aliases for slots 0...7 of the most recently connected device
    /// ("" when unset) — read from the App Group snapshot; slot numbers are
    /// always shown, the alias only adds a caption.
    var aliases: [String] = Array(repeating: "", count: 8)
}

struct SlotsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SlotsEntry { SlotsEntry(date: Date()) }
    func getSnapshot(in context: Context, completion: @escaping (SlotsEntry) -> Void) {
        completion(read())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SlotsEntry>) -> Void) {
        // reloaded explicitly by the app whenever aliases/connection change
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [read()], policy: .after(next)))
    }

    private func read() -> SlotsEntry {
        // newest snapshot first — aliases belong to the last device used
        let snaps = WidgetStore.snapshots().first
        var entry = SlotsEntry(date: Date())
        if let aliases = snaps?.slotAliases, aliases.count == 8 {
            entry.aliases = aliases
        }
        return entry
    }
}

struct SlotButton: View {
    let slot: Int
    let alias: String

    var body: some View {
        Link(destination: URL(string: "chameleonultra://activate/\(slot)")!) {
            VStack(spacing: 2) {
                Text("\(slot)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if !alias.isEmpty {
                    Text(alias)
                        .font(.system(size: 8))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.green.opacity(0.8))
                        .frame(width: 12, height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.cyan.opacity(0.8))
                        .frame(width: 12, height: 3)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct SlotsGridView: View {
    let aliases: [String]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(0..<4, id: \.self) { col in
                        let slot = row * 4 + col
                        SlotButton(slot: slot, alias: slot < aliases.count ? aliases[slot] : "")
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
            SlotsGridView(aliases: entry.aliases)
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
        DeviceStatusWidget()
    }
}
