import SwiftUI
import MapKit

/// Electronic-fence region list + map editor. A region binds ONE saved card;
/// entering the region (circle or drawn polygon) makes the app push that card
/// into the Chameleon's active slot automatically.
struct GeoRegionsView: View {
    @EnvironmentObject var store: CardStore
    @EnvironmentObject var app: AppModel
    @State private var regions: [GeoRegion] = GeoRegionStore.load()
    @State private var showEditor = false

    var body: some View {
        List {
            if regions.isEmpty {
                Section {
                    Text(L10n.t("No regions yet"))
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(regions) { region in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(region.name).font(.headline)
                        Text(regionSubtitle(region))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { indexSet in
                    let doomed = indexSet.map { regions[$0] }
                    doomed.forEach { GeoRegionStore.delete($0) }
                    regions = GeoRegionStore.load()
                    app.geofence.refreshMonitoring()
                }
            }
        }
        .navigationTitle(L10n.t("Geofence"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(store.cards.isEmpty)
            }
        }
        .sheet(isPresented: $showEditor) {
            GeoRegionEditorView { regions = GeoRegionStore.load() }
        }
        .overlay {
            if store.cards.isEmpty {
                Text(L10n.t("No cards — import one first"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func regionSubtitle(_ region: GeoRegion) -> String {
        let cardName = store.cards.first { $0.id == region.cardId }?.name ?? "—"
        let shape = region.kind == .circle
            ? String(format: L10n.t("Circle · %.0f m"), region.radius)
            : L10n.tf("Polygon · %d points", region.points.count)
        return "\(shape) · \(cardName)"
    }
}

// MARK: - Editor

struct GeoRegionEditorView: View {
    @EnvironmentObject var store: CardStore
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void

    @State private var kind: GeoRegion.Kind = .circle
    @State private var name = ""
    @State private var cardId: UUID?
    @State private var center: CLLocationCoordinate2D?
    @State private var radius: Double = 300
    @State private var points: [CLLocationCoordinate2D] = []

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.t("Region name")) {
                    TextField(L10n.t("Name"), text: $name)
                    Picker(L10n.t("Bind card"), selection: $cardId) {
                        Text(L10n.t("Select card…")).tag(UUID?.none)
                        ForEach(store.cards) { card in
                            Text(card.name).tag(UUID?.some(card.id))
                        }
                    }
                }

                Section {
                    Picker(L10n.t("Shape"), selection: $kind) {
                        Text(L10n.t("Circle")).tag(GeoRegion.Kind.circle)
                        Text(L10n.t("Polygon")).tag(GeoRegion.Kind.polygon)
                    }
                    .pickerStyle(.segmented)

                    RegionMapCanvas(kind: kind, center: $center, radius: $radius, points: $points)
                        .frame(height: 300)
                        .listRowInsets(EdgeInsets())
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    switch kind {
                    case .circle:
                        VStack(alignment: .leading) {
                            Text("\(L10n.t("Radius")): \(Int(radius)) m")
                                .font(.footnote)
                            Slider(value: $radius, in: 50...3000, step: 50)
                        }
                        Text(L10n.t("Long-press map to set center"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .polygon:
                        Text(L10n.t("Tap map to add points"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L10n.t("Undo point")) {
                            if !points.isEmpty { points.removeLast() }
                        }
                        .disabled(points.isEmpty)
                    }
                }

                Section {
                    Button(L10n.t("Save region")) { save() }
                        .disabled(!canSave)
                }
            }
            .navigationTitle(L10n.t("Add region"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
            }
        }
    }

    private var canSave: Bool {
        guard cardId != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .circle: return center != nil
        case .polygon: return points.count >= 3
        }
    }

    private func save() {
        guard let cardId else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let region: GeoRegion
        switch kind {
        case .circle:
            guard let center else { return }
            region = GeoRegion(name: trimmed, cardId: cardId, kind: .circle,
                               centerLatitude: center.latitude, centerLongitude: center.longitude,
                               radius: radius)
        case .polygon:
            let doubles = points.map { [$0.latitude, $0.longitude] }
            let bc = GeoRegion.boundingCircle(for: doubles)
            region = GeoRegion(name: trimmed, cardId: cardId, kind: .polygon,
                               centerLatitude: bc.center.latitude, centerLongitude: bc.center.longitude,
                               radius: bc.radius, points: doubles)
        }
        GeoRegionStore.add(region)
        onSaved()
        dismiss()
    }
}

// MARK: - Map drawing canvas (MKMapView: taps = polygon vertices, long-press = circle center)

struct RegionMapCanvas: UIViewRepresentable {
    let kind: GeoRegion.Kind
    @Binding var center: CLLocationCoordinate2D?
    @Binding var radius: Double
    @Binding var points: [CLLocationCoordinate2D]

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isRotateEnabled = false
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        let long = UILongPressGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handleLongPress(_:)))
        map.addGestureRecognizer(tap)
        map.addGestureRecognizer(long)
        return map
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.redraw(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RegionMapCanvas

        init(_ parent: RegionMapCanvas) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard parent.kind == .polygon, let map = gesture.view as? MKMapView, gesture.state == .ended else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            parent.points.append(coordinate)
            redraw(map)
        }

        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            if parent.kind == .circle {
                parent.center = coordinate
                // reframe once per explicit center placement, not on slider drags
                map.setRegion(MKCoordinateRegion(center: coordinate,
                                                 latitudinalMeters: parent.radius * 3,
                                                 longitudinalMeters: parent.radius * 3), animated: true)
                redraw(map)
            }
        }

        func redraw(_ map: MKMapView) {
            map.removeOverlays(map.overlays)
            switch parent.kind {
            case .circle:
                if let center = parent.center {
                    map.addOverlay(MKCircle(center: center, radius: parent.radius))
                }
            case .polygon:
                if parent.points.count >= 2 {
                    var coords = parent.points
                    map.addOverlay(MKPolygon(coordinates: &coords, count: coords.count))
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.strokeColor = .systemRed
                renderer.fillColor = UIColor.systemRed.withAlphaComponent(0.15)
                renderer.lineWidth = 2
                return renderer
            }
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = .systemRed
                renderer.fillColor = UIColor.systemRed.withAlphaComponent(0.15)
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
