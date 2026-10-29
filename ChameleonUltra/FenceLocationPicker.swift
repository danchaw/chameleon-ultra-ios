import SwiftUI
import MapKit
import Combine

// MARK: - Place search
//
// MapKit's local search needs no API key. Results are biased to the visible
// map rect so "KFC" resolves to the one on screen, not one three cities away.

@MainActor
final class PlaceSearchModel: NSObject, ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { update(query: query) } }
    }
    /// Suggestions straight from the completer — a single local call, so the
    /// list appears as fast as you type. Coordinates are only fetched, lazily,
    /// when a row is tapped.
    @Published private(set) var completions: [MKLocalSearchCompletion] = []
    @Published private(set) var isSearching = false
    /// Filled when the query looks like a bare coordinate pair, e.g.
    /// "30.6, 104.0", so Enter can jump straight there.
    @Published private(set) var coordinateHint = ""

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.pointOfInterest, .address]
    }

    func bind(region: MKCoordinateRegion?) {
        guard let region else { return }
        let span = max(region.span.latitudeDelta, region.span.longitudeDelta)
        completer.region = MKCoordinateRegion(
            center: region.center,
            span: MKCoordinateSpan(latitudeDelta: span * 1.2, longitudeDelta: span * 1.2))
    }

    private func update(query: String) {
        coordinateHint = Self.parseCoordinate(query) == nil ? "" : L10n.t("Coordinates detected")
        guard query.trimmingCharacters(in: .whitespaces).count >= 1 else {
            completer.queryFragment = ""
            completions = []
            return
        }
        completer.queryFragment = query
    }

    /// Typed text → a place. A "lat, lon" pair wins over everything so you can
    /// paste coordinates from another app.
    func resolve() async -> MKMapItem? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        isSearching = true
        defer { isSearching = false }
        if let coordinate = Self.parseCoordinate(text) {
            return Self.dropPin(at: coordinate,
                                named: String(format: "%.4f, %.4f",
                                              coordinate.latitude, coordinate.longitude))
        }
        if let completion = completions.first, let item = await resolve(completion) {
            return item
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        request.region = completer.region
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return item
    }

    /// The completer only hands back suggestions; MKLocalSearch expands each
    /// into a real map item with a coordinate.
    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else { return nil }
        return item
    }

    func clear() {
        completions = []
        coordinateHint = ""
    }

    static func dropPin(at coordinate: CLLocationCoordinate2D, named name: String) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = name
        return item
    }

    /// "30.6598, 104.0633" / "30.6598 104.0633" → coordinate. Nil for text.
    static func parseCoordinate(_ text: String) -> CLLocationCoordinate2D? {
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard parts.count == 2,
              let lat = Double(parts[0]),
              let lon = Double(parts[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

extension PlaceSearchModel: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let completions = Array(completer.results.prefix(8))
        Task { @MainActor in self.completions = completions }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.completions = [] }
    }
}

// MARK: - Map canvas
//
// Dragging and zooming are free; the fence centre is whatever sits under the
// fixed crosshair, so you can pan the world until the target is in the middle
// and pick the radius afterwards.

struct FenceMapView: UIViewRepresentable {
    var region: MKCoordinateRegion
    var centre: CLLocationCoordinate2D?
    var radius: Double
    /// Which camera request to apply — a new value re-centres the map.
    var centreRequest: Int = 0
    /// Fires whenever the visible region settles. `userDriven` is false while
    /// a programmatic camera request is landing, so drag-to-pick does not
    /// fight animated pans to GPS or to a searched place.
    var onRegionChanged: (MKCoordinateRegion, _ userDriven: Bool) -> Void = { _, _ in }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.setRegion(region, animated: false)
        // The opening camera is ours, not a drag: do not preselect its centre.
        context.coordinator.programmaticCentre = region.center
        context.coordinator.parent = self
        context.coordinator.apply(centre: centre, radius: radius, to: map)
        return map
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastCentreRequest != centreRequest {
            context.coordinator.lastCentreRequest = centreRequest
            context.coordinator.programmaticCentre = region.center
            map.setRegion(region, animated: true)
        }
        context.coordinator.apply(centre: centre, radius: radius, to: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FenceMapView?
        var lastCentreRequest = 0
        /// Centre of the camera move we last asked for. A region callback
        /// landing here is *our* animation finishing, not the user dragging,
        /// so drag-to-pick must not treat it as a fresh selection.
        var programmaticCentre: CLLocationCoordinate2D?
        private var pin: FencePin?
        private var circle: MKCircle?
        private var didSeedUserLocation = false

        func apply(centre: CLLocationCoordinate2D?, radius: Double, to map: MKMapView) {
            guard let centre else {
                if let pin {
                    map.removeAnnotation(pin)
                    self.pin = nil
                }
                removeCircle(from: map)
                return
            }
            // The crosshair follows the selection live: dragging the map
            // slides the world under a circle that stays where you put it.
            let annotation = pin ?? {
                let fresh = FencePin(coordinate: centre)
                map.addAnnotation(fresh)
                pin = fresh
                return fresh
            }()
            annotation.coordinate = centre
            annotation.radius = radius
            if let old = circle,
               abs(old.coordinate.latitude - centre.latitude) < 1e-8,
               abs(old.coordinate.longitude - centre.longitude) < 1e-8,
               abs(old.radius - radius) < 0.5 { return }
            removeCircle(from: map)
            guard radius > 0 else { return }
            let fresh = MKCircle(center: centre, radius: radius)
            map.addOverlay(fresh)
            circle = fresh
        }

        private func removeCircle(from map: MKMapView) {
            if let circle {
                map.removeOverlay(circle)
                self.circle = nil
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didSeedUserLocation,
                  let coordinate = userLocation.location?.coordinate else { return }
            didSeedUserLocation = true
            let seed = MKCoordinateRegion(center: coordinate,
                                          latitudinalMeters: 300,
                                          longitudinalMeters: 300)
            programmaticCentre = seed.center
            mapView.setRegion(seed, animated: true)
        }

        // Search suggestions follow the visible map, not the whole planet.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if mapView.userTrackingMode != .none {
                mapView.setUserTrackingMode(.none, animated: false)
            }
            // MapKit's own change, or ours? Animated programmatic pans end
            // exactly where we asked; anything else came from a finger.
            var userDriven = true
            if let target = programmaticCentre {
                let landed = mapView.region.center
                let off = CLLocation(latitude: target.latitude, longitude: target.longitude)
                    .distance(from: CLLocation(latitude: landed.latitude,
                                               longitude: landed.longitude))
                if off < 5 { userDriven = false }
            }
            if userDriven { programmaticCentre = nil }
            parent?.onRegionChanged(mapView.region, userDriven)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = .systemRed
                renderer.fillColor = UIColor.systemRed.withAlphaComponent(0.28)
                renderer.lineWidth = 3
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard annotation is FencePin else { return nil }
            let id = "fencePin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            view.canShowCallout = false
            view.annotation = annotation
            return view
        }
    }
}

final class FencePin: NSObject, MKAnnotation {
    var coordinate: CLLocationCoordinate2D
    var radius: Double = 0
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}