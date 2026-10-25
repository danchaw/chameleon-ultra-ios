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

    func connect(to device: DiscoveredDevice) async {
        connectionState = .connecting
        communicator = nil
        appendLog("Connecting to \(device.displayName)…")

        let ok = await ble.connect(to: device)
        guard ok else {
            connectionState = .disconnected
            lastError = "Could not connect to \(device.displayName)"
            appendLog("Connection failed")
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
            let version = try await communicator.getFirmwareVersion()
            firmwareVersion = version.version
            gitCommit = (try? await communicator.getGitCommitHash()) ?? ""
            chipID = (try? await communicator.getDeviceChipID()) ?? ""
            bleAddress = (try? await communicator.getDeviceBLEAddress()) ?? ""
            battery = try await communicator.getBatteryCharge()
            try await refreshSlots()
            connectionState = .connected
            appendLog("Connected to Chameleon \(deviceType.displayName) (fw \(numToVersionCode(version.version)))")
        } catch {
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
            let blocks = card.data.flatMap { $0.count == 16 ? $0 : [] }
            if !blocks.isEmpty {
                try await communicator.setMf1BlockData(startBlock: 0, blocks: Data(blocks))
            }
            if card.uidData.count > 0 {
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

    private func handleDisconnect() {
        communicator = nil
        if connectionState == .dfuMode {
            appendLog("DFU connection lost")
        }
        connectionState = .disconnected
        dfuProgress = nil
    }
}
