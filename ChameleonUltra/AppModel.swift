import Foundation
import SwiftUI
import Combine
import ActivityKit
import SharedKit

/// Central application state – connection lifecycle, device status, slot info.
@MainActor
final class AppModel: ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected, connecting, connected, dfuMode
    }

    @Published var connectionState: ConnectionState = .disconnected
    @Published var deviceType: ChameleonDevice = .ultra
    @Published var deviceName: String = ""
    @Published var firmwareVersion: Int?
    @Published var gitCommit: String = ""
    @Published var battery: BatteryCharge?
    @Published var chipID: String = ""
    @Published var bleAddress: String = ""
    /// User-chosen nickname for the connected device ("" = use advertised name).
    @Published var deviceNickname: String = ""

    var displayDeviceName: String { deviceNickname.isEmpty ? deviceName : deviceNickname }

    @Published var activeSlot = 0
    @Published var slotTypes: [SlotTypes] = Array(repeating: SlotTypes(), count: 8)
    @Published var slotEnabled: [EnabledSlotInfo] = Array(repeating: EnabledSlotInfo(), count: 8)
    @Published var slotNames: [SlotNames] = Array(repeating: SlotNames(), count: 8)

    /// User aliases for slots 0...7, stored per device address (app-side,
    /// independent of the device's own tag nicknames).
    @Published var slotAliases: [String] = Array(repeating: "", count: 8)
    static let slotAliasesStoreKey = "deviceSlotAliases"

    /// Back button on the dashboard: show the device list page WITHOUT
    /// disconnecting; the BLE session and commands keep working in background.
    @Published var showDeviceList = false

    @Published var dfuProgress: Double? = nil
    @Published var logLines: [String] = []
    @Published var lastError: String?

    let ble = BLEManager()
    let store = CardStore()
    let firmwareStore = FirmwareStore()
    /// Electronic fence: entering a bound region pushes its card to the device.
    let geofence = GeofenceManager()
    private(set) var communicator: ChameleonCommunicator?
    private var cancellables: [AnyCancellable] = []

    var isConnected: Bool { connectionState == .connected }

    static let shared = AppModel()

    private init() {
        ble.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ble.onDisconnected = { [weak self] in
            Task { @MainActor in
                self?.handleDisconnect()
            }
        }
        // periodic battery refresh while connected
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, self.isConnected else { continue }
                if let battery = try? await self.communicator?.getBatteryCharge(),
                   battery.percent > 0 || battery.voltage > 0 {
                    // ignore transient 0/0 readings from the fuel gauge
                    self.battery = battery
                    self.updateLiveActivity()
                }
            }
        }
        // electronic fence: enter region -> load bound card
        geofence.onRegionEnter = { [weak self] regionId in
            self?.handleRegionEnter(regionId)
        }
        geofence.refreshMonitoring()
    }

    // MARK: - Live Activity (lock screen / Dynamic Island status card)
    //
    // ActivityKit carries device state to the system UI WITHOUT any shared
    // container or entitlement, so it works even when the sideload tool
    // strips App Groups. Home-screen widgets stay purely interactive (slot
    // links) — no app data flows into them.

    private var liveActivity: Activity<ChameleonActivityAttributes>?

    /// Keep the live activity in sync with the current device state.
    func updateLiveActivity() {
        syncLiveActivity()
    }

    private func makeActivityState(connected: Bool) -> ChameleonActivityAttributes.ContentState {
        var slotName = ""
        if activeSlot >= 0, activeSlot < slotNames.count {
            let names = slotNames[activeSlot]
            slotName = names.hf.isEmpty ? names.lf : names.hf
        }
        return .init(deviceName: displayDeviceName,
                     connected: connected,
                     batteryPercent: battery?.percent,
                     batteryMillivolts: battery?.voltage,
                     activeSlot: activeSlot,
                     slotName: slotName,
                     updatedAt: Date())
    }

    private func syncLiveActivity() {
        if isConnected {
            let state = makeActivityState(connected: true)
            if let activity = liveActivity {
                Task { try? await activity.update(.init(state: state, staleDate: nil)) }
                return
            }
            // adopt an activity left over from an earlier app run
            if let existing = Activity<ChameleonActivityAttributes>.activities.first {
                liveActivity = existing
                Task { try? await existing.update(.init(state: state, staleDate: nil)) }
                return
            }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attributes = ChameleonActivityAttributes(deviceName: displayDeviceName,
                                                         deviceTypeName: deviceType.displayName)
            Task {
                guard let activity = try? await Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: nil)) else { return }
                liveActivity = activity
                // slot widget reads aliases from the live activity — refresh now
                // that it exists
            }
        } else if let activity = liveActivity {
            liveActivity = nil
            let finalState = makeActivityState(connected: false)
            Task { try? await activity.end(.init(state: finalState, staleDate: nil),
                                           dismissalPolicy: .default) }
        }
    }

    // MARK: - Electronic fence (region enter -> load bound card)

    private func handleRegionEnter(_ regionId: UUID) {
        guard isConnected, let communicator else {
            appendLog("电子围栏：进入区域，但设备未连接")
            return
        }
        guard let region = GeoRegionStore.load().first(where: { $0.id == regionId }),
              let card = store.cards.first(where: { $0.id == region.cardId }) else { return }
        Task { @MainActor in
            do {
                try await applyCardToSlot(card, slot: activeSlot)
                try? await refreshSlots()
                appendLog("电子围栏：已载入「\(card.name)」（\(region.name)）")
            } catch {
                appendLog("电子围栏：载入「\(card.name)」失败 \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Auto slot polling (rotate the device's active card slot)

    /// Door-reader game, slot edition: the user writes a different card into
    /// each device slot beforehand; the app then flips the ACTIVE SLOT
    /// 0→1→2… every 50–200 ms so a waiting reader catches whichever card
    /// matches. Only the tiny setActiveSlot command is sent — slot contents
    /// are never rewritten, so the cycle is fast and flash-wear-friendly.
    @Published var autoCycleEnabled: Bool = UserDefaults.standard.bool(forKey: AutoPoll.enabledKey)
    @Published var cycleStatus: String = ""
    private var cycleTask: Task<Void, Never>?
    private var cycleActivitySync = Date.distantPast

    func setAutoCycle(_ on: Bool) {
        autoCycleEnabled = on
        UserDefaults.standard.set(on, forKey: AutoPoll.enabledKey)
        if on { startCardCycle() } else { stopCardCycle() }
    }

    func startCardCycle() {
        guard cycleTask == nil else { return }
        guard isConnected else { return }
        cycleTask = Task { @MainActor in
            appendLog("Auto slot polling started")
            var slot = activeSlot
            while !Task.isCancelled {
                guard isConnected, let communicator else {
                    cycleStatus = L10n.t("Waiting for device/cards")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let count = max(2, deviceType.slotCount)
                slot = (slot + 1) % count
                do {
                    try await communicator.activateSlot(slot)
                    activeSlot = slot
                    cycleStatus = "\(L10n.t("Slot")) \(slot)"
                } catch is CancellationError {
                    break
                } catch {
                    cycleStatus = "\(L10n.t("Slot")) \(slot): \(error.localizedDescription)"
                }
                // Keep the Live Activity roughly in sync without hammering
                // ActivityKit with an update every 50 ms.
                if Date().timeIntervalSince(cycleActivitySync) > 3 {
                    cycleActivitySync = Date()
                    updateLiveActivity()
                }
                try? await Task.sleep(nanoseconds: UInt64(AutoPoll.intervalMs) * 1_000_000)
            }
        }
    }

    func stopCardCycle() {
        cycleTask?.cancel()
        cycleTask = nil
        cycleStatus = ""
        updateLiveActivity()
    }

    // MARK: - Device registry (user-editable names)

    /// Stable identity for a device: BLE address once known, else the
    /// advertised name (some firmwares report no address until handshake).
    var deviceKey: String { bleAddress.isEmpty ? deviceName : bleAddress }

    /// User-renamed device registry entry (standard defaults, key
    /// `deviceRegistry`, per BLE address).
    struct DeviceRecord: Codable, Equatable {
        var address: String
        var nickname: String = ""
        var defaultName: String = ""
        var displayName: String { nickname.isEmpty ? defaultName : nickname }
    }

    func loadRegistry() -> [DeviceRecord] {
        guard let data = UserDefaults.standard.data(forKey: Self.registryKey),
              let records = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return [] }
        return records
    }

    private func saveRegistry(_ records: [DeviceRecord]) {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.registryKey)
        }
    }

    /// Remember the currently connected device (advertised name + address).
    func registerCurrentDevice() {
        let key = deviceKey
        guard !key.isEmpty else { return }
        var records = loadRegistry()
        if let idx = records.firstIndex(where: { $0.address == key }) {
            records[idx].defaultName = deviceName
        } else {
            records.append(DeviceRecord(address: key, nickname: "", defaultName: deviceName))
        }
        saveRegistry(records)
    }

    func setDeviceNickname(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = deviceKey
        guard !key.isEmpty else { return }
        var records = loadRegistry()
        if let idx = records.firstIndex(where: { $0.address == key }) {
            records[idx].nickname = name
        } else {
            records.append(DeviceRecord(address: key, nickname: name, defaultName: deviceName))
        }
        saveRegistry(records)
        deviceNickname = name
        objectWillChange.send()
        updateLiveActivity()
    }

    /// Name to show for a scanned device: nickname when the user has set one.
    func displayName(for device: DiscoveredDevice) -> String {
        // scanned rows only expose the advertised name; the address-keyed
        // record is matched through its stored defaultName
        if let rec = loadRegistry().first(where: { $0.defaultName == device.displayName }) {
            return rec.displayName
        }
        return device.displayName
    }

    static let registryKey = "deviceRegistry"

    // MARK: - Slot aliases

    func loadSlotAliases(for address: String) -> [String] {
        let all = UserDefaults.standard.dictionary(forKey: Self.slotAliasesStoreKey) as? [String: [String]] ?? [:]
        var list = all[address] ?? []
        while list.count < 8 { list.append("") }
        return Array(list.prefix(8))
    }

    func setSlotAlias(_ slot: Int, _ rawName: String) {
        guard slot >= 0, slot < 8, !deviceKey.isEmpty else { return }
        var all = UserDefaults.standard.dictionary(forKey: Self.slotAliasesStoreKey) as? [String: [String]] ?? [:]
        var list = all[deviceKey] ?? Array(repeating: "", count: 8)
        while list.count < 8 { list.append("") }
        list[slot] = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        all[deviceKey] = list
        UserDefaults.standard.set(all, forKey: Self.slotAliasesStoreKey)
        slotAliases = list
        updateLiveActivity()
    }

    func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("\(formatter.string(from: Date())) \(line)")
        // keep the viewer responsive: once the buffer grows past the threshold,
        // roll the oldest lines into a timestamped .log archive file
        if logLines.count > Self.logArchiveThreshold {
            let batch = Array(logLines.prefix(Self.logArchiveBatch))
            logLines.removeFirst(batch.count)
            writeLogArchive(batch)
        }
    }

    // MARK: - Log archiving

    static let logArchiveThreshold = 1500   // lines before rolling over
    static let logArchiveBatch = 1000       // lines per archived file

    struct LogArchive: Identifiable {
        let url: URL
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var sizeBytes: Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        var modifiedAt: Date? { try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
        var formattedSize: String { ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file) }
        var formattedDate: String {
            guard let modifiedAt else { return "—" }
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: modifiedAt)
        }
    }

    static var logArchiveDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LogArchives", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func writeLogArchive(_ lines: [String]) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = Self.logArchiveDirectory
            .appendingPathComponent("protocol-log-\(stamp.string(from: Date()))-\(UUID().uuidString.prefix(4)).log")
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Archive everything currently in memory immediately (manual button).
    @discardableResult
    func archiveLogNow() -> Bool {
        guard !logLines.isEmpty else { return false }
        let lines = logLines
        logLines = []
        return writeLogArchive(lines) != nil
    }

    func listLogArchives() -> [LogArchive] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: Self.logArchiveDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return items.filter { $0.pathExtension == "log" }
            .map { LogArchive(url: $0) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func deleteLogArchive(_ archive: LogArchive) {
        try? FileManager.default.removeItem(at: archive.url)
    }

    func deleteAllLogArchives() {
        listLogArchives().forEach { try? FileManager.default.removeItem(at: $0.url) }
    }

    // MARK: - Connection

    private var cancelRequested = false

    /// Abort an in-flight connect/handshake from the UI.
    func cancelConnection() {
        cancelRequested = true
        communicator = nil
        ble.disconnect()
        connectionState = .disconnected
        appendLog("Connection cancelled")
    }

    func connect(to device: DiscoveredDevice) async {
        cancelRequested = false
        connectionState = .connecting
        communicator = nil
        appendLog("Connecting to \(device.displayName)…")

        let ok = await ble.connect(to: device)
        guard ok, !cancelRequested else {
            if !cancelRequested {
                connectionState = .disconnected
                lastError = "Could not connect to \(device.displayName)"
                appendLog("Connection failed")
            }
            return
        }

        deviceName = device.displayName

        if device.isDFU {
            connectionState = .dfuMode
            appendLog("Connected in DFU mode")
            return
        }

        let communicator = ChameleonCommunicator(ble: ble) { [weak self] line in
            self?.appendLog(line)
        }
        self.communicator = communicator

        do {
            deviceType = try await communicator.getDeviceType()
            if cancelRequested { ble.disconnect(); connectionState = .disconnected; return }
            let version = try await communicator.getFirmwareVersion()
            firmwareVersion = version.version
            gitCommit = (try? await communicator.getGitCommitHash()) ?? ""
            chipID = (try? await communicator.getDeviceChipID()) ?? ""
            bleAddress = (try? await communicator.getDeviceBLEAddress()) ?? ""
            deviceNickname = loadRegistry().first { $0.address == deviceKey }?.nickname ?? ""
            slotAliases = loadSlotAliases(for: deviceKey)
            registerCurrentDevice()
            // the fuel gauge reports 0 for a few seconds right after boot /
            // first connect — retry until we get a plausible reading
            battery = nil
            await readBatteryWithRetry()
            try await refreshSlots()
            if cancelRequested { ble.disconnect(); connectionState = .disconnected; return }
            connectionState = .connected
            showDeviceList = false
            updateLiveActivity()
            // auto cycle picks up where it left off on a fresh connection
            if autoCycleEnabled { startCardCycle() }
            appendLog("Connected to Chameleon \(deviceType.displayName) (fw \(numToVersionCode(version.version)))")
        } catch {
            if cancelRequested { return }
            lastError = "Device handshake failed: \(error.localizedDescription)"
            appendLog("Handshake failed: \(error)")
            ble.disconnect()
            connectionState = .disconnected
        }
    }

    /// Read battery, retrying while the gauge still reports all-zero
    /// (right after first connect the value may not be available yet).
    private func readBatteryWithRetry() async {
        for attempt in 0..<4 {
            if let reading = try? await communicator?.getBatteryCharge(),
               reading.percent > 0 || reading.voltage > 0 {
                battery = reading
                return
            }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 1_200_000_000) }
        }
        // last attempt's value (even if zero) already stored on failure
        battery = try? await communicator?.getBatteryCharge()
    }

    func refreshSlots() async throws {
        guard let communicator else { return }
        activeSlot = try await communicator.getActiveSlot()
        if let types = try? await communicator.getSlotTagTypes() { slotTypes = types }
        if let enabled = try? await communicator.getEnabledSlots() { slotEnabled = enabled }
        if let names = try? await communicator.getSlotTagNames() { slotNames = names }
        updateLiveActivity()
    }

    func activateSlot(_ index: Int) async {
        guard let communicator else { return }
        do {
            try await communicator.activateSlot(index)
            activeSlot = index
            updateLiveActivity()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Apply a saved card to a device slot (emulation).
    func applyCardToSlot(_ card: CardSave, slot: Int) async throws {
        guard let communicator else { throw ChameleonError.notConnected }
        let tag = card.tagType
        let frequency = tag.frequency

        try await communicator.activateSlot(slot)
        try await communicator.setSlotType(slot, type: tag)
        try await communicator.setDefaultDataToSlot(slot, type: tag)

        if tag.isMifareClassic {
            // write in ≤128-byte (8-block) chunks with a 1 ms pause, exactly
            // like the original writeHfDumpToSlot — bigger frames overflow the
            // BLE buffer and fail with ATT errors
            let blocks = card.data.filter { $0.count == 16 }
            if !blocks.isEmpty {
                var lastSend = 0
                var chunk: [UInt8] = []
                var blockIndex = 0
                for block in blocks {
                    if chunk.count >= 128 {
                        try await communicator.setMf1BlockData(startBlock: lastSend, blocks: Data(chunk))
                        try? await Task.sleep(nanoseconds: 1_000_000)
                        chunk = []
                        lastSend = blockIndex
                    }
                    chunk.append(contentsOf: block)
                    blockIndex += 1
                }
                if !chunk.isEmpty {
                    try await communicator.setMf1BlockData(startBlock: lastSend, blocks: Data(chunk))
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
            }
            if card.uidData.count > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000)
                try await communicator.setMf1AntiCollision(CardData(
                    uid: card.uidData, sak: UInt8(card.sak), atqa: Data(card.atqa), ats: Data(card.ats)))
            }
        } else if tag.isEM410X {
            try await communicator.setEM410XEmulatorID(card.uidData)
        } else if tag == .hidProx {
            try await communicator.setHIDProxEmulatorID(card.uidData)
        } else if tag == .viking {
            try await communicator.setVikingEmulatorID(card.uidData)
        } else if tag == .pac {
            try await communicator.setPacEmulatorID(card.uidData)
        } else if tag == .ioProx {
            try await communicator.setIoProxEmulatorID(card.uidData)
        } else if tag == .idteck {
            try await communicator.setIdteckEmulatorID(card.uidData)
        } else if tag.frequency == .hf {
            // NTAG family: load 4-byte pages through the block data command
            let pages = card.data.flatMap { $0 }
            if !pages.isEmpty {
                try await communicator.setMf1BlockData(startBlock: 0, blocks: Data(pages))
            }
        }

        try await communicator.enableSlot(slot, frequency: frequency, status: true)
        try await refreshSlots()
    }

    func disconnect() {
        communicator = nil
        ble.disconnect()
        connectionState = .disconnected
        dfuProgress = nil
        appendLog("Disconnected")
    }

    /// Read a device slot back into a CardSave (Mifare Classic full dump
    /// with anti-collision data, or EM410X uid) — port of helpers/slot_dump.dart.
    /// The slot is temporarily activated first (block/uid reads target the
    /// active slot) and the previous slot is restored afterwards.
    func readSlotAsCard(slot: Int) async throws -> CardSave? {
        guard let communicator else { throw ChameleonError.notConnected }
        var tag = slotTypes[slot].hf
        var isHF = true
        if tag == .unknown {
            tag = slotTypes[slot].lf
            isHF = false
        }
        guard tag != .unknown else { return nil }
        let nick = isHF ? slotNames[slot].hf : slotNames[slot].lf
        let name = nick.isEmpty ? "Slot \(slot)" : nick

        let previousSlot = activeSlot
        if activeSlot != slot {
            try await communicator.activateSlot(slot)
            activeSlot = slot
        }

        var card: CardSave? = nil
        if tag.isMifareClassic {
            // the firmware limits blocks per read — original uses 16-block
            // chunks in a loop (slot_dump.dart); reading all at once returns
            // nothing
            var binData = Data()
            var currentBlock = 0
            let readCount = 16
            while currentBlock < tag.blockCount {
                let blocksToRead = min(readCount, tag.blockCount - currentBlock)
                binData.append(try await communicator.mf1GetBlockData(
                    startBlock: currentBlock, blockCount: blocksToRead))
                currentBlock += blocksToRead
            }
            var blocks: [[UInt8]] = []
            var offset = 0
            while offset + 16 <= binData.count {
                blocks.append(Array(binData[offset..<(offset + 16)]))
                offset += 16
            }
            let anti = try await communicator.mf1GetAntiCollData()
            card = CardSave(uid: anti.uid.hex, name: name, tag: tag,
                            sak: Int(anti.sak), atqa: Array(anti.atqa), ats: Array(anti.ats),
                            data: blocks)
        } else if tag.isEM410X {
            let uid = try await communicator.getEM410XEmulatorID()
            card = CardSave(uid: uid.hex, name: name, tag: tag)
        }

        if previousSlot != slot {
            try await communicator.activateSlot(previousSlot)
            activeSlot = previousSlot
        }
        return card   // other LF tag types not supported for slot export yet
    }

    private func handleDisconnect() {
        communicator = nil
        if connectionState == .dfuMode {
            appendLog("DFU connection lost")
        }
        connectionState = .disconnected
        showDeviceList = false
        dfuProgress = nil
        updateLiveActivity()
        stopCardCycle()
    }
}
