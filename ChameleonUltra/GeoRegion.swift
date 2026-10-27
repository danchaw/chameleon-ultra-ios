import Foundation
import CoreLocation

/// One bound "electronic fence" region: a circle or a hand-drawn polygon on
/// the map, bound to ONE saved card (a card may be bound to many regions).
/// Entering the region makes the app push the bound card into the Chameleon's
/// active slot over BLE — walk into company, company card is ready.
struct GeoRegion: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case circle, polygon }

    var id: UUID = UUID()
    var name: String
    var cardId: UUID
    var kind: Kind
    /// Circle center (also the polygon bounding-circle center for monitoring).
    var centerLatitude: Double
    var centerLongitude: Double
    /// Circle radius in meters; for polygons: bounding radius.
    var radius: Double
    /// Polygon vertices (empty for circles).
    var points: [[Double]] = []   // [[lat, lon], ...]

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        switch kind {
        case .circle:
            let center = CLLocation(latitude: centerLatitude, longitude: centerLongitude)
            let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return center.distance(from: point) <= radius
        case .polygon:
            return GeoRegion.pointInPolygon(coordinate, points)
        }
    }

    /// Ray casting on lat/lon treated as planar — fine for door-scale areas.
    static func pointInPolygon(_ p: CLLocationCoordinate2D, _ pts: [[Double]]) -> Bool {
        guard pts.count >= 3 else { return false }
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let yi = pts[i][0], xi = pts[i][1]
            let yj = pts[j][0], xj = pts[j][1]
            let intersects = ((yi > p.latitude) != (yj > p.latitude)) &&
                (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi)
            if intersects { inside.toggle() }
            j = i
        }
        return inside
    }

    /// Smallest circle covering all polygon vertices (used for system
    /// region monitoring; exact containment re-checked on entry).
    static func boundingCircle(for points: [[Double]]) -> (center: CLLocationCoordinate2D, radius: Double) {
        guard let first = points.first else {
            return (CLLocationCoordinate2D(), 50)
        }
        var minLat = first[0], maxLat = first[0], minLon = first[1], maxLon = first[1]
        for pt in points {
            minLat = min(minLat, pt[0]); maxLat = max(maxLat, pt[0])
            minLon = min(minLon, pt[1]); maxLon = max(maxLon, pt[1])
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let c = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var radius = 50.0
        for pt in points {
            let p = CLLocation(latitude: pt[0], longitude: pt[1])
            radius = max(radius, c.distance(from: p))
        }
        return (center, radius)
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
