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
    @Environment(\.themeAccent) private var themeAccent

    @State private var frequency: TagFrequency = .hf
    @State private var phase: HFReadPhase = .idle
    @State private var error: String?
    @State private var checkTask: Task<Void, Never>?

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

    // key export
    @State private var showShare = false
    @State private var shareURL: URL?

    // key check options (port of additional_key_dict / skipDefaultDictionary)
    @State private var selectedDictionaryID: UUID?
    @State private var skipDefaultDictionary = false

    // continuous scan (hf14aScanKeep-style loop)
    @State private var continuous = false
    @State private var foundCards: [CardData] = []
    @State private var savedUIDs: Set<String> = []
    @State private var scanTask: Task<Void, Never>?

    private var communicator: ChameleonCommunicator? { app.communicator }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner(message: $error)

                if !app.isConnected {
                    GlassCard {
                        Label(L10n.t("Connect a Chameleon device first (Home tab)."), systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L10n.t("Frequency"), selection: $frequency) {
                        Text(L10n.t("HF 13.56 MHz")).tag(TagFrequency.hf)
                        Text(L10n.t("LF 125 kHz")).tag(TagFrequency.lf)
                    }
                    .pickerStyle(.segmented)

                    if frequency == .hf { hfSection } else { lfSection }
                }
            }
            .padding()
        }
        .navigationTitle(L10n.t("Read card"))
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
            checkTask?.cancel()
            checkTask = nil
            continuous = false
        }
        .sheet(isPresented: $showSaveSheet) { saveSheet }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }

    private var readButtonTitle: String {
        switch phase {
        case .scanning: return L10n.t("Reading…")
        case .idle: return L10n.t("Read tag")
        default: return L10n.t("Re-read tag")
        }
    }

    // MARK: Continuous scan

    private var continuousScanCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L10n.t("Continuous scan"), isOn: Binding(
                    get: { continuous },
                    set: { _ in toggleContinuous() }))
                Text(L10n.t("Place a HF tag on the Chameleon antenna"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !foundCards.isEmpty {
                    Divider()
                    ForEach(Array(foundCards.enumerated()), id: \.offset) { _, found in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(found.uid.hexSpaced)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                Text("SAK \(String(format: "%02X", found.sak)) · ATQA \(found.atqa.hexSpaced)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if savedUIDs.contains(found.uid.hex) {
                                Label(L10n.t("Saved"), systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            } else {
                                Button {
                                    saveUIDOnly(card: found, type: .unknown)
                                } label: {
                                    Text(L10n.t("Save UID only"))
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(themeAccent.opacity(0.15), in: Capsule())
                                        .foregroundStyle(themeAccent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func toggleContinuous() {
        if continuous {
            continuous = false
            scanTask?.cancel()
            scanTask = nil
        } else {
            continuous = true
            foundCards = []
            savedUIDs = []
            scanTask = Task {
                do {
                    if let communicator, try await !communicator.isReaderDeviceMode() {
                        try await communicator.setReaderDeviceMode(true)
                    }
                    while !Task.isCancelled {
                        if let found = try await communicator?.scan14443aTag(),
                           !foundCards.contains(where: { $0.uid == found.uid }) {
                            foundCards.append(found)
                        }
                        try await Task.sleep(nanoseconds: 800_000_000)
                    }
                } catch is CancellationError {
                } catch {
                    self.error = error.localizedDescription
                }
                await MainActor.run { continuous = false }
            }
        }
    }

    /// Save just the anti-collision data (original: save_only_uid).
    private func saveUIDOnly(card found: CardData, type: TagType) {
        store.add(CardSave(uid: found.uid.hex,
                           name: "UID \(found.uid.hex)",
                           tag: type,
                           sak: Int(found.sak),
                           atqa: Array(found.atqa),
                           ats: Array(found.ats),
                           data: []))
        savedUIDs.insert(found.uid.hex)
    }

    private var hfSection: some View {
        VStack(spacing: 16) {
            // the read button is always available — reading can be repeated any time
            GlassCard {
                VStack(spacing: 12) {
                    Image(systemName: "creditcard.viewfinder")
                        .font(.system(size: 40))
                        .foregroundStyle(.tint)
                    Text(L10n.t("Place a HF tag on the Chameleon antenna"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await readHF() }
                    } label: {
                        Label(readButtonTitle, systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .lgTile(prominent: true)
                    .disabled(phase == .scanning || phase == .checkingKeys || phase == .dumping || continuous)
                }
            }

            continuousScanCard

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
                            : (mfuTypeDetermined == .unknown ? L10n.t("Not Mifare Classic") : mfuTypeDetermined.displayName))
                        if isMifareClassic {
                            row("PRNG", ntLevel.rawValue)
                        }
                        if !mfuVersion.isEmpty {
                            row("Version", mfuVersion.hexSpaced)
                        }

                        Divider()

                        Button {
                            saveUIDOnly(card: card,
                                        type: isMifareClassic ? tagType : (mfuTypeDetermined == .unknown ? .unknown : mfuTypeDetermined))
                        } label: {
                            Label(L10n.t("Save UID only"), systemImage: "person.crop.circle.badge.checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let recoveryModel {
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        // SegmentedProgress carries its own right-aligned
                        // percentage, so no separate caption here.
                        Text(L10n.t("Key recovery"))
                            .font(.headline)
                        if let progress = recoveryModel.keyCheckProgress {
                            SegmentedProgress(progress: progress, count: 14)
                        }
                        if !recoveryModel.state.isEmpty {
                            Text(recoveryModel.state).font(.footnote).foregroundStyle(.secondary)
                        }
                        KeyCheckGridView(recovery: recoveryModel)

                        if phase == .cardFound || phase == .checkingKeys {
                            VStack(alignment: .leading, spacing: 10) {
                                Picker(L10n.t("Additional key dictionary"), selection: $selectedDictionaryID) {
                                    Text(L10n.t("None")).tag(UUID?.none)
                                    ForEach(mifareDictionaries) { dict in
                                        Text("\(dict.name) (\(dict.keys.count))").tag(UUID?.some(dict.id))
                                    }
                                }
                                Toggle(L10n.t("Skip default keys"), isOn: $skipDefaultDictionary)
                            }
                            .font(.subheadline)
                            .padding(10)
                            .background(Color(.systemBackground).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))

                            Button {
                                checkTask = Task { await checkKeys(autoDump: true) }
                            } label: {
                                Label(L10n.t("Check keys & dump"), systemImage: "key.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .lgTile(prominent: true)
                            .disabled(phase == .checkingKeys)
                        }

                        if phase == .checkingKeys || phase == .dumping {
                            Button {
                                checkTask?.cancel()
                                checkTask = nil
                            } label: {
                                Label(L10n.t("Stop"), systemImage: "stop.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(themeAccent)
                        }

                        if phase == .dumping {
                            HStack { SegmentedProgress(progress: recoveryModel.dumpProgress, count: 14); Text(L10n.t("Dumping…")) }
                        }

                        if phase == .done {
                            Button {
                                saveName = defaultSaveName
                                showSaveSheet = true
                            } label: {
                                Label(L10n.t("Save card"), systemImage: "square.and.arrow.down.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .lgTile(prominent: true)

                            Menu {
                                Button {
                                    exportFoundKeys(shareOnly: false)
                                } label: {
                                    Label(L10n.t("Save to dictionaries"), systemImage: "book")
                                }
                                Button {
                                    exportFoundKeys(shareOnly: true)
                                } label: {
                                    Label(L10n.t("Share as .dic"), systemImage: "square.and.arrow.up")
                                }
                            } label: {
                                Label(L10n.t("Export found keys"), systemImage: "key.horizontal")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            if !mfuPages.isEmpty && !isMifareClassic {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(L10n.t("Dump")) (\(mfuPages.count) \(L10n.t("pages")))")
                            .font(.headline)
                        HexDumpView(blocks: mfuPages, blockSize: 4)
                        if phase == .done {
                            Button {
                                saveName = defaultSaveName
                                showSaveSheet = true
                            } label: {
                                Label(L10n.t("Save card"), systemImage: "square.and.arrow.down.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .lgTile(prominent: true)
                        }
                    }
                }
            }
        }
    }

    private var recoveryModel: MifareClassicRecovery? {
        recovery.attached
    }

    /// Dictionaries usable as a Mifare Classic key source (6-byte keys).
    private var mifareDictionaries: [KeyDictionary] {
        store.dictionaries.filter { $0.keyLength == 12 }
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
            // default to the first Mifare dictionary, like the original app
            if selectedDictionaryID == nil, let first = mifareDictionaries.first {
                selectedDictionaryID = first.id
            }
            guard let found = try await communicator.scan14443aTag() else {
                error = L10n.t("No tag found")
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
            self.error = error.localizedDescription
            phase = .idle
        }
    }

    private func checkKeys(autoDump: Bool) async {
        guard let recoveryModel = recovery.attached else { return }
        error = nil
        phase = .checkingKeys
        do {
            let dictionary = mifareDictionaries.first { $0.id == selectedDictionaryID }
                ?? mifareDictionaries.first   // fall back to auto-select, original behavior
            try await recoveryModel.checkKeys(dictionary: dictionary,
                                              skipDefaultDictionary: skipDefaultDictionary)
            if autoDump {
                phase = .dumping
                try await recoveryModel.dumpData()
            }
            phase = .done
        } catch is CancellationError {
            // user pressed Stop — keep whatever was already found
            recoveryModel.state = ""
            recoveryModel.keyCheckProgress = nil
            phase = recoveryModel.allKeysExist || recoveryModel.checkMarks.contains(.found) ? .done : .cardFound
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
                        Text(L10n.t("Place a LF tag on the Chameleon antenna"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await readLF() }
                        } label: {
                            Label(phase == .scanning ? L10n.t("Reading…") : L10n.t("Read tag"), systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .lgTile(prominent: true)
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
                            Label(L10n.t("Save card"), systemImage: "square.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .lgTile(prominent: true)
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
                error = L10n.t("No LF tag found")
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
                TextField(L10n.t("Name"), text: $saveName)
                if let card {
                    LabeledContent("UID", value: card.uid.hexSpaced)
                    LabeledContent("Type", value: defaultSaveNameContainsType)
                }
            }
            .navigationTitle(L10n.t("Save card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.t("Cancel")) { showSaveSheet = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save")) {
                        saveCard()
                        showSaveSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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

    // MARK: Key export

    private func exportFoundKeys(shareOnly: Bool) {
        guard let recoveryModel = recovery.attached else { return }
        var unique: [Data] = []
        var seen = Set<String>()
        for key in recoveryModel.validKeys where !key.isEmpty && !seen.contains(key.hex) {
            seen.insert(key.hex)
            unique.append(key)
        }
        guard !unique.isEmpty else {
            error = L10n.t("No keys found yet")
            return
        }

        if !shareOnly {
            var dictionary = KeyDictionary(name: "\(card?.uid.hex.uppercased() ?? "Card") · \(L10n.t("Keys from dump"))")
            dictionary.keys = unique.map { Array($0) }
            dictionary.keyLength = 12
            store.add(dictionary: dictionary)
        }

        let text = unique.map { $0.hex.uppercased() }.joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recovered_keys.dic")
        try? text.data(using: .utf8)?.write(to: url)
        shareURL = url
        showShare = true
    }
}

/// Small holder so the @StateObject wrapper stays stable while the actual
/// recovery model is recreated per read.
@MainActor
final class MifareClassicRecoveryPlaceholder: ObservableObject {
    static let shared = MifareClassicRecoveryPlaceholder()
    @Published var attached: MifareClassicRecovery?
}
