import Foundation

/// Auto slot-polling preferences: instead of pushing cards into one slot,
/// the app rotates the device's ACTIVE SLOT across its *enabled* card slots
/// at a fast gap (50–500 ms), so a door reader picks up whichever slot
/// matches.
enum AutoPoll {
    /// When the switch is ON: .smart rests and only rotates slots while a
    /// reader is detected working on the card; .continuous never rests.
    enum Mode: String { case smart, continuous }

    static let enabledKey = "autoCycleEnabled"
    static let modeKey = "autoPollMode"
    /// New key: old "autoCycleInterval" stored seconds (3/5/10/30); reusing it
    /// would read a stale 5 as 5 ms. Milliseconds live under their own key.
    static let intervalKey = "autoPollIntervalMs"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var mode: Mode {
        get { Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .smart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Gap between slot switches, in milliseconds (slider range 50–500).
    static var intervalMs: Int {
        let i = UserDefaults.standard.integer(forKey: intervalKey)
        return (50...500).contains(i) ? i : 100
    }

    /// Full sweeps over the enabled slots before giving up; 0 = unlimited.
    /// Shared by the phone-side poller and pushed to device-side firmware (SET 4045).
    /// Default 3. object(forKey:) check keeps an explicit 0 ("unlimited") distinct
    /// from "never set" — integer(forKey:) answers 0 for both.
    static let lapsKey = "autoPollMaxLaps"
    static var maxLaps: Int {
        get {
            let d = UserDefaults.standard
            guard d.object(forKey: lapsKey) != nil else { return 3 }
            let v = d.integer(forKey: lapsKey)
            return (0...10).contains(v) ? v : 3
        }
        set { UserDefaults.standard.set(newValue, forKey: lapsKey) }
    }
}
