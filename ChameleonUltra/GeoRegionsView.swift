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
                                app.geofence.refreshMonitoring(force: on)
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
                Text(L10n.t("Drag the map, search for a place or tap to place the centre — then pick the radius."))
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
                app.geofence.refreshMonitoring(force: true)
            }
        }
        .sheet(item: $editingRegion) { region in
            GeoRegionEditorView(region: region) {
                regions = GeoRegionStore.load()
                app.geofence.refreshMonitoring(force: true)
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
//
// Two stages, in the order the question is actually asked on the phone:
//   1. locate — pan the map, search a place, pin the crosshair, or use my GPS
//   2. radius — slider (0…500, step 50) while the circle grows on the map

private enum EditorStage { case locate, radius }

struct GeoRegionEditorView: View {
    @EnvironmentObject var store: CardStore
    @Environment(\.dismiss) private var dismiss
    /// nil = create; non-nil = edit in place.
    var region: GeoRegion?
    var onSaved: () -> Void

    @EnvironmentObject var app: AppModel
    @StateObject private var search = PlaceSearchModel()

    @State private var stage: EditorStage = .locate
    @State private var name = ""
    @State private var cardId: UUID?
    @State private var radius: Double = 100
    @State private var centre: CLLocationCoordinate2D?
    @State private var placeTitle: String?

    /// Used for the very first frame if position is slow or denied.
    @State private var camera = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074),
        span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004))
    /// Which camera request to apply — a new value re-centres the map.
    @State private var centreRequest = 0
    /// Span of the current view. MKCoordinateRegion is not Equatable, so only
    /// this flag is published; scrubbing a region into @State would re-layout
    /// the whole editor on every finger move.
    @State private var visibleSpan: Double?
    /// Last visible rect, for search biasing and "is it already on screen".
    @State private var mapRegion: MKCoordinateRegion?
    /// A tapped suggestion is being expanded to coordinates.
    @State private var isResolvingPlace = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        // NavigationStack is what gives a sheet its title bar; without it the
        // Cancel / Next / Save toolbar silently disappears.
        NavigationStack {
            VStack(spacing: 0) {
                mapCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                bottomBar
            }
            .navigationTitle(region == nil ? L10n.t("Add region") : L10n.t("Edit region"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(stage == .locate ? L10n.t("Next")
                                            : (region == nil ? L10n.t("Save region") : L10n.t("Save changes"))) {
                        if stage == .locate {
                            confirmCrosshair()
                        } else {
                            save()
                        }
                    }
                    .disabled(stage == .locate ? centre == nil : !canSave)
                }
            }
        }
        .onAppear(perform: prefill)
        .onChange(of: visibleSpan) { _, _ in
            if let mapRegion { search.bind(region: mapRegion) }
        }
        .onChange(of: search.query) { _, newValue in
            // Typing again while sizing the fence means "find another place".
            guard !newValue.isEmpty, stage == .radius else { return }
            withAnimation(.snappy) { stage = .locate }
        }
    }

    // MARK: Map

    private var mapCanvas: some View {
        ZStack(alignment: .top) {
            FenceMapView(region: camera,
                         centre: centre,
                         radius: stage == .radius ? radius : 0,
                         centreRequest: centreRequest,
                         onRegionChanged: { newRegion, userDriven in
                             mapRegion = newRegion
                             visibleSpan = newRegion.span.latitudeDelta
                             if userDriven { centreUnderCrosshair(newRegion.center) }
                         })
                .overlay { crosshair }
                .overlay(alignment: .bottomTrailing) { locateButton }
                .overlay(alignment: .bottomLeading) { hintChip }

            if stage == .locate {
                searchLayer
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { searchFocused = false }
    }

    /// Fixed screen-centre marker: "Confirm" pins whatever sits here.
    private var crosshair: some View {
        ZStack {
            Circle()
                .fill(.red.opacity(0.18))
                .frame(width: 46, height: 46)
            Circle()
                .stroke(.red, lineWidth: 2)
                .frame(width: 18, height: 18)
            Circle()
                .fill(.red)
                .frame(width: 6, height: 6)
            Rectangle()
                .fill(.red.opacity(0.75))
                .frame(width: 1, height: 10)
                .offset(y: -17)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var locateButton: some View {
        Button {
            app.geofence.requestCurrentLocation { coordinate in
                guard let coordinate else {
                    app.lastError = L10n.t("Cannot get current location")
                    return
                }
                place(at: coordinate, title: L10n.t("My location"))
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel(L10n.t("My location"))
    }

    private var hintChip: some View {
        let text: String = {
            if stage == .radius { return L10n.t("Drag the slider to resize the circle") }
            return centre == nil ? L10n.t("Drag or search the map, then tap Confirm")
                                 : L10n.t("Centre picked — adjust the radius next")
        }()
        return Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(12)
            .allowsHitTesting(false)
    }

    // MARK: Search (stage 1)

    private var searchLayer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.t("Search a place or lat, lon"), text: $search.query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .focused($searchFocused)
                        .onSubmit { Task { await jumpToTypedPlace() } }
                    if !search.query.isEmpty {
                        Button {
                            search.query = ""
                            search.clear()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button(L10n.t("Confirm")) { confirmCrosshair() }
                    .font(.subheadline.weight(.semibold))
                    .disabled(centre == nil)
                    .foregroundStyle(centre == nil ? Color.secondary : Color.white)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(centre == nil ? AnyShapeStyle(.regularMaterial)
                                              : AnyShapeStyle(Color.accentColor),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if search.isSearching || isResolvingPlace {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            if searchFocused && !search.completions.isEmpty {
                suggestionList
            } else if !search.coordinateHint.isEmpty {
                Text(search.coordinateHint)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private var suggestionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(search.completions.enumerated()), id: \.offset) { _, completion in
                    Button {
                        choose(completion)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "mappin.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(completion.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                if !completion.subtitle.isEmpty {
                                    Text(completion.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 40)
                }
            }
        }
        .frame(maxHeight: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    /// Tap a suggestion: expand it to coordinates (the completer only knows
    /// names), pin it, and keep the stage so the radius can follow.
    private func choose(_ completion: MKLocalSearchCompletion) {
        searchFocused = false
        isResolvingPlace = true
        Task {
            defer { isResolvingPlace = false }
            guard let item = await search.resolve(completion) else {
                app.lastError = L10n.t("Place not found")
                return
            }
            place(at: item.placemark.coordinate, title: completion.title)
        }
    }

    // MARK: Bottom bar

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 12) {
            TextField(L10n.t("Name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)

            Picker(L10n.t("Bind card"), selection: $cardId) {
                Text(L10n.t("Select card…")).tag(UUID?.none)
                ForEach(store.cards) { card in
                    Text(card.name).tag(UUID?.some(card.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)

            if stage == .radius {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let centre {
                Label(placeTitle ?? String(format: "%.5f, %.5f", centre.latitude, centre.longitude),
                      systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var radiusText: String {
        radius > 0 ? String(format: "%.0f m", radius) : L10n.t("Fence off")
    }

    private var canSave: Bool {
        cardId != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && centre != nil
    }

    // MARK: Actions

    private func prefill() {
        guard let region else {
            // Brand-new fence: open on the phone's position, not the world.
            app.geofence.requestCurrentLocation { coordinate in
                guard centre == nil, let coordinate else { return }
                recentreOn(coordinate, meters: 600)
            }
            return
        }
        name = region.name
        cardId = region.cardId
        radius = region.radius
        centre = region.coordinate
        recentreOn(region.coordinate, meters: max(600, region.radius * 4))
    }

    /// Confirm only moves to the next stage now; the point itself was chosen
    /// the moment the map moved under the crosshair.
    private func confirmCrosshair() {
        if centre == nil {
            place(at: (mapRegion ?? camera).center, title: nil)
        }
        guard let centre else { return }
        withAnimation(.snappy) { stage = .radius }
        searchFocused = false
        recentreOn(centre, meters: max(600, radius * 3.2))
    }

    /// The crosshair is welded to the screen centre, so whatever the user
    /// drags underneath it *is* the chosen point — no extra tap needed.
    private func centreUnderCrosshair(_ coordinate: CLLocationCoordinate2D) {
        if let old = centre {
            let moved = CLLocation(latitude: old.latitude, longitude: old.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude,
                                           longitude: coordinate.longitude))
            if moved > 2 { placeTitle = nil }   // the name no longer matches
        }
        centre = coordinate
    }

    private func place(at coordinate: CLLocationCoordinate2D, title: String?) {
        searchFocused = false
        placeTitle = title
        centre = coordinate
        let near = mapRegion.map {
            CLLocation(latitude: $0.center.latitude, longitude: $0.center.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        // Already in view: keep the zoom, so panning does not fight the user.
        guard near.map({ $0 > 40 }) ?? true else { return }
        recentreOn(coordinate, meters: 600)
    }

    private func recentreOn(_ coordinate: CLLocationCoordinate2D, meters: Double) {
        camera = MKCoordinateRegion(center: coordinate,
                                    latitudinalMeters: meters,
                                    longitudinalMeters: meters)
        centreRequest += 1
    }

    private func jumpToTypedPlace() async {
        guard let item = await search.resolve() else {
            app.lastError = L10n.t("Place not found")
            return
        }
        place(at: item.placemark.coordinate, title: item.name)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let cardId, let centre else { return }
        if var existing = region {
            existing.name = trimmed
            existing.cardId = cardId
            existing.radius = radius
            existing.centerLatitude = centre.latitude
            existing.centerLongitude = centre.longitude
            GeoRegionStore.update(existing)
        } else {
            GeoRegionStore.add(GeoRegion(name: trimmed,
                                         cardId: cardId,
                                         centerLatitude: centre.latitude,
                                         centerLongitude: centre.longitude,
                                         radius: radius))
        }
        onSaved()
        dismiss()
    }
}