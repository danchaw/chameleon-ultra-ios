import SwiftUI
import UIKit

/// Connected dashboard (port of `gui/page/home.dart`).
struct HomeDashboardView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.themeAccent) private var accent
    @State private var showEmulatorSettings = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        LGMorphScope {
            List {
                heroSection
                slotsSection
                fenceSection
                moreSection
            }
            .navigationTitle(L10n.t("Device"))
            .navigationBarTitleDisplayMode(.large)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Back/status capsule at the far left. NO hand-built glass
                // here: the bar (iOS 26) draws ONE system capsule around the
                // label — our own lgChip on top used to read as "two layers".
                Button {
                    app.showDeviceList = true
                } label: {
                    principalChipLabel
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                // One system capsule, two segments — let the bar own the
                // spacing instead of a hand-tuned HStack, so the rhythm
                // matches every other toolbar in the app.
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(accent)
                }
                Button {
                    app.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(accent)
                }
            }
        }
        .sheet(isPresented: $showEmulatorSettings) {
            EmulatorSettingsSheet()
        }
        .alert(L10n.t("Rename device"), isPresented: $showRenameAlert) {
            TextField(L10n.t("Device name"), text: $renameText)
            Button(L10n.t("Save")) { app.setDeviceNickname(renameText) }
            Button(L10n.t("Cancel"), role: .cancel) { }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .refreshable {
            Haptics.light()
            refresh()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        .onAppear { refresh() }
        .onDisappear { refreshTask?.cancel() }
    }

    /// Electronic fence: entering a mapped region auto-loads its card.
    /// Fence as native rows; its verdict lives in the section footer, always
    /// readable, never inside a hand-built card.
    private var fenceSection: some View {
        Section {
            Toggle(L10n.t("Enable geofence"), isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: GeofenceManager.enabledKey) },
                set: {
                    UserDefaults.standard.set($0, forKey: GeofenceManager.enabledKey)
                    Haptics.selection()
                    // Turning the fence on is user intent — the probe must not
                    // be swallowed by the 30 s trigger dedupe.
                    app.geofence.refreshMonitoring(force: $0)
                }
            ))
            if UserDefaults.standard.bool(forKey: GeofenceManager.enabledKey) {
                Toggle(L10n.t("Allow background triggers"), isOn: Binding(
                    get: { app.geofence.hasAlwaysAccess },
                    set: { want in
                        if want {
                            app.geofence.requestAlwaysAuthorization()
                        } else {
                            // iOS cannot revoke Always programmatically — send the
                            // user to the Settings page for this app
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                ))
                NavigationLink {
                    GeoRegionsView()
                } label: {
                    HStack {
                        Text(L10n.t("Manage regions"))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(String(format: L10n.t("%d"), GeoRegionStore.load().count))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(L10n.t("Electronic fence"))
        } footer: {
            HStack(alignment: .top) {
                Text(app.geofence.statusText)
                Spacer(minLength: 8)
                Button(L10n.t("Check now")) {
                    app.geofence.refreshMonitoring(force: true)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
            }
        }
    }

    /// Dot + chevron + name + battery strip for the principal capsule. The
    /// capsule background stays neutral; only the chevron ("back" icon) picks
    /// up the theme tint. Refresh + exit share one other neutral capsule.
    private var principalChipLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.body.weight(.semibold))
                .foregroundStyle(accent)
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text(app.displayDeviceName)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            if let battery = app.battery {
                Text("\(battery.percent)%")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lgNumber()
                    .appleSpring(value: battery.percent)
            }
        }
    }

    /// Hero: what is connected and how it is doing — one glance, large type.
    private var heroSection: some View {
        Section {
            HStack(spacing: 14) {
                DeviceImageView(device: app.deviceType)
                    .frame(width: 56, height: 72)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.displayDeviceName)
                            .font(.title2.bold())
                            .lineLimit(1)
                        Button {
                            renameText = app.deviceNickname
                            showRenameAlert = true
                        } label: {
                            Image(systemName: "pencil.line")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("Rename device"))
                    }
                    Text("Chameleon \(app.deviceType.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let battery = app.battery {
                        HStack(spacing: 5) {
                            Image(systemName: "battery.75")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text("\(battery.percent)% · \(String(format: "%.2f", Double(battery.voltage) / 1000)) V")
                                .font(.subheadline.weight(.medium).monospacedDigit())
                        }
                        .foregroundStyle(.primary)
                        .appleSpring(value: battery.percent)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)

            infoRow(L10n.t("Firmware"), app.firmwareVersion.map { numToVersionCode($0) } ?? "—")
            if !app.gitCommit.isEmpty {
                infoRow("Git", String(app.gitCommit.prefix(12)))
            }
            infoRow(L10n.t("Chip ID"), app.chipID)
            infoRow(L10n.t("BLE address"), app.bleAddress)
        }
    }

    /// Direct manipulation stays on the home screen: tap a slot, it activates.
    private var slotsSection: some View {
        Section(header: Text(L10n.t("Card slots"))) {
            SlotChanger()
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            NavigationLink { SlotManagerView() } label: {
                Label { Text(L10n.t("Slot manager")).foregroundStyle(.primary) }
                    icon: { Image(systemName: "square.grid.3x3.fill") }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    /// Everything that is not a core job, one level deeper — native rows.
    private var moreSection: some View {
        Section(header: Text(L10n.t("More in the app"))) {
            NavigationLink { ToolsView() } label: {
                Label { Text(L10n.t("Tools")).foregroundStyle(.primary) }
                    icon: { Image(systemName: "wrench.and.screwdriver.fill") }
            }
            Button { showEmulatorSettings = true } label: {
                Label { Text(L10n.t("Emulator")).foregroundStyle(.primary) }
                    icon: { Image(systemName: "waveform.path.ecg.rectangle") }
            }
            NavigationLink { FlashingView(embedded: true) } label: {
                Label { Text(L10n.t("Firmware update")).foregroundStyle(.primary) }
                    icon: { Image(systemName: "arrow.down.doc.fill") }
            }
            NavigationLink { DeviceSettingsView() } label: {
                Label { Text(L10n.t("Device settings")).foregroundStyle(.primary) }
                    icon: { Image(systemName: "gearshape.2.fill") }
            }
        }
    }

    private func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            if let communicator = app.communicator {
                if let battery = try? await communicator.getBatteryCharge() { app.battery = battery }
                try? await app.refreshSlots()
            }
        }
    }
}

