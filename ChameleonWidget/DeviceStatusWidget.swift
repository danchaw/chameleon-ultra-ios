import WidgetKit
import SwiftUI

// Device status widget: battery, voltage and active slot of the Chameleon,
// read from the App Group snapshot the app publishes on every state change
// (see ChameleonUltra/SharedDeviceSnapshot.swift — keys are mirrored here).

struct DeviceStatusEntry: TimelineEntry {
    let date: Date
    var connected = false
    var batteryPercent: Int?
    var batteryMillivolts: Int?
    var deviceTypeName = "Ultra"
    var activeSlot = 0
    var slotName = ""
    var lastSeen: Date?
}

struct DeviceStatusProvider: TimelineProvider {
    static let suiteName = "group.com.chameleonultragui.ios"

    private func read() -> DeviceStatusEntry {
        let defaults = UserDefaults(suiteName: Self.suiteName)
        var entry = DeviceStatusEntry(date: Date())
        entry.connected = defaults?.bool(forKey: "device.connected") ?? false
        if defaults?.object(forKey: "device.batteryPercent") != nil {
            entry.batteryPercent = defaults?.integer(forKey: "device.batteryPercent")
        }
        if defaults?.object(forKey: "device.batteryMillivolts") != nil {
            entry.batteryMillivolts = defaults?.integer(forKey: "device.batteryMillivolts")
        }
        entry.deviceTypeName = defaults?.string(forKey: "device.deviceType") ?? "Ultra"
        entry.activeSlot = defaults?.integer(forKey: "device.activeSlot") ?? 0
        entry.slotName = defaults?.string(forKey: "device.slotName") ?? ""
        let ts = defaults?.double(forKey: "device.updatedAt") ?? 0
        if ts > 0 { entry.lastSeen = Date(timeIntervalSince1970: ts) }
        return entry
    }

    func placeholder(in context: Context) -> DeviceStatusEntry {
        var e = DeviceStatusEntry(date: Date())
        e.connected = true; e.batteryPercent = 78; e.batteryMillivolts = 3910; e.activeSlot = 2; e.slotName = "Office"
        return e
    }

    func getSnapshot(in context: Context, completion: @escaping (DeviceStatusEntry) -> Void) {
        completion(read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DeviceStatusEntry>) -> Void) {
        // Battery is polled every 30 s while connected; the app also reloads
        // this timeline explicitly on connect / disconnect / slot switches.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [read()], policy: .after(next)))
    }
}

struct DeviceStatusEntryView: View {
    var entry: DeviceStatusEntry

    private var batterySymbol: String {
        guard let p = entry.batteryPercent else { return "battery.0" }
        switch p {
        case ..<21: return "battery.25"
        case ..<51: return "battery.50"
        case ..<81: return "battery.75"
        default: return "battery.100"
        }
    }

    private var detailLine: String {
        if entry.connected {
            var line = "Slot \(entry.activeSlot)"
            if !entry.slotName.isEmpty { line += " · \(entry.slotName)" }
            if let mv = entry.batteryMillivolts {
                line += String(format: " · %.2f V", Double(mv) / 1000)
            }
            return line
        }
        if let lastSeen = entry.lastSeen {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            return "Offline · \(f.string(from: lastSeen))"
        }
        return "Offline"
    }

    var body: some View {
        Link(destination: URL(string: "chameleonultra://")!) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "sensor.tag.rfid.fill")
                        .font(.caption2)
                        .foregroundStyle(entry.connected ? Color.green : Color.secondary)
                    Text("Chameleon \(entry.deviceTypeName)")
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: batterySymbol)
                        .foregroundStyle(entry.connected ? Color.primary : Color.secondary)
                    Text(entry.batteryPercent.map { "\($0)%" } ?? "—")
                        .font(.title2.bold())
                        .monospacedDigit()
                        .foregroundStyle(entry.connected ? Color.primary : Color.secondary)
                }
                Text(detailLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

struct DeviceStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "DeviceStatus", provider: DeviceStatusProvider()) { entry in
            DeviceStatusEntryView(entry: entry)
        }
        .configurationDisplayName("Device status")
        .description("Battery, voltage and active slot of your Chameleon.")
        .supportedFamilies([.systemSmall])
    }
}
