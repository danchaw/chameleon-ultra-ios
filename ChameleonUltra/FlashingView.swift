import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Firmware update: online check against official GitHub releases with a
/// guided flash flow (download → reboot to DFU → auto-reconnect → flash).
struct FlashingView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var firmware = FirmwareService()
    var embedded = false

    enum BusyPhase: Equatable {
        case idle, downloading, rebooting, scanning, flashing
    }

    @State private var showPicker = false
    @State private var status: String?
    @State private var error: String?
    @State private var dfuLog: [String] = []
    @State private var logCancellable: AnyCancellable?
    @State private var downloadProgress: Double = 0
    @State private var busyPhase: BusyPhase = .idle
    @State private var pendingFirmware: Data?
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner(message: $error)

                if app.connectionState == .dfuMode {
                    dfuCard
                } else if app.isConnected {
                    updateCard
                } else {
                    GlassCard {
                        Label("Connect a Chameleon device first (Home tab).", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                if let status {
                    GlassCard {
                        Label(status, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if busyPhase == .downloading {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Downloading firmware…").font(.headline)
                            ProgressView(value: downloadProgress)
                            Text("\(Int(downloadProgress * 100))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if busyPhase == .rebooting || busyPhase == .scanning {
                    GlassCard {
                        VStack(spacing: 12) {
                            HStack {
                                ProgressView()
                                Text(busyPhase == .rebooting
                                     ? "Rebooting device into DFU mode…"
                                     : "Searching for DFU device (CU-…)…")
                                    .foregroundStyle(.secondary)
                            }
                            Button(role: .destructive) {
                                cancelOperation()
                            } label: {
                                Label("Cancel", systemImage: "xmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if !dfuLog.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("DFU log").font(.headline)
                            ForEach(Array(dfuLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Firmware update")
        .navigationBarTitleDisplayMode(embedded ? .automatic : .inline)
        .task {
            if app.isConnected {
                await firmware.checkForUpdates(device: app.deviceType)
            }
        }
        .onChange(of: app.connectionState) { _, newState in
            if newState == .dfuMode, let zip = pendingFirmware {
                flash(zip)
            }
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(contentTypes: [UTType(filenameExtension: "zip") ?? .zip, .data]) { url in
                Task {
                    if let data = try? Data(contentsOf: url) {
                        busyPhase = .flashing
                        if app.connectionState == .dfuMode {
                            flash(data)
                        } else {
                            rebootAndFlash(zip: data)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Update card (connected, normal mode)

    private var updateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Firmware update").font(.headline)
                        if let version = app.firmwareVersion {
                            Text("Device firmware: v\(numToVersionCode(version))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    DeviceImageView(device: app.deviceType)
                        .frame(height: 72)
                }

                if firmware.checking {
                    HStack {
                        ProgressView()
                        Text("Checking for updates…").foregroundStyle(.secondary)
                    }
                } else if let latest = firmware.latest {
                    let updateAvailable = firmware.isUpdateAvailable(currentVersion: app.firmwareVersion ?? 0)

                    HStack(spacing: 8) {
                        Image(systemName: updateAvailable ? "sparkles" : "checkmark.seal.fill")
                            .foregroundStyle(updateAvailable ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            if updateAvailable {
                                Text("Firmware v\(latest.versionString) available")
                                    .font(.subheadline.weight(.semibold))
                            } else {
                                Text("Up to date (latest: v\(latest.versionString))")
                                    .font(.subheadline.weight(.semibold))
                            }
                            if latest.isPrerelease {
                                Text("dev channel")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.orange.opacity(0.2), in: Capsule())
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if updateAvailable && !latest.shortNotes.isEmpty {
                        Text(latest.shortNotes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }

                    if updateAvailable {
                        Button {
                            guidedUpdate(latest)
                        } label: {
                            Label("Download and flash v\(latest.versionString)", systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busyPhase != .idle)
                    } else {
                        Button {
                            guidedUpdate(latest)
                        } label: {
                            Label("Re-flash v\(latest.versionString)", systemImage: "arrow.triangle.2.circlepath")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(busyPhase != .idle)
                    }

                    Button {
                        if let url = URL(string: "https://github.com/RfidResearchGroup/ChameleonUltra/releases") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("View release page", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else if let checkError = firmware.checkError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(checkError, systemImage: "wifi.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            Task { await firmware.checkForUpdates(device: app.deviceType) }
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                Button {
                    showPicker = true
                } label: {
                    Label("Select firmware .zip manually", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(busyPhase != .idle)
            }
        }
    }

    // MARK: - DFU card (device already in DFU mode)

    private var dfuCard: some View {
        GlassCard {
            VStack(spacing: 12) {
                DeviceImageView(device: app.deviceType)
                    .frame(height: 110)
                Text("Device in DFU mode")
                    .font(.headline)
                if app.dfuProgress == nil {
                    if pendingFirmware != nil {
                        HStack { ProgressView(); Text("Preparing…").foregroundStyle(.secondary) }
                    } else {
                        Text("Pick the firmware .zip package (application.dat + application.bin), e.g. ultra-dfu-app.zip from the official releases.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            showPicker = true
                        } label: {
                            Label("Select firmware package", systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ProgressView(value: app.dfuProgress ?? 0)
                    Text("Flashing… \(Int((app.dfuProgress ?? 0) * 100))% — keep the app in the foreground")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Guided flow

    private func guidedUpdate(_ release: FirmwareRelease) {
        error = nil
        status = nil
        busyPhase = .downloading
        operationTask = Task {
            do {
                let zip = try await firmware.download(release) { fraction in
                    downloadProgress = fraction
                }
                pendingFirmware = zip
                busyPhase = .rebooting
                try await app.communicator?.enterDFUMode()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                app.disconnect()
                busyPhase = .scanning
                app.ble.startScan()

                for _ in 0..<30 {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if let dfuDevice = app.ble.devices.first(where: { $0.isDFU }) {
                        await app.connect(to: dfuDevice)   // → .dfuMode → onChange flashes
                        return
                    }
                }
                busyPhase = .idle
                pendingFirmware = nil
                error = "Timed out waiting for the DFU device. Power-cycle the Chameleon and try again."
            } catch is CancellationError {
                // cancelled by user — state cleaned in cancelOperation()
            } catch let urlError as URLError where urlError.code == .cancelled {
                // download cancelled by user
            } catch {
                busyPhase = .idle
                pendingFirmware = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func rebootAndFlash(zip: Data) {
        pendingFirmware = zip
        busyPhase = .rebooting
        operationTask = Task {
            do {
                try await app.communicator?.enterDFUMode()
                try await Task.sleep(nanoseconds: 2_000_000_000)
                app.disconnect()
                busyPhase = .scanning
                app.ble.startScan()
                for _ in 0..<30 {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    if let dfuDevice = app.ble.devices.first(where: { $0.isDFU }) {
                        await app.connect(to: dfuDevice)
                        return
                    }
                }
                busyPhase = .idle
                pendingFirmware = nil
                error = "Timed out waiting for the DFU device."
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                busyPhase = .idle
                pendingFirmware = nil
                self.error = error.localizedDescription
            }
        }
    }

    private func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        app.ble.stopScan()
        app.cancelConnection()
        pendingFirmware = nil
        busyPhase = .idle
        status = "Update cancelled"
    }

    private func flash(_ zip: Data) {
        busyPhase = .flashing
        error = nil
        status = nil
        Task { @MainActor in
            do {
                let entries = try ZipArchive.extract(zip)
                guard let appDat = entries.first(where: { $0.name == "application.dat" })?.data,
                      let appBin = entries.first(where: { $0.name == "application.bin" })?.data else {
                    throw ChameleonError.invalidResponse("application.dat / application.bin not found in package")
                }

                let dfu = DFUCommunicator(ble: app.ble)
                logCancellable = dfu.$log.receive(on: DispatchQueue.main).sink { lines in
                    dfuLog = lines
                }

                status = "Sending init packet…"
                app.dfuProgress = 0
                try await dfu.flashFirmware(objectType: 0x01, firmware: appDat) { _ in }

                status = "Flashing firmware…"
                try await dfu.flashFirmware(objectType: 0x02, firmware: appBin) { fraction in
                    Task { @MainActor in app.dfuProgress = fraction }
                }

                app.dfuProgress = nil
                pendingFirmware = nil
                busyPhase = .idle
                status = "Done! Firmware updated — the device is rebooting."
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                app.disconnect()
            } catch {
                app.dfuProgress = nil
                busyPhase = .idle
                self.error = error.localizedDescription
                status = nil
            }
        }
    }
}
