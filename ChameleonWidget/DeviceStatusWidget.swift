import WidgetKit
import SwiftUI
import AppIntents

// Device status widget: battery, voltage and active slot (with alias) of a
// Chameleon, read from the App Group snapshot the app publishes on every
// state change. Each widget instance can be configured (long-press the
// widget → Edit Widget) to pin one of the user's named devices.
// The App Group codec mirrors ChameleonUltra/SharedDeviceSnapshot.swift —
// keep the two in sync.

// MARK: - Widget-side mirror of the shared snapshot

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

    var slotDisplay: String {
        let alias = activeSlot >= 0 && activeSlot < slotAliases.count ? slotAliases[activeSlot] : ""
        let label = !alias.isEmpty ? alias : slotName
        return label.isEmpty ? "\(activeSlot)" : "\(activeSlot) · \(label)"
    }
}

struct WidgetDeviceRecord: Codable {
    var address = ""
    var nickname = ""
    var defaultName = ""
    var displayName: String { nickname.isEmpty ? defaultName : nickname }
}

enum WidgetStore {
    static let suiteName = "group.com.chameleonultragui.ios"
    static let devicesKey = "device.snapshots.v1"
    static let registryKey = "device.registry.v1"

    static func snapshots() -> [WidgetDeviceSnapshot] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: devicesKey),
              let list = try? JSONDecoder().decode([WidgetDeviceSnapshot].self, from: data) else { return [] }
        return list
    }

    static func registry() -> [WidgetDeviceRecord] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: registryKey),
              let list = try? JSONDecoder().decode([WidgetDeviceRecord].self, from: data) else { return [] }
        return list
    }

    /// Devices listed for the configuration picker: everything the user has
    /// named or connected, most recently used first.
    static func knownDevices() -> [(address: String, title: String)] {
        var byAddress: [String: String] = [:]
        for rec in registry() where !rec.address.isEmpty {
            byAddress[rec.address] = rec.displayName
        }
        for snap in snapshots() where !snap.address.isEmpty {
            if let reg = byAddress[snap.address], !reg.isEmpty {
                byAddress[snap.address] = reg
            } else {
                byAddress[snap.address] = snap.name.isEmpty ? "Chameleon" : snap.name
            }
        }
        let order = snapshots().map { $0.address }   // newest first
        return byAddress
            .sorted { a, b in
                let ia = order.firstIndex(of: a.key) ?? .max
                let ib = order.firstIndex(of: b.key) ?? .max
                return ia < ib
            }
            .map { (address: $0.key, title: $0.value.isEmpty ? $0.key : $0.value) }
    }
}

// MARK: - AppIntent configuration (device picker)

struct ChameleonDeviceEntity: AppEntity {
    let id: String
    let title: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chameleon device")
    static let defaultQuery = ChameleonDeviceQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct ChameleonDeviceQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ChameleonDeviceEntity] {
        let known = WidgetStore.knownDevices()
        return identifiers.compactMap { id in
            known.first { $0.address == id }.map { ChameleonDeviceEntity(id: $0.address, title: $0.title) }
        }
    }

    func suggestedEntities() async throws -> [ChameleonDeviceEntity] {
        WidgetStore.knownDevices().map { ChameleonDeviceEntity(id: $0.address, title: $0.title) }
    }
}

struct DeviceStatusIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Chameleon device"
    static let description = IntentDescription("Pick which Chameleon this widget shows.")

    @Parameter(title: "Device")
    var device: ChameleonDeviceEntity?

    init() {}
}

// MARK: - Timeline

struct DeviceStatusEntry: TimelineEntry {
    let date: Date
    var info: WidgetDeviceSnapshot?
    var title: String
}

struct DeviceStatusProvider: AppIntentTimelineProvider {
    typealias Entry = DeviceStatusEntry
    typealias Intent = DeviceStatusIntent

    func placeholder(in context: Context) -> DeviceStatusEntry {
        var snap = WidgetDeviceSnapshot()
        snap.connected = true; snap.batteryPercent = 78; snap.batteryMillivolts = 3910
        snap.activeSlot = 2; snap.slotAliases[2] = "Office"
        return DeviceStatusEntry(date: Date(), info: snap, title: "Chameleon Ultra")
    }

    private func resolve(for configuration: DeviceStatusIntent) -> DeviceStatusEntry {
        let snaps = WidgetStore.snapshots()
        let info: WidgetDeviceSnapshot?
        let title: String
        if let pinned = configuration.device {
            info = snaps.first { $0.address == pinned.id }
            title = pinned.title
        } else {
            info = snaps.first
            if let info {
                title = WidgetStore.knownDevices().first { $0.address == info.address }?.title
                    ?? (info.name.isEmpty ? "Chameleon" : info.name)
            } else {
                title = "Chameleon"
            }
        }
        return DeviceStatusEntry(date: Date(), info: info, title: title)
    }

    func snapshot(for configuration: DeviceStatusIntent, in context: Context, completion: @escaping (DeviceStatusEntry) -> Void) {
        completion(resolve(for: configuration))
    }

    func timeline(for configuration: DeviceStatusIntent, in context: Context, completion: @escaping (Timeline<DeviceStatusEntry>) -> Void) {
        // Battery is polled every 30 s while connected; the app also reloads
        // this timeline explicitly on connect / disconnect / slot & rename.
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [resolve(for: configuration)], policy: .after(next)))
    }
}

// MARK: - View

struct DeviceStatusEntryView: View {
    var entry: DeviceStatusEntry

    private var batterySymbol: String {
        guard let p = entry.info?.batteryPercent else { return "battery.0" }
        switch p {
        case ..<21: return "battery.25"
        case ..<51: return "battery.50"
        case ..<81: return "battery.75"
        default: return "battery.100"
        }
    }

    private var detailLine: String {
        guard let info = entry.info else { return "Never connected" }
        if info.connected {
            var line = "Slot \(info.slotDisplay)"
            if let mv = info.batteryMillivolts {
                line += String(format: " · %.2f V", Double(mv) / 1000)
            }
            return line
        }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return "Offline · \(f.string(from: info.updatedAt))"
    }

    var body: some View {
        Link(destination: URL(string: "chameleonultra://")!) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "sensor.tag.rfid.fill")
                        .font(.caption2)
                        .foregroundStyle(entry.info?.connected == true ? Color.green : Color.secondary)
                    Text(entry.title)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: batterySymbol)
                        .foregroundStyle(entry.info?.connected == true ? Color.primary : Color.secondary)
                    Text(entry.info?.batteryPercent.map { "\($0)%" } ?? "—")
                        .font(.title2.bold())
                        .monospacedDigit()
                        .foregroundStyle(entry.info?.connected == true ? Color.primary : Color.secondary)
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
        AppIntentConfiguration(kind: "DeviceStatus", intent: DeviceStatusIntent.self, provider: DeviceStatusProvider()) { entry in
            DeviceStatusEntryView(entry: entry)
        }
        .configurationDisplayName("Device status")
        .description("Battery, voltage and active slot of a Chameleon. Pick the device in the widget editor.")
        .supportedFamilies([.systemSmall])
    }
}
