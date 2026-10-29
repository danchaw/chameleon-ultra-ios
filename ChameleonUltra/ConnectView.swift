import SwiftUI

/// BLE scan & connect screen (port of `gui/page/connect.dart`).
struct ConnectView: View {
    @EnvironmentObject var app: AppModel
    @State private var isScanning = false
    @AppStorage("autoScan") private var autoScan = false
    @AppStorage("autoConnectFirst") private var autoConnectFirst = false

    private var ble: BLEManager { app.ble }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if app.isConnected {
                    // Reached via the dashboard back button: stay connected,
                    // one tap re-enters the device page.
                    GlassCard {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayDeviceName)
                                    .font(.headline)
                                Text(L10n.t("Connected"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L10n.t("Enter device")) {
                                app.showDeviceList = false
                            }
                            .lgTile(prominent: true)
                        }
                    }
                }

                GlassCard {
                    VStack(spacing: 6) {
                        Text("Chameleon Ultra")
                            .font(.title3.bold())
                        Text(L10n.t("NFC & RFID research tool"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }

                HStack {
                    Text(L10n.t("Bluetooth devices"))
                        .font(.headline)
                    Spacer()
                    Button {
                        toggleScan()
                    } label: {
                        Label(isScanning ? L10n.t("Stop") : L10n.t("Scan"), systemImage: isScanning ? "stop.circle.fill" : "magnifyingglass")
                    }
                    .lgTile()
                    .disabled(!ble.bluetoothReady)
                }

                if !ble.bluetoothReady {
                    GlassCard {
                        Label(L10n.t("Bluetooth is off or unavailable"), systemImage: "bluetooth.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                if isScanning && ble.devices.isEmpty {
                    GlassCard {
                        HStack {
                            ProgressView()
                            Text(L10n.t("Searching for Chameleon devices…"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(sortedDevices) { device in
                    Button {
                        connect(device)
                    } label: {
                        HStack(spacing: 14) {
                            DeviceImageView(device: device.deviceType)
                                .frame(height: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(app.displayName(for: device))
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    if device.isDFU {
                                        Text("DFU")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(.orange.opacity(0.25), in: Capsule())
                                            .foregroundStyle(.orange)
                                    }
                                }
                                Text(device.deviceType == .ultra ? "Chameleon Ultra" : "Chameleon Lite")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: signalIcon(device.rssi))
                                .foregroundStyle(.tint)
                                .lgIcon()
                        }
                    }
                    .lgTile()
                }

                if ble.devices.isEmpty && !isScanning {
                    EmptyState(icon: "antenna.radiowaves.left.and.right",
                               title: L10n.t("No devices yet"),
                               subtitle: L10n.t("Power on your Chameleon and tap Scan. The device advertises as “ChameleonUltra…” (or CU-… in DFU mode)."),
                               actionTitle: L10n.t("Scan")) { toggleScan() }
                }
            }
            .padding()
        }
        .refreshable {
            if !isScanning { toggleScan() }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if isScanning { toggleScan() }
        }
        .navigationTitle(L10n.t("Connect"))
        .onAppear {
            if autoScan {
                toggleScan()
            }
            // Bluetooth may not be powered on yet – retry once shortly after.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if autoScan && ble.state == .idle && !isScanning { toggleScan() }
            }
        }
        .onDisappear { ble.stopScan() }
    }

    private var sortedDevices: [DiscoveredDevice] {
        ble.devices.sorted { $0.rssi > $1.rssi }
    }

    private func toggleScan() {
        if isScanning {
            ble.stopScan()
            isScanning = false
        } else {
            ble.startScan()
            isScanning = true
            // stop scanning automatically after 10s like the original 2s window, but longer for reliability
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                await MainActor.run {
                    if isScanning {
                        ble.stopScan()
                        isScanning = false
                    }
                }
            }
            if autoConnectFirst {
                autoConnectToFirst()
            }
        }
    }

    /// Watch the scan results and connect to the first Chameleon found
    /// (original: auto_connect_first_device). Once per scan session.
    private func autoConnectToFirst() {
        Task { @MainActor in
            for _ in 0..<20 {
                if !isScanning { return }
                if let first = ble.devices.first(where: { !$0.isDFU }) {
                    connect(first)
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func connect(_ device: DiscoveredDevice) {
        // already connected to this one (came back via the dashboard): just re-enter
        if app.connectionState == .connected, app.deviceName == device.displayName {
            app.showDeviceList = false
            return
        }
        ble.stopScan()
        isScanning = false
        Task { await app.connect(to: device) }
    }

    private func signalIcon(_ rssi: Int) -> String {
        switch rssi {
        case ..<(-90): return "wifi.exclamationmark"
        case ..<(-70): return "wifi.1"
        case ..<(-55): return "wifi.2"
        default: return "wifi.3"
        }
    }
}
