import Foundation
import CoreLocation

/// Location monitoring for the electronic fence. Registers every saved
/// region (circles directly; polygons as their bounding circle with an exact
/// point-in-polygon re-check on entry) and reports ENTER events with the
/// region id. The AppModel then pushes the bound card into the device.
@MainActor
final class GeofenceManager: NSObject, ObservableObject {

    static let enabledKey = "geoFenceEnabled"

    /// Human-readable state for the Settings page.
    @Published var statusText = ""

    private let manager = CLLocationManager()
    /// Region ids currently registered with CoreLocation.
    private var registered = Set<UUID>()
    /// Regions awaiting a one-shot location fix to confirm polygon entry.
    private var pendingConfirm = Set<UUID>()

    /// Fired when the phone enters a bound region (exact for circles; for
    /// polygons the app re-checks the exact polygon before acting).
    var onRegionEnter: ((UUID) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var isAllowed: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// Rebuild all region monitoring from the store. Call after any settings
    /// change or region edit.
    func refreshMonitoring() {
        guard CLLocationManager.locationServicesEnabled() else {
            statusText = L10n.t("Location services are off")
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            statusText = L10n.t("Requesting location permission…")
            return
        case .denied, .restricted:
            statusText = L10n.t("Location permission denied")
            manager.stopMonitoring()
            registered.removeAll()
            return
        default:
            break
        }

        manager.stopMonitoring()
        registered.removeAll()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            statusText = L10n.t("Fence monitoring off")
            return
        }
        let regions = GeoRegionStore.load()
        guard !regions.isEmpty else {
            statusText = L10n.t("No regions yet")
            return
        }
        for region in regions {
            let cr = CLCircularRegion(center: region.coordinate,
                                      radius: max(50, region.radius),
                                      identifier: region.id.uuidString)
            cr.notifyOnEntry = true
            cr.notifyOnExit = false
            manager.startMonitoring(for: cr)
            manager.requestState(for: cr)   // fires didEnter if already inside
            registered.insert(region.id)
        }
        statusText = String(format: L10n.t("Monitoring %d region(s)"), regions.count)
    }

    /// One-shot location fix used to confirm polygon containment.
    private func requestContainmentCheck(for region: GeoRegion) {
        pendingConfirm.insert(region.id)
        manager.startUpdatingLocation()
    }
}

// CLLocationManager delivers callbacks on the thread that created it —
// the app creates GeofenceManager on MainActor, so hops are belt-and-braces.

extension GeofenceManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in self.refreshMonitoring() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            guard !self.pendingConfirm.isEmpty else {
                manager.stopUpdatingLocation()
                return
            }
            manager.stopUpdatingLocation()
            let regions = GeoRegionStore.load()
            for id in self.pendingConfirm {
                guard let region = regions.first(where: { $0.id == id }) else { continue }
                if region.contains(location.coordinate) {
                    self.onRegionEnter?(region.id)
                }
            }
            self.pendingConfirm.removeAll()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.pendingConfirm.removeAll()
            manager.stopUpdatingLocation()
            self.statusText = L10n.t("Location failed")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier) else { return }
        Task { @MainActor in
            guard self.registered.contains(id),
                  let region = GeoRegionStore.load().first(where: { $0.id == id }) else { return }
            if region.kind == .polygon {
                // bounding circle only — confirm exact polygon containment
                self.requestContainmentCheck(for: region)
            } else {
                self.onRegionEnter?(id)
            }
        }
    }
}
