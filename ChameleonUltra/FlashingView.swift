import SwiftUI
import UIKit
import Combine
import UniformTypeIdentifiers

/// Firmware update: online check against official GitHub releases, package
/// verification, and an explicit user-confirmed flash (regular or forced).
struct FlashingView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var firmware = FirmwareService()
    var embedded = false

    enum BusyPhase: Equatable {
        case idle, downloading, verifying, rebooting, scanning, flashing
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

    // staged firmware: verified (or not) and waiting for the user's decision
    @State private var stagedFirmware: Data?
    @State private var stagedName = ""
    @State private var validation: FirmwareValidationReport?

    // confirmation before any flash
    @State private var showFlashConfirm = false
    @State private var forceArmed = false

    // firmware library management
    @State private var pendingDeleteFirmware: FirmwarePackage?
    @State private var confirmClearFirmware = false

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
                        Label(L10n.t("Connect a Chameleon device first (Home tab)."), systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                    }
                }

                if let validation {
                    validationCard(validation)
                }

                if !app.firmwareStore.packages.isEmpty {
                    firmwareLibraryCard
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
                            Text(L10n.t("Downloading firmware…")).font(.headline)
                            SegmentedProgress(progress: downloadProgress, count: 18)
                        }
                    }
                }

                if busyPhase == .verifying {
                    GlassCard {
                        HStack {
                            ProgressView()
                            Text(L10n.t("Verifying firmware package…")).foregroundStyle(.secondary)
                        }
                    }
                }

                if busyPhase == .rebooting || busyPhase == .scanning {
                    GlassCard {
                        VStack(spacing: 12) {
                            HStack {
                                ProgressView()
                                Text(busyPhase == .rebooting
                                     ? L10n.t("Rebooting device into DFU mode…")
                                     : L10n.t("Searching for DFU device (CU-…)…"))
                                    .foregroundStyle(.secondary)
                            }
                            Button(role: .destructive) {
                                cancelOperation()
                            } label: {
                                Label(L10n.t("Cancel"), systemImage: "xmark.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                if !dfuLog.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.t("DFU log")).font(.headline)
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
        .navigationTitle(L10n.t("Firmware update"))
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
        .alert(L10n.t("Confirm firmware flash"), isPresented: $showFlashConfirm) {
            Button(L10n.t("Flash"), role: .destructive) {
                proceedConfirmedFlash()
            }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text(forceArmed
                 ? L10n.t("This package FAILED verification. Force flashing will very likely damage your device. Really continue?")
                 : L10n.t("Flashing the wrong firmware can permanently brick your Chameleon. Continue?"))
        }
        .sheet(isPresented: $showPicker) {
            DocumentPicker(contentTypes: [UTType(filenameExtension: "zip") ?? .zip, .data]) { url in
                loadLocalFirmware(url: url)
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
                        Text(L10n.t("Firmware update")).font(.headline)
                        if let version = app.firmwareVersion {
                            Text("\(L10n.t("Device firmware")): v\(numToVersionCode(version))")
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
                        Text(L10n.t("Checking for updates…")).foregroundStyle(.secondary)
                    }
                } else if let latest = firmware.latest {
                    let updateAvailable = firmware.isUpdateAvailable(currentVersion: app.firmwareVersion ?? 0)

                    HStack(spacing: 8) {
                        Image(systemName: updateAvailable ? "sparkles" : "checkmark.seal.fill")
                            .foregroundStyle(updateAvailable ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            if updateAvailable {
                                Text(L10n.tf("Firmware v%@ available", latest.versionString))
                                    .font(.subheadline.weight(.semibold))
                            } else {
                                Text(L10n.tf("Up to date (latest: v%@)", latest.versionString))
                                    .font(.subheadline.weight(.semibold))
                            }
                            if latest.isPrerelease {
                                Text(L10n.t("dev channel"))
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

                    // Download + verify only. Flashing happens after the user confirms.
                    if updateAvailable {
                        Button {
                            guidedUpdate(latest)
                        } label: {
                            Label(L10n.tf("Download and flash v%@", latest.versionString),
                                  systemImage: "arrow.down.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busyPhase != .idle)
                    } else {
                        Button {
                            guidedUpdate(latest)
                        } label: {
                            Label(L10n.tf("Re-flash v%@", latest.versionString),
                                  systemImage: "arrow.triangle.2.circlepath")
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
                        Label(L10n.t("View release page"), systemImage: "safari")
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
                            Label(L10n.t("Retry"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Divider()

                Button {
                    rebootToDFU(zip: nil)
                } label: {
                    Label(L10n.t("Enter DFU mode"), systemImage: "exclamationmark.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // unified accent color
                .disabled(busyPhase != .idle)

                Button {
                    showPicker = true
                } label: {
                    Label(L10n.t("Flash local firmware (.zip)…"), systemImage: "folder")
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
                Text(L10n.t("Device in DFU mode"))
                    .font(.headline)
                if app.dfuProgress == nil {
                    if pendingFirmware != nil {
                        HStack { ProgressView(); Text(L10n.t("Preparing…")).foregroundStyle(.secondary) }
                    } else if stagedFirmware != nil {
                        // decision buttons live in the validation card below
                        Text(L10n.t("Firmware package loaded — choose an action below."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            showPicker = true
                        } label: {
                            Label(L10n.t("Select firmware package"), systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    SegmentedProgress(progress: app.dfuProgress ?? 0)
                        .padding(.top, 4)
                    Text("\(L10n.t("Flashing…")) — \(L10n.t("keep the app in the foreground"))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Firmware library (downloaded packages)

    private var firmwareLibraryCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.t("Downloaded firmware"), systemImage: "externaldrive.fill")
                        .font(.headline)
                    Spacer()
                    Button(role: .destructive) {
                        confirmClearFirmware = true
                    } label: {
                        Label(L10n.t("Clear all"), systemImage: "trash")
                            .font(.footnote)
                    }
                    .buttonStyle(.plain)
                    .alert(L10n.t("Clear all downloaded firmware?"), isPresented: $confirmClearFirmware) {
                        Button(L10n.t("Clear all"), role: .destructive) {
                            app.firmwareStore.deleteAll()
                            if stagedFirmware != nil {
                                stagedFirmware = nil
                                validation = nil
                            }
                        }
                        Button(L10n.t("Cancel"), role: .cancel) {}
                    } message: {
                        Text(L10n.t("This cannot be undone."))
                    }
                }

                ForEach(app.firmwareStore.packages) { package in
                    Button {
                        stageFromLibrary(package)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.zipper")
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(package.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("\(ByteCountFormatter.string(fromByteCount: Int64(package.sizeBytes), countStyle: .file)) · \(package.downloadedAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                pendingDeleteFirmware = package
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .alert(L10n.t("Delete firmware package?"), isPresented: deleteFirmwareShown) {
                Button(L10n.t("Delete"), role: .destructive) {
                    if let package = pendingDeleteFirmware {
                        app.firmwareStore.delete(package)
                        if stagedFirmware != nil && validation?.sourceName == package.title {
                            stagedFirmware = nil
                            validation = nil
                        }
                    }
                    pendingDeleteFirmware = nil
                }
                Button(L10n.t("Cancel"), role: .cancel) { pendingDeleteFirmware = nil }
            } message: {
                Text(L10n.t("This cannot be undone."))
            }
        }
    }

    private var deleteFirmwareShown: Binding<Bool> {
        Binding(get: { pendingDeleteFirmware != nil }, set: { if !$0 { pendingDeleteFirmware = nil } })
    }

    /// Load a library package back into the staging flow (verify again, then flash).
    private func stageFromLibrary(_ package: FirmwarePackage) {
        guard let data = app.firmwareStore.data(for: package) else {
            error = L10n.t("Download failed")
            return
        }
        busyPhase = .verifying
        let report = FirmwareValidator.validate(zip: data, sourceName: package.title)
        withAnimation {
            validation = report
            stagedFirmware = data
            stagedName = package.title
            busyPhase = .idle
        }
    }

    // MARK: - Validation report card (user decides what happens next)

    private func validationCard(_ report: FirmwareValidationReport) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: report.isValid ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .foregroundStyle(report.isValid ? Color.green : Color.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.isValid ? L10n.t("Firmware package verified") : L10n.t("Firmware package invalid"))
                            .font(.headline)
                        Text(report.sourceName.isEmpty
                             ? "\(L10n.t("downloaded package")) · \(report.zipBytes) bytes"
                             : "\(report.sourceName) · \(report.zipBytes) bytes")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if report.isValid {
                    checkRow(true, signedRowText(report))
                    if let digestOK = report.downloadDigestValid {
                        checkRow(digestOK, L10n.t("Download SHA-256 matches GitHub asset digest"))
                    }
                    checkRow(report.zipCrcValid, "\(L10n.t("Zip entries CRC32 verified")) (\(report.entriesFound.count) \(L10n.t("files")))")
                    checkRow(true, "\(L10n.t("Firmware hash matches application.bin")) (\(report.hashTypeName))")
                    if let sizeOK = report.sizeMatches {
                        checkRow(sizeOK, "\(L10n.t("Manifest app size matches bin size")) (\(report.declaredAppSize ?? 0) == \(report.actualBinSize))")
                    }

                    Button {
                        forceArmed = false
                        showFlashConfirm = true
                    } label: {
                        Label(L10n.t("Flash this firmware"), systemImage: "bolt.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busyPhase != .idle || stagedFirmware == nil)
                } else {
                    if let fatal = report.fatal {
                        checkRow(false, fatal)
                    }
                    if report.downloadDigestValid == false {
                        checkRow(false, L10n.t("Download SHA-256 does NOT match GitHub digest — download corrupted"))
                    }
                    if !report.zipCrcValid {
                        checkRow(false, L10n.t("Zip CRC check failed — archive corrupted"))
                    }
                    if !report.hasApplicationDat || !report.hasApplicationBin {
                        let names = report.entriesFound.joined(separator: ", ")
                        checkRow(false, "\(L10n.t("application.dat / application.bin missing")) (\(names))")
                    }
                    if !report.signedPackage {
                        checkRow(false, L10n.t("Package isn't signed"))
                    }
                    if report.hasApplicationBin && !report.firmwareHashMatches && !report.hashTypeName.isEmpty {
                        checkRow(false, "\(L10n.t("Firmware hash mismatch — wrong or damaged file")) (\(report.hashTypeName))")
                    }
                    if report.sizeMatches == false {
                        checkRow(false, "\(L10n.t("Manifest app size does not match bin size")) (\(report.declaredAppSize ?? 0) != \(report.actualBinSize))")
                    }

                    Divider()

                    Label(L10n.t("Force flash (unsafe)"), systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                    Button(role: .destructive) {
                        forceArmed = true
                        showFlashConfirm = true
                    } label: {
                        Label(L10n.t("Force flash (unsafe)"), systemImage: "bolt.trianglebadge.exclamationmark.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(busyPhase != .idle || stagedFirmware == nil)
                }
            }
        }
    }

    private func signedRowText(_ report: FirmwareValidationReport) -> String {
        if let fwVersion = report.fwVersion {
            return "\(L10n.t("Signed dfu-cc package")), \(L10n.t("firmware version")) \(fwVersion)"
        }
        return L10n.t("Signed dfu-cc package")
    }

    private func checkRow(_ ok: Bool, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
                .font(.footnote)
            Text(text)
                .font(.footnote)
                .foregroundStyle(ok ? Color.primary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Local firmware pick (staged, never flashed directly)

    private func loadLocalFirmware(url: URL) {
        error = nil
        status = nil
        validation = nil
        stagedFirmware = nil
        pendingFirmware = nil
        do {
            let data = try Data(contentsOf: url)
            stagedName = url.lastPathComponent
            busyPhase = .verifying
            let report = FirmwareValidator.validate(zip: data, sourceName: url.lastPathComponent)
            withAnimation {
                validation = report
                stagedFirmware = data
                busyPhase = .idle
            }
        } catch {
            busyPhase = .idle
            self.error = error.localizedDescription
        }
    }

    // MARK: - Guided flow (download + verify only, then stop)

    private func guidedUpdate(_ release: FirmwareRelease) {
        error = nil
        status = nil
        validation = nil
        stagedFirmware = nil
        busyPhase = .downloading
        operationTask = Task {
            do {
                let zip = try await firmware.download(release) { fraction in
                    downloadProgress = fraction
                }

                busyPhase = .verifying
                let report = FirmwareValidator.validate(zip: zip,
                                                        expectedDigestSHA256: release.digestSHA256,
                                                        sourceName: "\(release.tagName).zip")
                withAnimation {
                    validation = report
                    stagedFirmware = zip
                    stagedName = "\(release.tagName).zip"
                    busyPhase = .idle
                }
                // keep the verified package for offline re-flashing
                app.firmwareStore.save(zip: zip, title: "\(release.tagName).zip")
                // Stop here — the user decides (and confirms) before anything is flashed.
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                busyPhase = .idle
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Confirmed flash

    private func proceedConfirmedFlash() {
        guard let zip = stagedFirmware else { return }
        if app.connectionState == .dfuMode {
            flash(zip)
        } else {
            rebootToDFU(zip: zip)
        }
    }

    /// Reboot the device into DFU mode and reconnect. `zip == nil` means the
    /// user just wants to enter DFU (flashes only when firmware is staged).
    private func rebootToDFU(zip: Data?) {
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
                        await app.connect(to: dfuDevice)   // → .dfuMode → onChange flashes if staged
                        return
                    }
                }
                busyPhase = .idle
                pendingFirmware = nil
                error = L10n.t("Timed out waiting for the DFU device. Power-cycle the Chameleon and try again.")
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
        status = L10n.t("Update cancelled")
    }

    private func flash(_ zip: Data) {
        busyPhase = .flashing
        error = nil
        status = nil
        Task { @MainActor in
            do {
                let entries = try ZipArchive.extract(zip)
                guard let rawDat = entries.first(where: { $0.name == "application.dat" })?.data,
                      let rawBin = entries.first(where: { $0.name == "application.bin" })?.data else {
                    throw ChameleonError.invalidResponse("application.dat / application.bin not found in package")
                }
                // zip-extracted payloads are Data slices — normalize to zero-based
                let appDat = Data(rawDat)
                let appBin = Data(rawBin)

                let dfu = DFUCommunicator(ble: app.ble)
                logCancellable = dfu.$log.receive(on: DispatchQueue.main).sink { lines in
                    dfuLog = lines
                }

                status = L10n.t("Sending init packet…")
                app.dfuProgress = 0
                try await dfu.flashFirmware(objectType: 0x01, firmware: appDat) { _ in }

                status = L10n.t("Flashing firmware…")
                try await dfu.flashFirmware(objectType: 0x02, firmware: appBin) { fraction in
                    Task { @MainActor in app.dfuProgress = fraction }
                }

                app.dfuProgress = nil
                pendingFirmware = nil
                busyPhase = .idle
                status = L10n.t("Done! Firmware updated — the device is rebooting.")
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
