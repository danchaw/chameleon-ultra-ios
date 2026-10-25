import Foundation
import SwiftUI
import Combine

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

    @Published var activeSlot = 0
    @Published var slotTypes: [SlotTypes] = Array(repeating: SlotTypes(), count: 8)
    @Published var slotEnabled: [EnabledSlotInfo] = Array(repeating: EnabledSlotInfo(), count: 8)
    @Published var slotNames: [SlotNames] = Array(repeating: SlotNames(), count: 8)

    @Published var dfuProgress: Double? = nil
    @Published var logLines: [String] = []
    @Published var lastError: String?

    let ble = BLEManager()
    let store = CardStore()
    let firmwareStore = FirmwareStore()
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
                if let battery = try? await self.communicator?.getBatteryCharge() { self.battery = battery }
            }
        }
    }

    func appendLog(_ line: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        logLines.append("\(formatter.string(from: Date())) \(line)")
        if logLines.count > 800 { logLines.removeFirst(logLines.count - 800) }
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
            battery = try await communicator.getBatteryCharge()
            try await refreshSlots()
            if cancelRequested { ble.disconnect(); connectionState = .disconnected; return }
            connectionState = .connected
            appendLog("Connected to Chameleon \(deviceType.displayName) (fw \(numToVersionCode(version.version)))")
        } catch {
            if cancelRequested { return }
            lastError = "Device handshake failed: \(error.localizedDescription)"
            appendLog("Handshake failed: \(error)")
            ble.disconnect()
            connectionState = .disconnected
        }
    }

    func refreshSlots() async throws {
        guard let communicator else { return }
        activeSlot = try await communicator.getActiveSlot()
        if let types = try? await communicator.getSlotTagTypes() { slotTypes = types }
        if let enabled = try? await communicator.getEnabledSlots() { slotEnabled = enabled }
        if let names = try? await communicator.getSlotTagNames() { slotNames = names }
    }

    func activateSlot(_ index: Int) async {
        guard let communicator else { return }
        do {
            try await communicator.activateSlot(index)
            activeSlot = index
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
        dfuProgress = nil
    }
}
