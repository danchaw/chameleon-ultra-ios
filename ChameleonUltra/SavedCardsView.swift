import SwiftUI

/// Saved cards browser (port of `gui/page/saved_cards.dart`).
struct SavedCardsView: View {
    @EnvironmentObject var store: CardStore
    @EnvironmentObject var app: AppModel
    @State private var search = ""
    @State private var showImporter = false
    @State private var message: String?
    @State private var pendingDelete: [CardSave]?

    var body: some View {
        List {
            if let message {
                Section { Text(message).foregroundStyle(.secondary).font(.footnote) }
            }
            Section {
                ForEach(filtered) { card in
                    NavigationLink {
                        CardDetailView(card: card)
                    } label: {
                        cardRow(card)
                    }
                }
                .onDelete { indexSet in
                    pendingDelete = indexSet.map { filtered[$0] }
                }
            }
        }
        .searchable(text: $search, prompt: L10n.t("name, UID or type"))
        .navigationTitle(L10n.t("Saved cards"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hapticFeedback()
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .buttonStyle(PressableButtonStyle())
            }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    DictionaryManagerView()
                } label: {
                    Image(systemName: "key.horizontal")
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(contentTypes: [.json]) { url in
                if let data = try? Data(contentsOf: url) {
                    let count = store.importCards(from: data)
                    message = count > 0 ? "✓ \(count) \(L10n.t("Imported"))" : L10n.t("No compatible cards found in file")
                    if count > 0 { UINotificationFeedbackGenerator().notificationOccurred(.success) }
                }
            }
        }
        .confirmationDialog(L10n.t("Confirm deletion"), isPresented: deleteDialogShown, titleVisibility: .visible) {
            Button(L10n.t("Delete"), role: .destructive) {
                pendingDelete?.forEach { store.delete($0) }
                pendingDelete = nil
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            Button(L10n.t("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.t("This cannot be undone."))
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private var filtered: [CardSave] {
        guard !search.isEmpty else { return store.cards }
        let query = search.lowercased()
        return store.cards.filter {
            $0.name.lowercased().contains(query)
                || $0.uid.lowercased().contains(query)
                || $0.displayType.lowercased().contains(query)
        }
    }

    private func cardRow(_ card: CardSave) -> some View {
        HStack(spacing: 12) {
            Image(systemName: card.tagType.frequency == .lf ? "antenna.radiowaves.left.and.right" : "creditcard.viewfinder")
                .font(.system(size: 20))
                .foregroundStyle(card.tagType.frequency == .lf ? .blue : .green)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name).font(.headline)
                Text("\(card.displayType) · \(card.uid.uppercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Card detail

struct CardDetailView: View {
    @EnvironmentObject var store: CardStore
    @EnvironmentObject var app: AppModel
    @State var card: CardSave
    @State private var showShare = false
    @State private var shareURL: URL?
    @State private var message: String?
    @State private var editableName: String = ""
    @State private var showApplySheet = false
    @State private var applyingSlot: Int?
    @State private var showDeleteConfirm = false

    private var blockSize: Int { card.isMifareClassic ? 16 : 4 }

    var body: some View {
        List {
            Section(L10n.t("Card")) {
                TextField(L10n.t("Name"), text: $editableName, onCommit: saveName)
                LabeledContent(L10n.t("Type"), value: card.displayType)
                LabeledContent("UID", value: card.uid.uppercased())
                if card.tagType.frequency == .hf {
                    LabeledContent("SAK", value: String(format: "%02X", card.sak))
                    LabeledContent("ATQA", value: card.atqa.map { String(format: "%02X", $0) }.joined(separator: " "))
                    if !card.ats.isEmpty {
                        LabeledContent("ATS", value: card.ats.map { String(format: "%02X", $0) }.joined(separator: " "))
                    }
                }
                LabeledContent(L10n.t("Blocks"), value: "\(card.data.count)")
            }

            if !card.data.isEmpty {
                Section(L10n.t("Dump")) {
                    HexDumpView(blocks: card.data, blockSize: blockSize)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section {
                if app.isConnected {
                    Button {
                        hapticFeedback()
                        showApplySheet = true
                    } label: {
                        HStack {
                            Label(L10n.t("Apply to device slot…"), systemImage: "square.grid.3x3")
                            Spacer()
                            if applyingSlot != nil { ProgressView() }
                        }
                    }
                    .buttonStyle(PressableButtonStyle())
                } else {
                    Label("Connect a device to emulate this card", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("Export")) {
                Button {
                    hapticFeedback()
                    export(json: true)
                } label: {
                    Label(L10n.t("Export as JSON"), systemImage: "curlybraces.square")
                }
                .buttonStyle(PressableButtonStyle())

                Button {
                    hapticFeedback()
                    export(json: false)
                } label: {
                    Label(L10n.t("Export as binary dump"), systemImage: "doc.binary")
                }
                .buttonStyle(PressableButtonStyle())

                if card.isMifareClassic && !card.dumpKeys.isEmpty {
                    Menu {
                        Button {
                            exportDumpKeys(saveToDictionaries: true)
                        } label: {
                            Label(L10n.t("Save to dictionaries"), systemImage: "book")
                        }
                        Button {
                            exportDumpKeys(saveToDictionaries: false)
                        } label: {
                            Label(L10n.t("Share as .dic"), systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label(L10n.t("Export keys from dump"), systemImage: "key.horizontal")
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            Section(L10n.t("Danger zone")) {
                Button(role: .destructive) {
                    hapticFeedback(.medium)
                    showDeleteConfirm = true
                } label: {
                    Label(L10n.t("Delete card"), systemImage: "trash")
                }
                .buttonStyle(PressableButtonStyle())
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary).font(.footnote) }
            }
        }
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { editableName = card.name }
        .sheet(isPresented: $showShare) {
            if let shareURL {
                ShareSheet(items: [shareURL])
            }
        }
        .sheet(isPresented: $showApplySheet) { applySheet }
        .confirmationDialog(L10n.t("Confirm deletion"), isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(L10n.t("Delete"), role: .destructive) {
                store.delete(card)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text("\(L10n.t("Delete this card?")) \(L10n.t("This cannot be undone."))")
        }
    }

    private var applySheet: some View {
        NavigationStack {
            List(0..<8, id: \.self) { slot in
                Button {
                    apply(to: slot)
                } label: {
                    HStack {
                        Text("\(L10n.t("Slot")) \(slot)  (\(app.slotTypes[slot].hf.displayName) / \(app.slotTypes[slot].lf.displayName))")
                            .foregroundStyle(.primary)
                        Spacer()
                        if applyingSlot == slot {
                            ProgressView()
                        } else if let applying = applyingSlot, applying < 0, -applying - 1 == slot {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                    }
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(applyingSlot != nil)
            }
            .navigationTitle(L10n.t("Choose slot"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func apply(to slot: Int) {
        hapticFeedback()
        applyingSlot = slot
        Task {
            do {
                try await app.applyCardToSlot(card, slot: slot)
                applyingSlot = -slot - 1   // done marker
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                message = L10n.tf("Applied to slot %d", slot)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                showApplySheet = false
            } catch {
                message = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                showApplySheet = false
            }
            applyingSlot = nil
        }
    }

    private func saveName() {
        card.name = editableName
        store.update(card)
    }

    private func export(json: Bool) {
        let safeName = card.name.replacingOccurrences(of: "/", with: "_")
        let ext = json ? "json" : "bin"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).\(ext)")
        do {
            if json {
                try JSONEncoder().encode([card]).write(to: url)
            } else {
                try card.binaryDump.write(to: url)
            }
            shareURL = url
            showShare = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func exportDumpKeys(saveToDictionaries: Bool) {
        let keys = card.dumpKeys
        guard !keys.isEmpty else { return }
        if saveToDictionaries {
            var dictionary = KeyDictionary(name: "\(card.name) · \(L10n.t("Keys from dump"))")
            dictionary.keys = keys.map { Array($0) }
            dictionary.keyLength = 12
            store.add(dictionary: dictionary)
            message = "✓ \(keys.count) \(L10n.t("keys imported"))"
        }
        let text = keys.map { $0.hex.uppercased() }.joined(separator: "\n") + "\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(card.name).dic")
        try? text.data(using: .utf8)?.write(to: url)
        shareURL = url
        showShare = true
    }
}

// MARK: - Dictionary manager

struct DictionaryManagerView: View {
    @EnvironmentObject var store: CardStore
    @State private var newText = ""
    @State private var newName = ""
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var pendingDeleteDict: KeyDictionary?

    var body: some View {
        List {
            Section {
                ForEach(store.dictionaries) { dict in
                    NavigationLink {
                        DictionaryDetailView(dictionary: dict)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(dict.name).font(.headline)
                            Text("\(dict.keys.count) \(L10n.t("keys"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    pendingDeleteDict = indexSet.map { store.dictionaries[$0] }.first
                }
            }
        }
        .navigationTitle(L10n.t("Dictionaries"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hapticFeedback()
                    showAdd = true
                } label: { Image(systemName: "plus") }
                    .buttonStyle(PressableButtonStyle())
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hapticFeedback()
                    showImporter = true
                } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(PressableButtonStyle())
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                Form {
                    TextField(L10n.t("Name"), text: $newName)
                    Section(L10n.t("Keys (one hex key per line)")) {
                        TextEditor(text: $newText)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minHeight: 180)
                    }
                }
                .navigationTitle(L10n.t("New dictionary"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.t("Cancel")) { showAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.t("Add")) {
                            let dict = KeyDictionary.fromText(newText, name: newName.isEmpty ? "Dictionary" : newName)
                            store.add(dictionary: dict)
                            newText = ""; newName = ""
                            showAdd = false
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(contentTypes: [.plainText, .json]) { url in
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let name = url.deletingPathExtension().lastPathComponent
                    let dict = KeyDictionary.fromText(text, name: name)
                    guard !dict.keys.isEmpty else { return }
                    store.add(dictionary: dict)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
        .confirmationDialog(L10n.t("Confirm deletion"), isPresented: deleteDictShown, titleVisibility: .visible) {
            Button(L10n.t("Delete"), role: .destructive) {
                if let dict = pendingDeleteDict { store.delete(dictionary: dict) }
                pendingDeleteDict = nil
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            Button(L10n.t("Cancel"), role: .cancel) { pendingDeleteDict = nil }
        } message: {
            Text("\(L10n.t("Delete this dictionary?")) \(L10n.t("This cannot be undone."))")
        }
    }

    private var deleteDictShown: Binding<Bool> {
        Binding(get: { pendingDeleteDict != nil }, set: { if !$0 { pendingDeleteDict = nil } })
    }
}

struct DictionaryDetailView: View {
    @EnvironmentObject var store: CardStore
    let dictionary: KeyDictionary
    @State private var showShare = false
    @State private var shareURL: URL?

    var body: some View {
        List(dictionary.keys, id: \.self) { key in
            Text(key.map { String(format: "%02X", $0) }.joined(separator: ""))
                .font(.system(size: 13, design: .monospaced))
        }
        .navigationTitle(dictionary.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    hapticFeedback()
                    let text = dictionary.keyData.map { $0.hex.uppercased() }.joined(separator: "\n") + "\n"
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(dictionary.name).dic")
                    try? text.data(using: .utf8)?.write(to: url)
                    shareURL = url
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }
}
