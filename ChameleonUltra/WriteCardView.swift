import SwiftUI

/// Write card page (port of `gui/page/write_card.dart` core flows).
struct WriteCardView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: CardStore

    @State private var mode: WriteMode = .mifareDump
    @State private var selectedCard: CardSave?
    @State private var magicType: MagicType = .gen1
    @State private var newUID = ""
    @State private var keyA = "FFFFFFFFFFFF"
    @State private var error: String?
    @State private var message: String?
    @State private var progress: Double = 0
    @State private var writing = false

    enum WriteMode: String, CaseIterable, Identifiable {
        case mifareDump = "Mifare dump"
        case uidWrite = "Write UID"
        case lfClone = "LF clone (T55xx)"
        var id: String { rawValue }
    }

    enum MagicType: String, CaseIterable, Identifiable {
        case gen1 = "Gen1 (magic, no auth)"
        case gen2 = "Gen2 (keyed)"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner(message: $error)
                if let message {
                    GlassCard {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                if !app.isConnected {
                    GlassCard {
                        Label(L10n.t("Connect a Chameleon device first (Home tab)."), systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L10n.t("Mode"), selection: $mode) {
                        ForEach(WriteMode.allCases) { Text(L10n.t($0.rawValue)).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    switch mode {
                    case .mifareDump: mifareDumpSection
                    case .uidWrite: uidWriteSection
                    case .lfClone: lfCloneSection
                    }
                }
            }
            .padding()
        }
        .navigationTitle(L10n.t("Write card"))
        .disabled(writing)
        .overlay {
            if writing {
                VStack(spacing: 12) {
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text("\(L10n.t("Writing…")) \(Int(progress * 100))%")
                        .font(.footnote)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    // MARK: - Mifare dump

    private var mifareDumpSection: some View {
        VStack(spacing: 16) {
            GlassCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("Source card")).font(.headline)
                    if store.cards.filter({ $0.isMifareClassic }).isEmpty {
                        Text(L10n.t("No saved Mifare Classic cards. Read one first."))
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker(L10n.t("Card"), selection: $selectedCard) {
                            ForEach(store.cards.filter { $0.isMifareClassic }) { card in
                                Text("\(card.name) (\(card.displayType))").tag(card as CardSave?)
                            }
                        }
                        .pickerStyle(.menu)

                        Picker(L10n.t("Card type"), selection: $magicType) {
                            ForEach(MagicType.allCases) { Text(L10n.t($0.rawValue)).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        if magicType == .gen2 {
                            HStack {
                                Text(L10n.t("Key A")).foregroundStyle(.secondary)
                                TextField("FFFFFFFFFFFF", text: $keyA)
                                    .font(.system(size: 13, design: .monospaced))
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.characters)
                            }
                        }

                        Button {
                            Task { await writeMifareDump() }
                        } label: {
                            Label(L10n.t("Write dump to card"), systemImage: "square.and.pencil")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedCard == nil || writing)
                    }
                }
            }
        }
    }

    private func writeMifareDump() async {
        guard let communicator = app.communicator, let card = selectedCard else { return }
        writing = true
        error = nil
        message = nil
        progress = 0

        do {
            if try await !communicator.isReaderDeviceMode() {
                try await communicator.setReaderDeviceMode(true)
            }
            let blockCount = card.data.count
            for (index, block) in card.data.enumerated() where block.count == 16 {
                var ok = false
                if magicType == .gen1 {
                    ok = try await gen1WriteBlock(communicator, block: index, data: Data(block))
                } else {
                    let key = Data(hex: keyA)
                    guard key.count == 6 else { throw ChameleonError.invalidResponse("Key A must be 12 hex characters") }
                    ok = try await communicator.mf1WriteBlock(block: index, keyType: 0x60, key: key, blockData: Data(block))
                }
                if !ok {
                    let cardKind = magicType == .gen1 ? "Gen1 magic" : "writable"
                    throw ChameleonError.invalidResponse("write failed at block \(index) – is the card a \(cardKind) card?")
                }
                progress = Double(index + 1) / Double(blockCount)
            }
            message = L10n.tf("Dump written (%d blocks)", blockCount)
        } catch {
            self.error = error.localizedDescription
        }
        writing = false
    }

    /// Gen1 magic unlock: reset → 0x40 wakeup → 0x43 unlock → 0xA0 block write (no CRC).
    private func gen1WriteBlock(_ communicator: ChameleonCommunicator, block: Int, data: Data) async throws -> Bool {
        var unlockOptions = ChameleonCommunicator.Raw14AOptions()
        unlockOptions.appendCrc = false
        unlockOptions.checkResponseCrc = false
        unlockOptions.respTimeoutMs = 100

        _ = try await communicator.send14ARaw(Data([0x00]), options: unlockOptions)   // reset
        _ = try await communicator.send14ARaw(Data([0x40]), options: unlockOptions)   // wakeup
        let ack1 = try await communicator.send14ARaw(Data([0x43]), options: unlockOptions) // unlock
        guard ack1.count == 1, ack1.first == 0x0A else { return false }

        _ = try await communicator.send14ARaw(Data([0xA0, UInt8(block)]), options: unlockOptions)
        let ack2 = try await communicator.send14ARaw(data, options: unlockOptions)
        return ack2.count == 1 && ack2.first == 0x0A
    }

    // MARK: - UID write

    private var uidWriteSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("Write UID (Gen1 magic card)")).font(.headline)
                Text(L10n.t("4 or 7 byte hex UID. Block 0 is rebuilt from UID/SAK/ATQA."))
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("04 A2 B3 C4 D5 E6", text: $newUID)
                    .font(.system(size: 15, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                Button {
                    Task { await writeUID() }
                } label: {
                    Label(L10n.t("Write UID"), systemImage: "person.text.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(writing)
            }
        }
    }

    private func writeUID() async {
        guard let communicator = app.communicator else { return }
        writing = true
        error = nil
        message = nil
        progress = 0.5

        do {
            let uid = Data(hex: newUID)
            guard uid.count == 4 || uid.count == 7 else {
                throw ChameleonError.invalidResponse("UID must be 4 or 7 bytes")
            }
            if try await !communicator.isReaderDeviceMode() {
                try await communicator.setReaderDeviceMode(true)
            }
            var options = ChameleonCommunicator.Raw14AOptions()
            options.appendCrc = false
            options.checkResponseCrc = false
            options.respTimeoutMs = 100
            _ = try await communicator.send14ARaw(Data([0x00]), options: options)
            _ = try await communicator.send14ARaw(Data([0x40]), options: options)
            let ack = try await communicator.send14ARaw(Data([0x43]), options: options)
            guard ack.count == 1, ack.first == 0x0A else {
                throw ChameleonError.invalidResponse("Card did not unlock – not a Gen1 magic card?")
            }
            let sak: UInt8 = uid.count == 4 ? 0x08 : 0x00
            let atqa: Data = uid.count == 4 ? Data([0x44, 0x00]) : Data([0x44, 0x00])
            let block0 = MifareClassic.patchFirstBlock(Data(repeating: 0, count: 16),
                                                       uid: uid, sak: sak, atqa: atqa, vanitySak: false)
            _ = try await communicator.send14ARaw(Data([0xA0, 0x00]), options: options)
            let ack2 = try await communicator.send14ARaw(block0, options: options)
            guard ack2.count == 1, ack2.first == 0x0A else {
                throw ChameleonError.invalidResponse("Write not acknowledged")
            }
            progress = 1
            message = L10n.tf("UID written: %@", uid.hexSpaced)
        } catch {
            self.error = error.localizedDescription
        }
        writing = false
    }

    // MARK: - LF clone

    private var lfCloneSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("Clone LF card to T55xx")).font(.headline)
                if store.cards.filter({ $0.tagType.frequency == .lf }).isEmpty {
                    Text(L10n.t("No saved LF cards. Read one first."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Picker(L10n.t("Card"), selection: $selectedCard) {
                        ForEach(store.cards.filter { $0.tagType.frequency == .lf }) { card in
                            Text("\(card.name) (\(card.tagType.displayName))").tag(card as CardSave?)
                        }
                    }
                    .pickerStyle(.menu)
                    Button {
                        Task { await cloneLF() }
                    } label: {
                        Label(L10n.t("Write to T55xx tag"), systemImage: "doc.on.doc.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedCard == nil || writing)
                }
            }
        }
    }

    private func cloneLF() async {
        guard let communicator = app.communicator, let card = selectedCard else { return }
        writing = true
        error = nil
        message = nil
        progress = 0.5

        do {
            let uid = card.uidData
            try await communicator.writeEM410XtoT55XX(uid: uid, newKey: Data(repeating: 0, count: 4), oldKeys: [])
            progress = 1
            message = L10n.tf("T55xx written with %@", card.tagType.displayName)
        } catch {
            self.error = error.localizedDescription
        }
        writing = false
    }
}
