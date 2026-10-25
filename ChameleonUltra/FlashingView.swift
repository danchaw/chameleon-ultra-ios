import SwiftUI
import Combine
import UniformTypeIdentifiers

/// Firmware update via Nordic Secure DFU (port of `gui/page/flashing.dart`).
struct FlashingView: View {
    @EnvironmentObject var app: AppModel
    var embedded = false

    @State private var showPicker = false
    @State private var status: String?
    @State private var error: String?
    @State private var dfuLog: [String] = []
    @State private var logCancellable: AnyCancellable?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner(message: $error)

                GlassCard {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)

                        if app.connectionState == .dfuMode {
                            Text("Device in DFU mode")
                                .font(.headline)
                            Text("Pick the firmware .zip package (contains application.dat and application.bin) from the Chameleon Ultra releases.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            if app.dfuProgress == nil {
                                Button {
                                    showPicker = true
                                } label: {
                                    Label("Select firmware package", systemImage: "folder")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                            } else {
                                ProgressView(value: app.dfuProgress ?? 0)
                                Text("Flashing… \(Int((app.dfuProgress ?? 0) * 100))% — do not lock the phone")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Firmware update")
                                .font(.headline)
                            if let version = app.firmwareVersion {
                                Text("Current firmware: \(numToVersionCode(version))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Text("The device will reboot into DFU mode and reconnect automatically.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            Button(role: .destructive) {
                                enterDFU()
                            } label: {
                                Label("Reboot to DFU mode", systemImage: "exclamationmark.arrow.circlepath")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if let status {
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
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
        .sheet(isPresented: $showPicker) {
            DocumentPicker(contentTypes: [UTType(filenameExtension: "zip") ?? .zip, .data]) { url in
                Task { await flash(package: url) }
            }
        }
    }

    private func enterDFU() {
        Task {
            do {
                status = "Rebooting device to DFU…"
                try await app.communicator?.enterDFUMode()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                app.disconnect()
                app.ble.startScan()
                status = "Scanning for DFU device (CU-…)…"
                // wait for the DFU device to show up, then connect
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if let dfuDevice = app.ble.devices.first(where: { $0.isDFU }) {
                        await app.connect(to: dfuDevice)
                        return
                    }
                }
                error = "DFU device not found"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func flash(package url: URL) async {
        error = nil
        status = "Reading package…"
        do {
            let data = try Data(contentsOf: url)
            let entries = try ZipArchive.extract(data)
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
            try await dfu.flashFirmware(objectType: 0x02, firmware: appBin) { progress in
                Task { @MainActor in app.dfuProgress = progress }
            }

            app.dfuProgress = nil
            status = "Done! The device reboots into the new firmware."
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            app.disconnect()
        } catch {
            app.dfuProgress = nil
            self.error = error.localizedDescription
            status = nil
        }
    }
}
