import SwiftUI

/// BLE scan & connect screen (port of `gui/page/connect.dart`).
struct ConnectView: View {
    @EnvironmentObject var app: AppModel
    @State private var isScanning = false

    private var ble: BLEManager { app.ble }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner(message: $app.lastError)

                GlassCard {
                    HStack(spacing: 16) {
                        DeviceImageView(device: .ultra)
                            .frame(height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Chameleon Ultra")
                                .font(.title3.bold())
                            Text("NFC & RFID research tool")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }

                HStack {
                    Text("Bluetooth devices")
                        .font(.headline)
                    Spacer()
                    Button {
                        toggleScan()
                    } label: {
                        Label(isScanning ? "Stop" : "Scan", systemImage: isScanning ? "stop.circle.fill" : "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!ble.bluetoothReady)
                }

                if !ble.bluetoothReady {
                    GlassCard {
                        Label("Bluetooth is off or unavailable", systemImage: "bluetooth.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                if isScanning && ble.devices.isEmpty {
                    GlassCard {
                        HStack {
                            ProgressView()
                            Text("Searching for Chameleon devices…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                ForEach(sortedDevices) { device in
                    Button {
                        connect(device)
                    } label: {
                        GlassCard {
                            HStack(spacing: 14) {
                                DeviceImageView(device: device.deviceType)
                                    .frame(height: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 8) {
                                        Text(device.displayName)
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
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                if ble.devices.isEmpty && !isScanning {
                    GlassCard {
                        VStack(spacing: 8) {
                            Label("No devices yet", systemImage: "tray")
                                .foregroundStyle(.secondary)
                            Text("Power on your Chameleon and tap Scan. The device advertises as “ChameleonUltra…” (or CU-… in DFU mode).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Connect")
        .onAppear {
            toggleScan()
            // Bluetooth may not be powered on yet – retry once shortly after.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if ble.state == .idle && !isScanning { toggleScan() }
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
        }
    }

    private func connect(_ device: DiscoveredDevice) {
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
