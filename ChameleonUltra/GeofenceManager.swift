import Foundation
import CoreLocation
import UIKit

/// Location monitoring for the electronic fence. Registers every saved
/// circular region with CoreLocation and reports ENTER events with the
/// region id. The AppModel then pushes the bound card into the device.
///
/// Reliability design follows the Home Assistant iOS ZoneManager playbook
/// (see research notes in Documents\DSH\_geo_research\REPORT.md):
///  1. registration replays are swallowed (startMonitoring answers with a
///     didDetermineState even when NOTHING changed — probeInsideNow is the
///     only authority for "already inside");
///  2. system ENTER events are never acted on blindly — a fresh one-shot
///     fix re-verifies against the TRUE radius first (events lag minutes
///     and fire on GPS jitter);
///  3. stale cached fixes (>180 s) never count as "inside";
///  4. every event gets a verdict — status line + onEventLog sink — silence
///     was the original complaint.
/// CoreLocation hard-caps us at 20 monitored regions per app, so over that
/// only the 19 nearest to the last known position get registered.
@MainActor
final class GeofenceManager: NSObject, ObservableObject {

    static let enabledKey = "geoFenceEnabled"

    /// CoreLocation allows 20; keep one slot free for future system use.
    private static let regionCap = 19

    /// Human-readable state for the fence card.
    @Published var statusText = ""

    /// Every monitoring event mirrors into here (AppModel appends to the
    /// in-app Logs tab) — "what did the fence see?" must be answerable.
    var onEventLog: ((String) -> Void)?

    private func log(_ s: String) { onEventLog?(s) }

    /// Live authorization status so the "background triggers" Toggle
    /// reflects reality (the system dialog changes it behind our back).
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    /// Region ids currently registered with CoreLocation.
    private var registered = Set<UUID>()

    /// Fired when the phone enters a bound region. `forced` marks USER intent
    /// (toggle on, save, connect, "Check now") — the write path must not
    /// honour the "already matches" ledger for those.
    var onRegionEnter: ((UUID, _ forced: Bool) -> Void)?

    /// "Monitoring %d region(s)" line the probe results get appended to.
    private var monitorLine = ""

    /// Dedupe ENTER triggers: requestState + didEnterRegion + the manual probe
    /// can all report the same region seconds apart.
    private var lastTrigger: (id: UUID, at: Date)?

    /// didDetermineState answers queued to be dropped: registering a region
    /// makes CoreLocation replay a state answer even with no movement —
    /// HA swallows exactly these. Our own probe covers "already inside".
    private var swallowNextState = Set<UUID>()

    /// Last usable fix (all sources); the 20-region trim sorts by it.
    private(set) var lastKnown: CLLocation?

    @discardableResult
    private func fireEnter(_ id: UUID, force: Bool = false) -> Bool {
        guard registered.contains(id),
              GeoRegionStore.load().contains(where: { $0.id == id && $0.isEnabled }) else { return false }
        if !force, let last = lastTrigger, last.id == id,
           Date().timeIntervalSince(last.at) < 30 { return false }
        lastTrigger = (id, Date())
        onRegionEnter?(id, force)
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
        swallowNextState.removeAll()
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            statusText = L10n.t("Fence monitoring off")
            log("refresh: master switch off")
            return
        }
        var regions = GeoRegionStore.load().filter { $0.isEnabled && $0.radius > 0 }
        guard !regions.isEmpty else {
            statusText = L10n.t("No regions yet")
            log("refresh: no enabled regions")
            return
        }
        // CoreLocation caps one app at 20 monitored regions; past the cap keep
        // only the nearest to our last known position (HA prunes the same way).
        if regions.count > Self.regionCap {
            let total = regions.count
            if let ref = lastKnown {
                regions.sort {
                    CLLocation(latitude: $0.centerLatitude, longitude: $0.centerLongitude)
                        .distance(from: ref)
                        < CLLocation(latitude: $1.centerLatitude, longitude: $1.centerLongitude)
                            .distance(from: ref)
                }
            }
            regions = Array(regions.prefix(Self.regionCap))
            log("trim: \(total) regions \u{2192} nearest \(Self.regionCap)")
        }
        for region in regions {
            let cr = CLCircularRegion(center: region.coordinate,
                                      radius: region.monitoringRadius,
                                      identifier: region.id.uuidString)
            cr.notifyOnEntry = true
            cr.notifyOnExit = false
            manager.startMonitoring(for: cr)
            // Registration ALWAYS replays a didDetermineState answer even with
            // zero movement — HA swallows those; our own probe below is the
            // only authority for "already inside".
            swallowNextState.insert(region.id)
            manager.requestState(for: cr)
            registered.insert(region.id)
        }
        statusText = L10n.tf("Monitoring %d region(s)", regions.count)
        monitorLine = statusText
        log("refresh: monitoring \(regions.count), force=\(force)")
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

