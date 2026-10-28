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
    /// Circle radius in meters.
    var radius: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
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
}

/// Auto card-cycling preferences: the app pushes every saved card into the
/// active slot one after another at a fixed interval, so whatever reader you
/// tap finds a matching card without manual selection.
enum AutoPoll {
    static let enabledKey = "autoCycleEnabled"
    static let intervalKey = "autoCycleInterval"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Per-card dwell time in seconds (BLE write takes ~1-2 s).
    static var intervalSeconds: Int {
        let i = UserDefaults.standard.integer(forKey: intervalKey)
        return i >= 3 ? i : 5
    }
}
