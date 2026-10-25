import SwiftUI

enum HFReadPhase: Equatable {
    case idle
    case scanning
    case cardFound
    case checkingKeys
    case dumping
    case done
}

/// Read card page (port of `gui/page/read_card.dart`).
struct ReadCardView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: CardStore

    @State private var frequency: TagFrequency = .hf
    @State private var phase: HFReadPhase = .idle
    @State private var error: String?

    // HF state
    @State private var card: CardData?
    @State private var tagType: TagType = .unknown
    @State private var mfuTypeDetermined: TagType = .unknown
    @State private var isMifareClassic = false
    @State private var isEV1 = false
    @State private var ntLevel: NTLevel = .unknown
    @State private var mfuVersion: Data = Data()
    @State private var mfuPages: [[UInt8]] = []
    @StateObject private var recovery = MifareClassicRecoveryPlaceholder.shared

    // LF state
    @State private var lfCard: (type: TagType, uid: String)?
    @State private var lfDetail: String = ""

    // save sheet
    @State private var showSaveSheet = false
    @State private var saveName = ""

    private var communicator: ChameleonCommunicator? { app.communicator }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner(message: $error)

                if !app.isConnected {
                    GlassCard {
                        Label("Connect a Chameleon device first (Home tab).", systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Frequency", selection: $frequency) {
                        Text("HF 13.56 MHz").tag(TagFrequency.hf)
                        Text("LF 125 kHz").tag(TagFrequency.lf)
                    }
                    .pickerStyle(.segmented)

                    if frequency == .hf { hfSection } else { lfSection }
                }
            }
            .padding()
        }
        .navigationTitle("Read card")
        .sheet(isPresented: $showSaveSheet) { saveSheet }
    }

    // MARK: HF

    private var hfSection: some View {
        VStack(spacing: 16) {
            if phase == .idle || phase == .scanning {
                GlassCard {
                    VStack(spacing: 12) {
                        Image(systemName: "sensor.tag.rfid.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("Place a HF tag on the Chameleon antenna")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await readHF() }
                        } label: {
                            Label(phase == .scanning ? "Reading…" : "Read tag", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(phase == .scanning)
                    }
                }
            }

            if phase == .scanning {
                GlassCard { HStack { ProgressView(); Text("Reading tag…").foregroundStyle(.secondary) } }
            }

            if let card, phase != .idle, phase != .scanning {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ISO14443A")
                            .font(.headline)
                        row("UID", card.uid.hexSpaced)
                        row("SAK", String(format: "%02X", card.sak))
                        row("ATQA", card.atqa.hexSpaced)
                        row("ATS", card.ats.isEmpty ? "—" : card.ats.hexSpaced)
                        row("Type", isMifareClassic
                            ? tagType.displayName + (isEV1 ? " EV1" : "")
                            : (mfuTypeDetermined == .unknown ? "Not Mifare Classic" : mfuTypeDetermined.displayName))
                        if isMifareClassic {
                            row("PRNG", ntLevel.rawValue)
                        }
                        if !mfuVersion.isEmpty {
                            row("Version", mfuVersion.hexSpaced)
                        }
                    }
                }
            }

            if let recoveryModel {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Key recovery")
                                .font(.headline)
                            Spacer()
                            if let progress = recoveryModel.keyCheckProgress {
                                Text("\(Int(progress * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let progress = recoveryModel.keyCheckProgress {
                            ProgressView(value: progress)
                        }
                        if !recoveryModel.state.isEmpty {
                            Text(recoveryModel.state).font(.footnote).foregroundStyle(.secondary)
                        }
                        KeyCheckGridView(recovery: recoveryModel)

                        if phase == .cardFound || phase == .checkingKeys {
                            Button {
                                Task { await checkKeys(autoDump: true) }
                            } label: {
                                Label("Check keys & dump", systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(phase == .checkingKeys)
                        }

                        if phase == .dumping {
                            HStack { ProgressView(value: recoveryModel.dumpProgress); Text("Dumping…") }
                        }

                        if phase == .done {
                            Button {
                                saveName = defaultSaveName
                                showSaveSheet = true
                            } label: {
                                Label("Save card", systemImage: "square.and.arrow.down.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            if !mfuPages.isEmpty && !isMifareClassic {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Dump (\(mfuPages.count) pages)")
                            .font(.headline)
                        HexDumpView(blocks: mfuPages, blockSize: 4)
                        if phase == .done {
                            Button {
                                saveName = defaultSaveName
                                showSaveSheet = true
                            } label: {
                                Label("Save card", systemImage: "square.and.arrow.down.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
    }

    private var recoveryModel: MifareClassicRecovery? {
        recovery.attached
    }

    private var defaultSaveName: String {
        guard let card else { return "Card" }
        let typeName = isMifareClassic ? tagType.displayName : (mfuTypeDetermined == .unknown ? "HF" : mfuTypeDetermined.displayName)
        return "\(card.uid.hex) \(typeName)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func readHF() async {
        guard let communicator else { return }
        error = nil
        phase = .scanning
        mfuPages = []
        mfuVersion = Data()
        mfuTypeDetermined = .unknown

        do {
            if try await !communicator.isReaderDeviceMode() {
                try await communicator.setReaderDeviceMode(true)
            }
            guard let found = try await communicator.scan14443aTag() else {
                error = "No tag found"
                phase = .idle
                return
            }
            card = found

            let mifare = try await communicator.detectMf1Support()
            isMifareClassic = mifare
            recovery.attached = nil

            if mifare {
                let recoveryModel = MifareClassicRecovery(communicator: communicator)
                recovery.attached = recoveryModel
                try await recoveryModel.detectCard()
                tagType = recoveryModel.mifareClassicType.chameleonTagType
                isEV1 = recoveryModel.isEV1
                ntLevel = recoveryModel.ntLevel
            } else {
                mfuTypeDetermined = (try? await MifareUltralight.type(via: communicator)) ?? .unknown
                mfuVersion = (try? await MifareUltralight.getVersion(via: communicator)) ?? Data()
                tagType = mfuTypeDetermined
                mfuPages = (try? await MifareUltralight.readDump(via: communicator, type: mfuTypeDetermined)) ?? []
                phase = .done
                return
            }
            phase = .cardFound
        } catch {
            error = error.localizedDescription
            phase = .idle
        }
    }

    private func checkKeys(autoDump: Bool) async {
        guard let recoveryModel = recovery.attached else { return }
        error = nil
        phase = .checkingKeys
        do {
            let dictionary = store.dictionaries.first { $0.keyLength == 12 }
            try await recoveryModel.checkKeys(dictionary: dictionary)
            if autoDump {
                phase = .dumping
                try await recoveryModel.dumpData()
            }
            phase = .done
        } catch {
            self.error = error.localizedDescription
            phase = .cardFound
        }
    }

    // MARK: LF

    private var lfSection: some View {
        VStack(spacing: 16) {
            if phase == .idle || phase == .scanning {
                GlassCard {
                    VStack(spacing: 12) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 40))
                            .foregroundStyle(.tint)
                        Text("Place a LF tag on the Chameleon antenna")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await readLF() }
                        } label: {
                            Label(phase == .scanning ? "Reading…" : "Read tag", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(phase == .scanning)
                    }
                }
            }

            if let lfCard {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lfCard.type.displayName).font(.headline)
                        row("UID", lfCard.uid)
                        if !lfDetail.isEmpty {
                            row("Info", lfDetail)
                        }
                        Button {
                            saveName = "\(lfCard.uid) \(lfCard.type.displayName)"
                            showSaveSheet = true
                        } label: {
                            Label("Save card", systemImage: "square.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func readLF() async {
        guard let communicator else { return }
        error = nil
        phase = .scanning
        lfCard = nil
        lfDetail = ""

        do {
            if try await !communicator.isReaderDeviceMode() {
                try await communicator.setReaderDeviceMode(true)
            }
            if let em = try await communicator.readEM410X(), !em.uid.isEmpty {
                lfCard = (em.type, em.uid.hexSpaced)
            } else if let hid = try await communicator.readHIDProx(), !hid.uid.isEmpty {
                lfCard = (hid.type, hid.uid.hexSpaced)
                lfDetail = hid.viewableString
            } else if let viking = try await communicator.readViking(), !viking.uid.isEmpty {
                lfCard = (viking.type, viking.uid.hexSpaced)
            } else if let pac = try await communicator.readPac(), !pac.uid.isEmpty {
                lfCard = (pac.type, pac.uid.hexSpaced)
            } else if let io = try await communicator.readIoProx(), !io.uid.isEmpty {
                lfCard = (io.type, io.uid.hexSpaced)
            } else {
                error = "No LF tag found"
            }
        } catch {
            self.error = error.localizedDescription
        }
        phase = .idle
    }

    // MARK: Save sheet

    private var saveSheet: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $saveName)
                if let card {
                    LabeledContent("UID", value: card.uid.hexSpaced)
                    LabeledContent("Type", value: defaultSaveNameContainsType)
                }
            }
            .navigationTitle("Save card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSaveSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCard()
                        showSaveSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var defaultSaveNameContainsType: String {
        isMifareClassic ? tagType.displayName : (mfuTypeDetermined == .unknown ? lfCard?.type.displayName ?? "" : mfuTypeDetermined.displayName)
    }

    private func saveCard() {
        if frequency == .lf, let lfCard {
            store.add(CardSave(uid: lfCard.uid.replacingOccurrences(of: " ", with: ""),
                               name: saveName, tag: lfCard.type))
            return
        }
        guard let card else { return }
        if isMifareClassic, let recoveryModel = recovery.attached {
            let blocks = recoveryModel.cardData.prefix(recoveryModel.mifareClassicType.blockCount)
                .map { Array($0) }
            store.add(CardSave(uid: card.uid.hex,
                               name: saveName,
                               tag: recoveryModel.mifareClassicType.chameleonTagType,
                               sak: Int(card.sak),
                               atqa: Array(card.atqa),
                               ats: Array(card.ats),
                               data: blocks))
        } else {
            store.add(CardSave(uid: card.uid.hex,
                               name: saveName,
                               tag: mfuTypeDetermined,
                               sak: Int(card.sak),
                               atqa: Array(card.atqa),
                               ats: Array(card.ats),
                               data: mfuPages))
        }
    }
}

/// Small holder so the @StateObject wrapper stays stable while the actual
/// recovery model is recreated per read.
@MainActor
final class MifareClassicRecoveryPlaceholder: ObservableObject {
    static let shared = MifareClassicRecoveryPlaceholder()
    @Published var attached: MifareClassicRecovery?
}
