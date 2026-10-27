import Foundation
import WidgetKit

/// Minimal device-state snapshot shared with the widget extensions over the
/// App Group container. The app writes it whenever connection state, battery
/// or slots change; the widgets read it in their timeline providers.
/// NOTE: the widget target compiles its own mirror of these keys
/// (ChameleonWidget/DeviceStatusWidget.swift) — keep the two in sync.
/// If the App Group entitlement is stripped during re-signing (e.g. free
/// Apple ID profiles), the suite simply never shares and widgets show the
/// offline placeholder — nothing crashes.
enum DeviceSnapshot {
    static let suiteName = "group.com.chameleonultragui.ios"

    static let connectedKey = "device.connected"
    static let batteryPercentKey = "device.batteryPercent"
    static let batteryMillivoltsKey = "device.batteryMillivolts"
    static let deviceTypeKey = "device.deviceType"
    static let activeSlotKey = "device.activeSlot"
    static let slotNameKey = "device.slotName"
    static let updatedAtKey = "device.updatedAt"

    static var shared: UserDefaults? { UserDefaults(suiteName: suiteName) }

    struct State {
        var connected = false
        var batteryPercent: Int?
        var batteryMillivolts: Int?
        var deviceTypeName = "Ultra"
        var activeSlot = 0
        var slotName = ""
    }

    static func publish(_ state: State) {
        guard let defaults = shared else { return }
        defaults.set(state.connected, forKey: connectedKey)
        defaults.set(state.batteryPercent, forKey: batteryPercentKey)
        defaults.set(state.batteryMillivolts, forKey: batteryMillivoltsKey)
        defaults.set(state.deviceTypeName, forKey: deviceTypeKey)
        defaults.set(state.activeSlot, forKey: activeSlotKey)
        defaults.set(state.slotName, forKey: slotNameKey)
        defaults.set(Date().timeIntervalSince1970, forKey: updatedAtKey)
        WidgetCenter.shared.reloadTimelines(ofKind: "DeviceStatus")
    }
}
