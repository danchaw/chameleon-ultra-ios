import SwiftUI

/// Connected dashboard (port of `gui/page/home.dart`).
struct HomeDashboardView: View {
    @EnvironmentObject var app: AppModel
    @State private var showEmulatorSettings = false
    @State private var refreshTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                deviceCard
                GlassCard { SlotChanger() }
                quickActions
            }
            .padding()
        }
        .navigationTitle("Chameleon \(app.deviceType.displayName)")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    app.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showEmulatorSettings) {
            EmulatorSettingsSheet()
        }
        .onAppear { refresh() }
        .onDisappear { refreshTask?.cancel() }
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
                            Text(app.deviceName)
                                .font(.headline)
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

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            NavigationLink {
                SlotManagerView()
            } label: {
                actionTile(L10n.t("Slot manager"), "square.grid.3x3.fill")
            }
            NavigationLink {
                ToolsView()
            } label: {
                actionTile(L10n.t("Tools"), "wrench.and.screwdriver.fill")
            }
            Button {
                showEmulatorSettings = true
            } label: {
                actionTile(L10n.t("Emulator"), "waveform.path.ecg.rectangle")
            }
            NavigationLink {
                FlashingView(embedded: true)
            } label: {
                actionTile(L10n.t("Firmware update"), "arrow.down.doc.fill")
            }
        }
        .buttonStyle(.plain)
    }

    private func actionTile(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    Section(L10n.t("Mifare Classic emulator")) {
                        Toggle(L10n.t("Key detection (mfkey32)"), isOn: detectionBinding)
                        Toggle(L10n.t("Gen1a mode"), isOn: gen1aBinding)
                        Toggle(L10n.t("Gen2 mode"), isOn: gen2Binding)
                        Toggle(L10n.t("Use anti-collision data from block 0"), isOn: antiCollBinding)
                        Picker(L10n.t("Write mode"), selection: writeModeBinding) {
                            ForEach(MifareWriteMode.allCases) { mode in
                                Text(L10n.t(mode.displayName)).tag(mode)
                            }
                        }
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