// MARK: - Emulator settings (port of the home page emulator section)

struct EmulatorSettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings: EmulatorSettings?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if settings != nil {
                    Section {
                        Toggle(L10n.t("Key detection (mfkey32)"), isOn: detectionBinding)
                        Toggle(L10n.t("Gen1a mode"), isOn: gen1aBinding)
                        Toggle(L10n.t("Gen2 mode"), isOn: gen2Binding)
                        Toggle(L10n.t("Use anti-collision data from block 0"), isOn: antiCollBinding)
                        Picker(L10n.t("Write mode"), selection: writeModeBinding) {
                            ForEach(MifareWriteMode.allCases) { mode in
                                Text(L10n.t(mode.displayName)).tag(mode)
                            }
                        }
                    } header: {
                        Text(L10n.t("Mifare Classic emulator"))
                    } footer: {
                        Text(L10n.t("Write mode explanation"))
                    }
                    Section {
                        Text(L10n.t("Changes are applied to the device immediately."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        HStack { ProgressView(); Text(L10n.t("Loading…")).foregroundStyle(.secondary) }
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.primary) }
                }
            }
            .navigationTitle(L10n.t("Emulator settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text(L10n.t("Done")).foregroundStyle(.primary)
                    }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        guard let communicator = app.communicator else { return }
        do {
            settings = try await communicator.getMf1EmulatorSettings()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var detectionBinding: Binding<Bool> {
        Binding {
            settings?.isDetectionEnabled ?? false
        } set: { newValue in
            settings?.isDetectionEnabled = newValue
            Task { try? await app.communicator?.setMf1DetectionStatus(newValue) }
        }
    }

    private var gen1aBinding: Binding<Bool> {
        Binding {
            settings?.isGen1a ?? false
        } set: { newValue in
            settings?.isGen1a = newValue
            Task { try? await app.communicator?.setMf1Gen1aMode(newValue) }
        }
    }

    private var gen2Binding: Binding<Bool> {
        Binding {
            settings?.isGen2 ?? false
        } set: { newValue in
            settings?.isGen2 = newValue
            Task { try? await app.communicator?.setMf1Gen2Mode(newValue) }
        }
    }

    private var antiCollBinding: Binding<Bool> {
        Binding {
            settings?.isAntiColl ?? false
        } set: { newValue in
            settings?.isAntiColl = newValue
            Task { try? await app.communicator?.setMf1UseFirstBlockColl(newValue) }
        }
    }

    private var writeModeBinding: Binding<MifareWriteMode> {
        Binding {
            settings?.writeMode ?? .normal
        } set: { newValue in
            settings?.writeMode = newValue
            Task { try? await app.communicator?.setMf1WriteMode(newValue) }
        }
    }
}
