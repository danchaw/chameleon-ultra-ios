import WidgetKit
import SwiftUI
import ActivityKit
import SharedKit

// Live Activity UI (lock screen card + Dynamic Island). The attributes type
// comes from SharedKit — the SAME module the app uses, so ActivityKit can
// match the activity across the two processes.

// MARK: - Lock screen card

struct ChameleonLiveActivityView: View {
    let state: ChameleonActivityAttributes.ContentState

    private var deviceTitle: String {
        let name = state.deviceName.isEmpty ? "Chameleon" : state.deviceName
        return name
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.connected ? "sensor.tag.rfid.fill" : "sensor.tag.radiowaves.forward")
                .foregroundStyle(state.connected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(state.connected ? "Slot \(state.activeSlotLabel)"
                                     : "Offline · \(Self.timeFormatter.string(from: state.updatedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
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
        Text("S\(state.activeSlot)").font(.caption2.bold()).monospacedDigit()
    }
}

struct ChameleonIslandExpanded: View {
    let state: ChameleonActivityAttributes.ContentState

    private var deviceTitle: String {
        state.deviceName.isEmpty ? "Chameleon" : state.deviceName
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: state.connected ? "sensor.tag.rfid.fill" : "sensor.tag.radiowaves.forward")
                .foregroundStyle(state.connected ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(deviceTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(state.connected ? "Slot \(state.activeSlotLabel)" : "Offline")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
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
            ChameleonLiveActivityView(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    ChameleonIslandExpanded(state: context.state)
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
