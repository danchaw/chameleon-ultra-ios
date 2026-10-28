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
    @Published private(set) var results: [MKMapItem] = []
    @Published private(set) var isSearching = false
    /// Filled when the query looks like a bare coordinate pair, e.g.
    /// "30.6, 104.0", so Enter can jump straight there.
    @Published private(set) var coordinateHint = ""

    private let completer = MKLocalSearchCompleter()
    /// Latest suggestion-expansion run, cancelled when the query changes.
    private var resolveTask: Task<Void, Never>?

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
            results = []
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
        if let item = results.first { return item }
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
        resolveTask?.cancel()
        results = []
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
        Task { @MainActor in
            self.resolveTask?.cancel()
            self.resolveTask = Task { @MainActor in
                let items = await withTaskGroup(of: (Int, MKMapItem?).self) { group -> [(Int, MKMapItem)] in
                    for (index, completion) in completions.enumerated() {
                        group.addTask {
                            let item: MKMapItem? = await self.resolve(completion)
                            return (index, item)
                        }
                    }
                    var found: [(Int, MKMapItem)] = []
                    for await pair in group { if let pair = pair.1 { found.append((pair.0, pair.1)) } }
                    return found
                }
                if Task.isCancelled { return }
                self.results = items.sorted { $0.0 < $1.0 }.map { $0.1 }
            }
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in self.results = [] }
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
    /// Fires after the user stops panning, with the region now on screen.
    var onRegionChanged: (MKCoordinateRegion) -> Void = { _ in }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.setRegion(region, animated: false)
        context.coordinator.parent = self
        context.coordinator.apply(centre: centre, radius: radius, to: map)
        return map
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastCentreRequest != centreRequest {
            context.coordinator.lastCentreRequest = centreRequest
            map.setRegion(region, animated: true)
        }
        context.coordinator.apply(centre: centre, radius: radius, to: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: FenceMapView?
        var lastCentreRequest = 0
        private var drawnCentre: CLLocationCoordinate2D?
        private var drawnRadius: Double = -1
        private var didSeedUserLocation = false

        func apply(centre: CLLocationCoordinate2D?, radius: Double, to map: MKMapView) {
            let moved: Bool
            if let centre {
                if let old = drawnCentre {
                    moved = !(abs(old.latitude - centre.latitude) < 1e-7 &&
                              abs(old.longitude - centre.longitude) < 1e-7)
                } else {
                    moved = true
                }
            } else {
                moved = drawnCentre != nil
            }
            guard moved || abs(radius - drawnRadius) > 0.01 else { return }
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
            if let centre {
                drawnCentre = centre
                drawnRadius = radius
                map.addAnnotation(FencePin(coordinate: centre))
                if radius > 0 {
                    map.addOverlay(MKCircle(center: centre, radius: radius))
                }
            } else {
                drawnCentre = nil
                drawnRadius = -1
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard !didSeedUserLocation,
                  let coordinate = userLocation.location?.coordinate else { return }
            didSeedUserLocation = true
            mapView.setRegion(MKCoordinateRegion(center: coordinate,
                                                 latitudinalMeters: 300,
                                                 longitudinalMeters: 300), animated: true)
        }

        // Search suggestions follow the visible map, not the whole planet.
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if mapView.userTrackingMode != .none {
                mapView.setUserTrackingMode(.none, animated: false)
            }
            parent?.onRegionChanged(mapView.region)
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
    let coordinate: CLLocationCoordinate2D
    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}