import Foundation
import CoreLocation

/// One bound "electronic fence" region: a circle on the map, bound to ONE
/// saved card (a card may be bound to many regions). Entering the region
/// makes the app push the bound card into the Chameleon's active slot — walk
/// into company, company card is ready.
struct GeoRegion: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var cardId: UUID
    var centerLatitude: Double
    var centerLongitude: Double
    /// Circle radius in meters (0–500, stepped by 50; 0 = fence off).
    var radius: Double
    /// Per-region master switch in the manage list.
    var isEnabled: Bool = true

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    /// CoreLocation monitoring is unreliable below its ~100 m floor; the true
    /// radius is still honoured by the app-side inside-probe.
    var monitoringRadius: Double {
        max(100, radius)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cardId, centerLatitude, centerLongitude, radius, isEnabled
    }

    init(id: UUID = UUID(), name: String, cardId: UUID,
         centerLatitude: Double, centerLongitude: Double,
         radius: Double, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.cardId = cardId
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.radius = radius
        self.isEnabled = isEnabled
    }

    // Old files have no `isEnabled` — default it to true.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        cardId = try c.decode(UUID.self, forKey: .cardId)
        centerLatitude = try c.decode(Double.self, forKey: .centerLatitude)
        centerLongitude = try c.decode(Double.self, forKey: .centerLongitude)
        radius = try c.decode(Double.self, forKey: .radius)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

/// JSON-file-backed store for fence regions (Documents/geo-regions.json).
enum GeoRegionStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("geo-regions.json")
    }

    static func load() -> [GeoRegion] {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([GeoRegion].self, from: data) else { return [] }
        return list
    }

    static func save(_ regions: [GeoRegion]) {
        guard let data = try? JSONEncoder().encode(regions) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func add(_ region: GeoRegion) {
        var list = load()
        list.append(region)
        save(list)
    }

    static func delete(_ region: GeoRegion) {
        save(load().filter { $0.id != region.id })
    }

    /// Replace one region in place (edits keep the same id).
    static func update(_ region: GeoRegion) {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.id == region.id }) else { return }
        list[idx] = region
        save(list)
    }

    static func setEnabled(_ id: UUID, _ enabled: Bool) {
        var list = load()
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].isEnabled = enabled
        save(list)
    }
}

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
