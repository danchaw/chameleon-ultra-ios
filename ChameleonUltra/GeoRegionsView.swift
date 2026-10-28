import SwiftUI
import MapKit

/// Electronic-fence region list + map editor. A region binds ONE saved card;
/// entering the circle makes the app push that card into the Chameleon's
/// active slot automatically.
struct GeoRegionsView: View {
    @EnvironmentObject var store: CardStore
    @EnvironmentObject var app: AppModel
    @State private var regions: [GeoRegion] = GeoRegionStore.load()
    @State private var showEditor = false

    var body: some View {
        List {
            Section {
                if regions.isEmpty {
                    Text(L10n.t("No regions yet"))
                        .foregroundStyle(.secondary)
                }
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
            GeoRegionEditorView {
                regions = GeoRegionStore.load()
                app.geofence.refreshMonitoring()
            }
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
        return String(format: L10n.t("Circle · %.0f m"), region.radius) + " · \(cardName)"
    }
}

// MARK: - Editor

struct GeoRegionEditorView: View {
    @EnvironmentObject var store: CardStore
    @Environment(\.dismiss) private var dismiss
    var onSaved: () -> Void

    @EnvironmentObject var app: AppModel
    @State private var name = ""
    @State private var cardId: UUID?
    @State private var center: CLLocationCoordinate2D?
    @State private var radius: Double = 300
    /// One-shot camera target: the user's position when the editor opens.
    @State private var focus: CLLocationCoordinate2D?
    @State private var locateFailed = false

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
                    RegionMapCanvas(center: $center, radius: $radius, focus: focus)
                        .frame(height: 200)
                        .listRowInsets(EdgeInsets())
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        // crosshair marks the screen centre = circle centre
                        .overlay {
                            ZStack {
                                Rectangle().fill(Color.red.opacity(0.9))
                                    .frame(width: 17, height: 2)
                                Rectangle().fill(Color.red.opacity(0.9))
                                    .frame(width: 2, height: 17)
                            }
                        }
                    Text(locateFailed ? L10n.t("Cannot get current location")
                                       : L10n.t("Drag the map — screen centre sets the circle"))
                        .font(.caption)
                        .foregroundStyle(locateFailed ? Color.red : Color.secondary)
                    VStack(alignment: .leading) {
                        Text("\(L10n.t("Radius")): \(Int(radius)) m")
                            .font(.footnote)
                        Slider(value: $radius, in: 50...3000, step: 50)
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
            .onAppear {
                app.geofence.requestCurrentLocation { coordinate in
                    if let coordinate {
                        focus = coordinate
                    } else {
                        locateFailed = true
                    }
                }
            }
        }
    }

    private var canSave: Bool {
        cardId != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty && center != nil
    }

    private func save() {
        guard let cardId, let center else { return }
        let region = GeoRegion(name: name.trimmingCharacters(in: .whitespaces),
                               cardId: cardId,
                               centerLatitude: center.latitude,
                               centerLongitude: center.longitude,
                               radius: radius)
        GeoRegionStore.add(region)
        onSaved()
        dismiss()
    }
}

// MARK: - Map canvas
//
// On open the editor passes a `focus` coordinate (the user's position, via a
// one-shot CLLocationManager request) and the camera jumps there with a
// ~radius*4 span — a 300 m fence fills the view instead of the whole world.
// Dragging the map moves the circle center (screen centre = circle centre);
// the red ring re-draws under the crosshair continuously.

struct RegionMapCanvas: UIViewRepresentable {
    @Binding var center: CLLocationCoordinate2D?
    @Binding var radius: Double
    var focus: CLLocationCoordinate2D?

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isRotateEnabled = false
        return map
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyFocusIfNeeded(map)
        context.coordinator.redraw(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: RegionMapCanvas
        /// Suppresses region-change feedback while we move the camera.
        private var programmaticMove = false
        private var appliedFocus: CLLocationCoordinate2D?

        init(_ parent: RegionMapCanvas) {
            self.parent = parent
        }

        // user panned/zoomed: the map centre IS the circle centre
        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            if programmaticMove {
                programmaticMove = false
                return
            }
            parent.center = map.centerCoordinate
            redraw(map)
        }

        func applyFocusIfNeeded(_ map: MKMapView) {
            guard let focus = parent.focus, parent.center == nil,
                  !Self.same(focus, appliedFocus) else { return }
            appliedFocus = focus
            programmaticMove = true
            parent.center = focus
            map.setRegion(MKCoordinateRegion(center: focus,
                                             latitudinalMeters: parent.radius * 4,
                                             longitudinalMeters: parent.radius * 4), animated: false)
        }

        static func same(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D?) -> Bool {
            guard let b else { return false }
            return abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
        }

        func redraw(_ map: MKMapView) {
            map.removeOverlays(map.overlays)
            if let center = parent.center {
                map.addOverlay(MKCircle(center: center, radius: parent.radius))
            }
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
    }
}
