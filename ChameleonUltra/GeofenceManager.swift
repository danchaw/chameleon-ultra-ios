import Foundation
import CoreLocation

/// Location monitoring for the electronic fence. Registers every saved
/// circular region with CoreLocation and reports ENTER events with the
/// region id. The AppModel then pushes the bound card into the device.
@MainActor
final class GeofenceManager: NSObject, ObservableObject {

    static let enabledKey = "geoFenceEnabled"

    /// Human-readable state for the Settings page.
    @Published var statusText = ""

    /// Live authorization status so the "background triggers" Toggle
    /// reflects reality (the system dialog changes it behind our back).
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    /// Region ids currently registered with CoreLocation.
    private var registered = Set<UUID>()

    /// Fired when the phone enters a bound region.
    var onRegionEnter: ((UUID) -> Void)?

    /// Dedupe ENTER triggers: requestState + didEnterRegion + the manual probe
    /// can all report the same region seconds apart.
    private var lastTrigger: (id: UUID, at: Date)?

    @MainActor
    private func fireEnter(_ id: UUID) {
        guard registered.contains(id),
              GeoRegionStore.load().contains(where: { $0.id == id && $0.isEnabled }) else { return }
        if let last = lastTrigger, last.id == id,
           Date().timeIntervalSince(last.at) < 30 { return }
        lastTrigger = (id, Date())
        onRegionEnter?(id)
    }

    /// One-shot current-location request (the region editor uses it to open
    /// the camera at the user's position instead of the whole world).
    private var locationCompletion: ((CLLocationCoordinate2D?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
    }

    /// "Always" granted — the fence wakes the app on the locked screen.
    var hasAlwaysAccess: Bool { authorization == .authorizedAlways }

    var isAllowed: Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }


    /// Ask for "Always" so fence events wake the app while the phone is
    /// locked (iOS shows a second confirmation in Settings).
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// Single position fix; completion runs on main, nil on failure/denied.
    func requestCurrentLocation(_ completion: @escaping (CLLocationCoordinate2D?) -> Void) {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            completion(nil)
            return
        case .denied, .restricted:
            completion(nil)
            return
        default:
            break
        }
        locationCompletion = completion
        manager.requestLocation()
    }

    /// Stop every currently monitored region.
    private func stopAllMonitoring() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        registered.removeAll()
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
            stopAllMonitoring()
            return
        default:
            break
        }

        stopAllMonitoring()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            statusText = L10n.t("Fence monitoring off")
            return
        }
        let regions = GeoRegionStore.load().filter { $0.isEnabled && $0.radius > 0 }
        guard !regions.isEmpty else {
            statusText = L10n.t("No regions yet")
            return
        }
        for region in regions {
            let cr = CLCircularRegion(center: region.coordinate,
                                      radius: region.monitoringRadius,
                                      identifier: region.id.uuidString)
            cr.notifyOnEntry = true
            cr.notifyOnExit = false
            manager.startMonitoring(for: cr)
            // Answer arrives via didDetermineState (NOT didEnterRegion).
            manager.requestState(for: cr)
            registered.insert(region.id)
        }
        statusText = L10n.tf("Monitoring %d region(s)", regions.count)
        // CoreLocation only fires ENTER on true transitions and may lag minutes,
        // so check "already inside" ourselves right now.
        probeInsideNow()
    }

    /// One-shot position fix; applies any region whose TRUE radius contains us.
    private func probeInsideNow() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), isAllowed else { return }
        let regions = GeoRegionStore.load().filter { $0.isEnabled && $0.radius > 0 }
        guard !regions.isEmpty else { return }
        requestCurrentLocation { [weak self] coord in
            guard let self, let coord else { return }
            let here = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            for r in regions
            where here.distance(from: CLLocation(latitude: r.centerLatitude,
                                                 longitude: r.centerLongitude)) <= r.radius {
                self.fireEnter(r.id)
            }
        }
    }
}

// CLLocationManager delivers callbacks on the thread that created it —
// the app creates GeofenceManager on MainActor, so hops are belt-and-braces.

extension GeofenceManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            self.authorization = status
            self.refreshMonitoring()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in
            guard let completion = self.locationCompletion else { return }
            self.locationCompletion = nil
            completion(coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard let completion = self.locationCompletion else { return }
            self.locationCompletion = nil
            completion(nil)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier) else { return }
        Task { @MainActor in
            self.fireEnter(id)
        }
    }

    /// requestState(for:) answers HERE (inside/outside/unknown) — this is what
    /// makes "already inside when the fence is created" work.
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didDetermineState state: CLRegionState,
                                     for region: CLRegion) {
        guard state == .inside,
              let id = UUID(uuidString: region.identifier) else { return }
        Task { @MainActor in
            self.fireEnter(id)
        }
    }
}
