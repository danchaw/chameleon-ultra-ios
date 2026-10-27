import WidgetKit
import SwiftUI
import ActivityKit

// Shared widget-side data plumbing: the App Group snapshot reader (used as a
// fallback for slot aliases) and the Live Activity definition + UI.
//
// ChameleonActivityAttributes below MUST stay byte-for-byte identical to
// ChameleonUltra/ChameleonActivityAttributes.swift — ActivityKit matches the
// two copies by name. It also carries the slot alias array, which is how the
// SlotSwitcher widget gets live aliases even when re-signing strips the App
// Group entitlement (ActivityKit needs no shared container).

// MARK: - App Group snapshot fallback (codec mirrors SharedDeviceSnapshot.swift)

struct WidgetDeviceSnapshot: Codable {
    var address = ""
    var name = ""
    var connected = false
    var batteryPercent: Int?
    var batteryMillivolts: Int?
    var deviceTypeName = "Ultra"
    var activeSlot = 0
    var slotName = ""
    var slotAliases: [String] = Array(repeating: "", count: 8)
    var updatedAt = Date()
}

enum WidgetStore {
    static let suiteName = "group.com.chameleonultragui.ios"
    static let devicesKey = "device.snapshots.v1"

    /// Newest snapshot first (the app sorts on write).
    static func snapshots() -> [WidgetDeviceSnapshot] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: devicesKey),
              let list = try? JSONDecoder().decode([WidgetDeviceSnapshot].self, from: data) else { return [] }
        return list
    }
}

// MARK: - Live Activity attributes (copy of the app-side definition)

struct ChameleonActivityAttributes: ActivityAttributes {
    var deviceName: String = ""
    var deviceTypeName: String = ""

    struct ContentState: Codable, Hashable {
        var deviceName: String
        var connected: Bool
        var batteryPercent: Int?
        var batteryMillivolts: Int?
        var activeSlot: Int
        var slotName: String
        var slotAliases: [String]
        var updatedAt: Date

        static func slotLabel(aliases: [String], slot: Int, fallback: String = "") -> String {
            let alias = (slot >= 0 && slot < aliases.count && !aliases[slot].isEmpty)
                ? aliases[slot] : fallback
            return alias.isEmpty ? "\(slot)" : "\(slot) · \(alias)"
        }

        var activeSlotLabel: String {
            Self.slotLabel(aliases: slotAliases, slot: activeSlot, fallback: slotName)
        }

        var voltageText: String? {
            guard let mv = batteryMillivolts else { return nil }
            return String(format: "%.2f V", Double(mv) / 1000)
        }
    }
}

// MARK: - Lock screen card

struct ChameleonLiveActivityView: View {
    let state: ChameleonActivityAttributes.ContentState
    let attributes: ChameleonActivityAttributes

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.connected ? "sensor.tag.rfid.fill" : "sensor.tag.radiowaves.forward")
                .foregroundStyle(state.connected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.deviceName.isEmpty ? attributes.deviceName : state.deviceName) \(attributes.deviceTypeName)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(state.connected ? "Slot \(state.activeSlotLabel)"
                                     : "Offline · \(Self.timeFormatter.string(from: state.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let percent = state.batteryPercent {
                HStack(spacing: 4) {
                    Image(systemName: Self.batterySymbol(percent))
                    Text("\(percent)%").font(.body.bold()).monospacedDigit()
                }
                .foregroundStyle(state.connected ? Color.primary : Color.secondary)
            } else {
                Text("—").font(.body.bold())
            }
            if state.connected, let voltage = state.voltageText {
                Text(voltage)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .activityBackgroundTint(.clear)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    static func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ..<21: return "battery.25"
        case ..<51: return "battery.50"
        case ..<81: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Dynamic Island

struct ChameleonIslandCompactLeading: View {
    let state: ChameleonActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: ChameleonLiveActivityView.batterySymbol(state.batteryPercent ?? -1))
                .foregroundStyle(state.connected ? Color.green : Color.secondary)
            if let percent = state.batteryPercent {
                Text("\(percent)%").font(.caption2.bold()).monospacedDigit()
            }
        }
    }
}

struct ChameleonIslandCompactTrailing: View {
    let state: ChameleonActivityAttributes.ContentState

    var body: some View {
        Text("S\(state.activeSlot)")
            .font(.caption2.bold())
            .monospacedDigit()
    }
}

struct ChameleonIslandExpanded: View {
    let state: ChameleonActivityAttributes.ContentState
    let attributes: ChameleonActivityAttributes

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.connected ? "sensor.tag.rfid.fill" : "sensor.tag.radiowaves.forward")
                .foregroundStyle(state.connected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(state.deviceName.isEmpty ? attributes.deviceName : state.deviceName) \(attributes.deviceTypeName)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(state.connected ? "Slot \(state.activeSlotLabel)" : "Offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let percent = state.batteryPercent {
                Text("\(percent)%").font(.title3.bold()).monospacedDigit()
            } else {
                Text("—").font(.title3.bold())
            }
            if state.connected, let voltage = state.voltageText {
                Text(voltage).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }
}

struct ChameleonLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChameleonActivityAttributes.self) { context in
            ChameleonLiveActivityView(state: context.state, attributes: context.attributes)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ChameleonIslandExpanded(state: context.state, attributes: context.attributes)
                }
            } compactLeading: {
                ChameleonIslandCompactLeading(state: context.state)
            } compactTrailing: {
                ChameleonIslandCompactTrailing(state: context.state)
            } minimal: {
                Image(systemName: "sensor.tag.rfid.fill")
                    .foregroundStyle(context.state.connected ? Color.green : Color.secondary)
            }
            .keylineTint(context.state.connected ? Color.green : Color.secondary)
        }
    }
}
