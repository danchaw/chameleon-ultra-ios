import Foundation
import WidgetKit

/// Device snapshot shared between app + widgets. Kept as the App Group
/// fallback channel (works when the sideload tool preserves the
/// application-groups entitlement). The Live Activity carries the same data
/// independently of entitlements.

public struct DeviceSnapshotEntry: Codable, Equatable {
    public var address = ""
    public var name = ""
    public var connected = false
    public var batteryPercent: Int?
    public var batteryMillivolts: Int?
    public var deviceTypeName = "Ultra"
    public var activeSlot = 0
    public var slotName = ""
    /// User aliases for slots 0...7 ("" when unset) — shown in the widgets
    /// next to the (never hidden) slot numbers.
    public var slotAliases: [String] = Array(repeating: "", count: 8)
    public var updatedAt = Date()

    public init() {}
}

/// User-renamed device registry (app-local canonical store).
public struct DeviceRecord: Codable, Equatable {
    public var address: String
    public var nickname: String = ""
    public var defaultName: String = ""
    public var displayName: String { nickname.isEmpty ? defaultName : nickname }

    public init(address: String, nickname: String = "", defaultName: String = "") {
        self.address = address
        self.nickname = nickname
        self.defaultName = defaultName
    }
}

public enum DeviceSnapshot {
    public static let suiteName = "group.com.chameleonultragui.ios"
    public static let devicesKey = "device.snapshots.v1"
    public static let maxDevices = 16

    public static var shared: UserDefaults? { UserDefaults(suiteName: suiteName) }

    public static func upsert(_ entry: DeviceSnapshotEntry) {
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
        WidgetCenter.shared.reloadTimelines(ofKind: "SlotSwitcher")
    }

    public static func readDevices() -> [DeviceSnapshotEntry] {
        guard let data = shared?.data(forKey: devicesKey),
              let list = try? JSONDecoder().decode([DeviceSnapshotEntry].self, from: data) else { return [] }
        return list
    }
}
