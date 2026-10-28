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
    @State private var editingRegion: GeoRegion?

    var body: some View {
        List {
            Section {
                if regions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(L10n.t("No regions yet"))
                            .font(.headline)
                        Text(L10n.t("Add a region and bind a card — walking into the circle loads that card automatically."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
                ForEach(regions) { region in
                    HStack(spacing: 12) {
                        Button {
                            editingRegion = region
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(region.name).font(.headline)
                                HStack(spacing: 6) {
                                    Image(systemName: "creditcard")
                                    Text(cardName(region))
                                    Text("·")
                                    Text(radiusText(region))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Toggle("", isOn: Binding(
                            get: { region.isEnabled && region.radius > 0 },
                            set: { on in
                                GeoRegionStore.setEnabled(region.id, on)
                                regions = GeoRegionStore.load()
                                app.geofence.refreshMonitoring()
                            }
                        ))
                        .labelsHidden()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            GeoRegionStore.delete(region)
                            regions = GeoRegionStore.load()
                            app.geofence.refreshMonitoring()
                        } label: {
                            Label(L10n.t("Delete"), systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text(L10n.t("The circle is centred on you and shows 100 m around your position. Swipe left to delete."))
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
            GeoRegionEditorView(region: nil) {
                regions = GeoRegionStore.load()
                app.geofence.refreshMonitoring()
            }
        }
        .sheet(item: $editingRegion) { region in
            GeoRegionEditorView(region: region) {
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

    private func cardName(_ region: GeoRegion) -> String {
        store.cards.first { $0.id == region.cardId }?.name ?? L10n.t("Card missing")
    }

    private func radiusText(_ region: GeoRegion) -> String {
        region.radius > 0 ? String(format: L10n.t("%.0f m"), region.radius)
                          : L10n.t("Fence off")
    }
}

// MARK: - Editor

struct GeoRegionEditorView: View {
    @EnvironmentObject var store: CardStore
    @Environment(\.dismiss) private var dismiss
    /// nil = create; non-nil = edit in place.
    var region: GeoRegion?
    var onSaved: () -> Void

    @EnvironmentObject var app: AppModel
    @State private var name = ""
    @State private var cardId: UUID?
    @State private var radius: Double = 100

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
                    // Fixed view: always a 100 m window around the user's
                    // position; the red circle is drawn at `radius`.
                    UserCentredMap(radius: radius)
                        .frame(height: 240)
                        .listRowInsets(EdgeInsets())
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            Text("100 m")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }
                    HStack(spacing: 12) {
                        Text(L10n.t("Radius"))
                            .font(.footnote)
                        Slider(value: $radius, in: 0...500, step: 50)
                        Text(radiusText)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(radius > 0 ? Color.accentColor : .secondary)
                            .frame(minWidth: 54, alignment: .trailing)
                    }
                    Text(radius > 0 ? L10n.t("Entering the circle loads the bound card")
                                    : L10n.t("Radius 0 turns this fence off"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button(region == nil ? L10n.t("Save region") : L10n.t("Save changes")) { save() }
                        .disabled(!canSave)
                }
            }
            .navigationTitle(region == nil ? L10n.t("Add region") : L10n.t("Edit region"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var radiusText: String {
        radius > 0 ? String(format: "%.0f m", radius) : L10n.t("Fence off")
    }

    private var canSave: Bool {
        cardId != nil && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func prefill() {
        guard let region else { return }
        name = region.name
        cardId = region.cardId
        radius = region.radius
    }

    private func save() {
        guard let cardId else { return }
        // Fresh location capture: fences are relative to where you are now.
        app.geofence.requestCurrentLocation { coordinate in
            let centre = coordinate ?? region?.coordinate
            guard let centre else { return }
            if var existing = region {
                existing.name = name.trimmingCharacters(in: .whitespaces)
                existing.cardId = cardId
                existing.radius = radius
                existing.centerLatitude = centre.latitude
                existing.centerLongitude = centre.longitude
                GeoRegionStore.update(existing)
            } else {
                GeoRegionStore.add(GeoRegion(name: name.trimmingCharacters(in: .whitespaces),
                                             cardId: cardId,
                                             centerLatitude: centre.latitude,
                                             centerLongitude: centre.longitude,
                                             radius: radius))
            }
            onSaved()
            dismiss()
        }
    }
}

// MARK: - Map canvas
//
// Fixed 100 m window around the user: the camera is locked to the device
// location (recentred whenever it moves >1 m) and shows ~200 m across, so the
// red fence circle (radius 0–500, default 100) is always drawn relative to
// "me". Dragging the map is disabled — the view is a live preview, not a
// placement surface; the centre is captured from the GPS fix on save.

struct UserCentredMap: UIViewRepresentable {
    var radius: Double

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.isScrollEnabled = false
        map.isZoomEnabled = false
        return map
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.recentreIfNeeded(map)
        context.coordinator.redraw(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: UserCentredMap
        private var currentCentre: CLLocationCoordinate2D?
        private var lastCamera: CLLocationCoordinate2D?

        init(_ parent: UserCentredMap) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let coordinate = userLocation.location?.coordinate else { return }
            currentCentre = coordinate
            recentreIfNeeded(mapView)
            redraw(mapView)
        }

        // Centre once, then only when the fix drifts, so the user can still
        // inspect while standing still.
        func recentreIfNeeded(_ map: MKMapView) {
            guard let centre = currentCentre else { return }
            if let last = lastCamera,
               CLLocation(latitude: last.latitude, longitude: last.longitude)
                   .distance(from: CLLocation(latitude: centre.latitude,
                                              longitude: centre.longitude)) < 1 {
                return
            }
            lastCamera = centre
            map.setRegion(MKCoordinateRegion(center: centre,
                                             latitudinalMeters: 200,
                                             longitudinalMeters: 200), animated: lastCamera != nil)
        }

        func redraw(_ map: MKMapView) {
            map.removeOverlays(map.overlays)
            guard let centre = currentCentre, parent.radius > 0 else { return }
            map.addOverlay(MKCircle(center: centre, radius: parent.radius))
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
