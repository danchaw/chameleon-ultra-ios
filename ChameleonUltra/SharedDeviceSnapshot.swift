import Foundation
import WidgetKit

/// Per-device state snapshot shared with the widget extension over the App
/// Group container, keyed by BLE address. The app upserts the connected (or
/// just-disconnected) device on every relevant state change; the widget reads
/// all known devices so each widget instance can pin one of them.
/// NOTE: the widget target compiles its own mirror of this codec
/// (ChameleonWidget/DeviceStatusWidget.swift) — keep the two in sync.
/// If the App Group entitlement is stripped during re-signing (free Apple ID
/// profiles), `UserDefaults(suiteName:)` silently never shares: renames still
/// persist in standard defaults, widgets just show the offline placeholder.

// MARK: - Codable payloads

struct DeviceSnapshotEntry: Codable, Equatable {
    var address = ""            // stable key: BLE address, fallback advertised name
    var name = ""               // user nickname when set, else advertised name
    var connected = false
    var batteryPercent: Int?
    var batteryMillivolts: Int?
    var deviceTypeName = "Ultra"
    var activeSlot = 0
    var slotName = ""
    /// User aliases for slots 0...7 ("" when unset) — shown in the widgets
    /// next to the (never hidden) slot numbers.
    var slotAliases: [String] = Array(repeating: "", count: 8)
    var updatedAt = Date()
}

/// User-renamed device registry (canonical copy lives in standard defaults,
/// mirrored here so the widget's configuration picker can list it).
struct DeviceRecord: Codable, Equatable {
    var address: String
    var nickname: String = ""
    var defaultName: String = ""
    var displayName: String { nickname.isEmpty ? defaultName : nickname }
}

// MARK: - App Group store

enum DeviceSnapshot {
    static let suiteName = "group.com.chameleonultragui.ios"
    static let devicesKey = "device.snapshots.v1"
    static let registryKey = "device.registry.v1"
    static let maxDevices = 16

    static var shared: UserDefaults? { UserDefaults(suiteName: suiteName) }

    static func upsert(_ entry: DeviceSnapshotEntry) {
        guard let defaults = shared else { return }
        var list = readDevices()
        if let idx = list.firstIndex(where: { $0.address == entry.address }) {
            list[idx] = entry
        } else {
            list.append(entry)
        }
        list.sort { $0.updatedAt > $1.updatedAt }
        list = Array(list.prefix(maxDevices))
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: devicesKey)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "DeviceStatus")
        WidgetCenter.shared.reloadTimelines(ofKind: "SlotSwitcher")
    }

    static func readDevices() -> [DeviceSnapshotEntry] {
        guard let data = shared?.data(forKey: devicesKey),
              let list = try? JSONDecoder().decode([DeviceSnapshotEntry].self, from: data) else { return [] }
        return list
    }

    static func publishRegistry(_ records: [DeviceRecord]) {
        guard let defaults = shared,
              let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: registryKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "DeviceStatus")
        WidgetCenter.shared.reloadTimelines(ofKind: "SlotSwitcher")
    }

    static func readRegistry() -> [DeviceRecord] {
        guard let data = shared?.data(forKey: registryKey),
              let list = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return [] }
        return list
    }
}
