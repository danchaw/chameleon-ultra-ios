import Foundation
import ActivityKit

/// Single shared definition of the Live Activity contract. This lives in the
/// SharedKit package so the app and the widget extension reference the SAME
/// type from the SAME module — ActivityKit matches activities across
/// processes by the fully qualified type name, and duplicated per-target
/// copies never match.
public struct ChameleonActivityAttributes: ActivityAttributes {
    /// Static context — set when the activity starts.
    public var deviceName: String
    public var deviceTypeName: String

    /// Dynamic state — updated on every battery/slot/alias change.
    public struct ContentState: Codable, Hashable {
        /// kept in state (not the immutable attributes) so renames show up live
        public var deviceName: String
        public var connected: Bool
        public var batteryPercent: Int?
        public var batteryMillivolts: Int?
        public var activeSlot: Int
        public var slotName: String
        public var updatedAt: Date

        public init(deviceName: String = "",
                    connected: Bool,
                    batteryPercent: Int?,
                    batteryMillivolts: Int?,
                    activeSlot: Int,
                    slotName: String = "",
                    updatedAt: Date = Date()) {
            self.deviceName = deviceName
            self.connected = connected
            self.batteryPercent = batteryPercent
            self.batteryMillivolts = batteryMillivolts
            self.activeSlot = activeSlot
            self.slotName = slotName
            self.updatedAt = updatedAt
        }

        /// "N · 名称" for a slot, number always preserved.
        public var activeSlotLabel: String {
            slotName.isEmpty ? "\(activeSlot)" : "\(activeSlot) · \(slotName)"
        }

        public var voltageText: String? {
            guard let mv = batteryMillivolts, mv > 0 else { return nil }
            return String(format: "%.2f V", Double(mv) / 1000)
        }
    }

    public init(deviceName: String, deviceTypeName: String) {
        self.deviceName = deviceName
        self.deviceTypeName = deviceTypeName
    }
}
