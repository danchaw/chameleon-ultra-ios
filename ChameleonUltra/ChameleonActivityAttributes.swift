import Foundation
import ActivityKit

/// Live Activity shared state. Declared identically in BOTH targets
/// (app + widget extension) — the copies must stay byte-for-byte in sync
/// (see ChameleonWidget/LiveActivityWidget.swift). ActivityKit carries this
/// state across processes WITHOUT an App Group, which is why the widgets can
/// show live battery/slot/alias data even when re-signing strips entitlements.
struct ChameleonActivityAttributes: ActivityAttributes {
    /// Static context — stored properties, set when the activity starts.
    var deviceName: String = ""
    var deviceTypeName: String = ""

    /// Dynamic state — updated on every battery/slot/alias change.
    struct ContentState: Codable, Hashable {
        /// kept in state (not the immutable attributes) so renames show up live
        var deviceName: String
        var connected: Bool
        var batteryPercent: Int?
        var batteryMillivolts: Int?
        var activeSlot: Int
        var slotName: String
        var slotAliases: [String]
        var updatedAt: Date

        /// "N · 别名" for a slot, number always preserved.
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