    /// Core rule #2: a system ENTER (or .inside state answer) is a HINT, never
    /// an order. Events lag minutes and fire on GPS jitter, so before writing
    /// any card we take one fresh fix and test it against the TRUE radius
    /// (plus the fix's own accuracy, capped at 100 m — indoor GPS is routinely
    /// 50–150 m off). No fix at all → trust the event anyway: a redundant
    /// write is harmless (the ledger + force semantics in AppModel make it a
    /// no-op when the card is already in place), silence was the real bug.
    /// A background task keeps us runnable while CLLocationManager answers.
    private func verifyThenFire(_ id: UUID, source: String) {
        guard let region = GeoRegionStore.load().first(where: { $0.id == id && $0.isEnabled }) else {
            log("\(source): \(id) not an enabled registered region — ignored")
            return
        }
        log("\(source) event for 「\(region.name)」 — re-checking with GPS")
        let app = UIApplication.shared
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = app.beginBackgroundTask(withName: "fence-verify") {
            if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid }
        }
        let endBG: () -> Void = { if bg != .invalid { app.endBackgroundTask(bg); bg = .invalid } }
        requestFix { [weak self] fix in
            guard let self else { endBG(); return }
            // HA freshness rule: cached fixes older than 3 minutes say nothing
            // about NOW.
            let fresh = fix != nil && fix!.timestamp.timeIntervalSinceNow > -180
            guard let fix, fresh else {
                log("\(source): no fresh fix — trusting the event")
                _ = self.fireEnter(id)
                endBG()
                return
            }
            self.lastKnown = fix
            let centre = CLLocation(latitude: region.centerLatitude, longitude: region.centerLongitude)
            let distance = fix.distance(from: centre)
            let slack = fix.horizontalAccuracy >= 0 ? min(fix.horizontalAccuracy, 100) : 0
            if distance <= region.radius + slack {
                log("\(source): verified inside (\(Int(distance)) m ≤ \(Int(region.radius)) m + \(Int(slack)) m)")
                _ = self.fireEnter(id)
            } else {
                // Late/ghost event — say so on the card, do NOT write.
                self.statusText = "\(self.monitorLine) · "
                    + L10n.tf("GPS check: outside by %d m", Int(distance - region.radius))
                log("\(source): dismissed — outside by \(Int(distance - region.radius)) m")
            }
            endBG()
        }
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
                self.log("probe: no position fix")
                return
            }
            self.lastKnown = here
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
                self.log("probe: outside every region (nearest \(Int(nearest)) m)")
                return
            }
            var anyFired = false
            for r in hits where self.fireEnter(r.id, force: force) { anyFired = true }
            if !anyFired {
                // In range, but the trigger was deduped / not registered.
                self.statusText = L10n.tf("In range, %d region(s) — already handled", hits.count)
                self.log("probe: in range ×\(hits.count), all deduped")
            } else {
                self.log("probe: firing for \(hits.count) region(s), force=\(force)")
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
            if let fix, fix.timestamp.timeIntervalSinceNow > -180 {
                self.lastKnown = fix
            }
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
            // Never act on the raw event — GPS re-check first (rule #2).
            self.verifyThenFire(id, source: "ENTER")
        }
    }

    /// requestState(for:) answers HERE (inside/outside/unknown). The replay
    /// that registration produces for every region is swallowed (rule #1) —
    /// probeInsideNow is the authority for "already inside". Anything left is
    /// a genuine transition and still gets the GPS re-check.
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didDetermineState state: CLRegionState,
                                     for region: CLRegion) {
        guard let id = UUID(uuidString: region.identifier) else { return }
        Task { @MainActor in
            if self.swallowNextState.remove(id) != nil {
                self.log("registration replay swallowed for \(id) (\(state.rawValue))")
                return
            }
            guard state == .inside else { return }
            self.verifyThenFire(id, source: "STATE")
        }
    }
}
