import SwiftUI
import UIKit

/// Connected dashboard (port of `gui/page/home.dart`).
struct HomeDashboardView: View {
    @EnvironmentObject var app: AppModel
    @State private var showEmulatorSettings = false
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        LGMorphScope {
            ScrollView {
                VStack(spacing: 16) {
                    deviceCard
                    SlotChanger()
                        .lgCard()
                    geofenceCard
                        .lgCard()
                    quickActions
                }
                .padding()
            }
            .navigationTitle(L10n.t("Device"))
            .navigationBarTitleDisplayMode(.large)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Back to the device list; the connection stays alive.
                Button {
                    app.showDeviceList = true
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .principal) {
                statusPill
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    app.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
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
        .refreshable {
            Haptics.light()
            refresh()
            try? await Task.sleep(nanoseconds: 600_000_000)
        }
        .onAppear { refresh() }
        .onDisappear { refreshTask?.cancel() }
    }

    /// Electronic fence: entering a mapped region auto-loads its card.
    private var geofenceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.tint)
                Text(L10n.t("Electronic fence"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Toggle(L10n.t("Enable geofence"), isOn: Binding(
                get: { UserDefaults.standard.bool(forKey: GeofenceManager.enabledKey) },
                set: {
                    UserDefaults.standard.set($0, forKey: GeofenceManager.enabledKey)
                    // Turning the fence on is user intent 鈥?the probe must not
                    // be swallowed by the 30 s trigger dedupe.
                    app.geofence.refreshMonitoring(force: $0)
                }
            ))
            Toggle(L10n.t("Allow background triggers"), isOn: Binding(
                get: { app.geofence.hasAlwaysAccess },
                set: { want in
                    if want {
                        app.geofence.requestAlwaysAuthorization()
                    } else {
                        // iOS cannot revoke Always programmatically 鈥?send the
                        // user to the Settings page for this app
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            ))
            HStack(alignment: .top) {
                Text(app.geofence.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    app.geofence.refreshMonitoring(force: true)
                } label: {
                    Label(L10n.t("Check now"), systemImage: "location.viewpoint")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            // Full-width row: a 44 pt tap target beats a tiny capsule, and the
            // count tells you at a glance how many fences exist.
            NavigationLink {
                GeoRegionsView()
            } label: {
                HStack(spacing: 8) {
                    Text(L10n.t("Manage regions"))
                        .font(.subheadline.weight(.medium))
                    Text(String(format: L10n.t("%d"), GeoRegionStore.load().count))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var deviceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    DeviceImageView(device: app.deviceType)
                        .frame(height: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "battery")
                                .foregroundStyle(.tint)
                            Text(app.displayDeviceName)
                                .font(.headline)
                            Button {
                                renameText = app.deviceNickname
                                showRenameAlert = true
                            } label: {
                                Image(systemName: "pencil.line")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.t("Rename device"))
                        }
                        Text("Chameleon \(app.deviceType.displayName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let battery = app.battery {
                            Text("\(battery.percent)% · \(String(format: "%.2f", Double(battery.voltage) / 1000)) V")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer()
                }

                Divider()

                infoRow(L10n.t("Firmware"), app.firmwareVersion.map { numToVersionCode($0) } ?? "—")
                if !app.gitCommit.isEmpty {
                    infoRow("Git", String(app.gitCommit.prefix(12)))
                }
                infoRow(L10n.t("Chip ID"), app.chipID)
                infoRow(L10n.t("BLE address"), app.bleAddress)
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

    /// Fixed (non-lazy) grid so the shared GlassEffectContainer can morph
    /// the highlighted tile between positions.
    private var quickActions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                NavigationLink { SlotManagerView() } label: {
                    actionTile(L10n.t("Slot manager"), "square.grid.3x3.fill")
                }
                NavigationLink { ToolsView() } label: {
                    actionTile(L10n.t("Tools"), "wrench.and.screwdriver.fill")
                }
                Button { showEmulatorSettings = true } label: {
                    actionTile(L10n.t("Emulator"), "waveform.path.ecg.rectangle")
                }
            }
            HStack(spacing: 12) {
                NavigationLink { FlashingView(embedded: true) } label: {
                    actionTile(L10n.t("Firmware update"), "arrow.down.doc.fill")
                }
                NavigationLink { DeviceSettingsView() } label: {
                    actionTile(L10n.t("Device settings"), "gearshape.2.fill")
                }
                NavigationLink { ReadCardView() } label: {
                    actionTile(L10n.t("Read"), "creditcard.viewfinder", prominent: true)
                }
                .disabled(!app.isConnected)
            }
        }
    }

    private func actionTile(_ title: String, _ icon: String, prominent: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .lgIcon()
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
        }
        .lgTile(prominent: prominent)
    }

    /// Compact live status shown in the navigation bar; absorbs into the
    /// bar chrome on scroll (iOS 26 large-title behaviour).
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text(app.displayDeviceName)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if let battery = app.battery {
                Text("\(battery.percent)%")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)
                    .lgNumber()
                    .animation(.snappy, value: battery.percent)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .lgChip()
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
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(L10n.t("Emulator settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
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
