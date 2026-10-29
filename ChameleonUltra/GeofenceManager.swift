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

    /// "Monitoring %d region(s)" line the probe results get appended to.
    private var monitorLine = ""

    /// Dedupe ENTER triggers: requestState + didEnterRegion + the manual probe
    /// can all report the same region seconds apart.
    private var lastTrigger: (id: UUID, at: Date)?

    @discardableResult
    private func fireEnter(_ id: UUID, force: Bool = false) -> Bool {
        guard registered.contains(id),
              GeoRegionStore.load().contains(where: { $0.id == id && $0.isEnabled }) else { return false }
        if !force, let last = lastTrigger, last.id == id,
           Date().timeIntervalSince(last.at) < 30 { return false }
        lastTrigger = (id, Date())
        onRegionEnter?(id)
        return true
    }

    /// One-shot current-location requests (the region editor and the fence
    /// probe can overlap; CoreLocation answers the manager once, so every
    /// pending completion must receive the same fix).
    private var locationCompletions: [(_ fix: CLLocation?) -> Void] = []

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
        requestFix { completion($0?.coordinate) }
    }

    /// Like requestCurrentLocation but hands out the raw CLLocation, so the
    /// fence probe can weigh horizontalAccuracy (indoor fixes are routinely
    /// 50–150 m off — comparing them against a 100 m fence with zero
    /// tolerance is why "fence centred on me" read as "outside").
    func requestFix(_ completion: @escaping (CLLocation?) -> Void) {
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
        let box = FixOnce(completion)
        locationCompletions.append { box.deliver($0) }
        manager.requestLocation()
        // Indoor requestLocation can hang for minutes without ever answering;
        // the fence must answer with a verdict, not with silence.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            box.deliver(nil)
        }
    }

    /// Delivers at most once, so the watchdog and the real CLLocation callback
    /// can race without double-firing the completion.
    @MainActor
    private final class FixOnce {
        private var done = false
        private let body: (CLLocation?) -> Void
        init(_ body: @escaping (CLLocation?) -> Void) { self.body = body }
        func deliver(_ fix: CLLocation?) {
            if done { return }
            done = true
            body(fix)
        }
    }

    /// Stop every currently monitored region.
    private func stopAllMonitoring() {
        for region in manager.monitoredRegions {
            manager.stopMonitoring(for: region)
        }
        registered.removeAll()
    }

    /// Rebuild all region monitoring from the store. Call after any settings
    /// change or region edit. `force: true` (user intent: toggle, save, manual
    /// check) also bypasses the 30 s ENTER dedupe for the immediate probe.
    func refreshMonitoring(force: Bool = false) {
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
        monitorLine = statusText
        // CoreLocation only fires ENTER on true transitions and may lag minutes,
        // so check "already inside" ourselves right now.
        probeInsideNow(force: force)
    }

    /// Re-arm after a fresh BLE connect: a fence that fired while the device
    /// was away (or while the probe had no fix) must write the card now.
    func refreshAfterConnect() {
        lastTrigger = nil
        refreshMonitoring(force: true)
    }

    /// One-shot position fix; applies any region whose TRUE radius (plus the
    /// fix's own accuracy, capped at 100 m) contains us, and always prints a
    /// verdict so the user can tell WHERE the chain stopped.
    private func probeInsideNow(force: Bool) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey), isAllowed else { return }
        let regions = GeoRegionStore.load().filter { $0.isEnabled && $0.radius > 0 }
        guard !regions.isEmpty else { return }
        requestFix { [weak self] fix in
            guard let self else { return }
            guard let here = fix else {
                self.statusText = "\(self.monitorLine) · " + L10n.t("No position fix — fence not checked")
                return
            }
            var hits: [GeoRegion] = []
            var nearest = Double.greatestFiniteMagnitude
            for r in regions {
                let distance = here.distance(from: CLLocation(latitude: r.centerLatitude,
                                                              longitude: r.centerLongitude))
                nearest = min(nearest, distance)
                let slack = here.horizontalAccuracy >= 0 ? min(here.horizontalAccuracy, 100) : 0
                if distance <= r.radius + slack { hits.append(r) }
            }
            guard !hits.isEmpty else {
                // Show how far we actually are — the fastest way to see whether
                // the fence centre and the live fix disagree by more than the
                // radius, which is the usual reason a "right on top" fence skips.
                self.statusText = "\(self.monitorLine) · " + L10n.t("Outside every region right now")
                    + "（" + L10n.tf("nearest %d m", Int(nearest)) + "）"
                return
            }
            var anyFired = false
            for r in hits where self.fireEnter(r.id, force: force) { anyFired = true }
            if !anyFired {
                // In range, but the trigger was deduped / not registered.
                self.statusText = L10n.tf("In range, %d region(s) — already handled", hits.count)
            }
        }
    }
}

// CLLocationManager delivers callbacks on the thread that created it —
// the app creates GeofenceManager on MainActor, so hops are belt-and-braces.

extension GeofenceManager: CLLocationManagerDelegate {

    nonisolated func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        Task { @MainActor in
            // iOS re-delivers the CURRENT status on delegate attach / app launch.
            // Acting on a non-change would run a second probe whose dedupe
            // verdict can stomp on the first trigger's status line.
            if self.authorization == status { return }
            self.authorization = status
            self.refreshMonitoring()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last
        Task { @MainActor in
            let completions = self.locationCompletions
            self.locationCompletions = []
            for completion in completions { completion(fix) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            let completions = self.locationCompletions
            self.locationCompletions = []
            for completion in completions { completion(nil) }
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
