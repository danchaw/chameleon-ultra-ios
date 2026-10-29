import SwiftUI
import UniformTypeIdentifiers

/// Saved cards browser (port of `gui/page/saved_cards.dart`).
struct SavedCardsView: View {
    @EnvironmentObject var store: CardStore
    @EnvironmentObject var app: AppModel
    @Environment(\.themeAccent) private var themeAccent
    @State private var search = ""
    @State private var showImporter = false
    @State private var message: String?
    @State private var pendingDelete: [CardSave]?
    // batch selection mode: tap rows to toggle, select-all, delete selected
    @State private var selectMode = false
    @State private var selection = Set<UUID>()
    @State private var confirmBatchDelete = false

    var body: some View {
        List {
            if let message {
                Section { Text(message).foregroundStyle(.secondary).font(.footnote) }
            }
            Section {
                ForEach(filtered) { card in
                    if selectMode {
                        Button {
                            toggle(card.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selection.contains(card.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(card.id) ? Color.accentColor : Color(.systemGray3))
                                cardRow(card)
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                    NavigationLink {
                        CardDetailView(card: card)
                    } label: {
                        cardRow(card)
                    }
                    .contextMenu {
                        Button {
                            var copy = card
                            copy.id = UUID()
                            copy.name = card.name + " " + L10n.t("Copy")
                            store.add(copy)
                        } label: {
                            AccentLabel(L10n.t("Duplicate card"), "plus.square.on.square")
                        }
                        Button(role: .destructive) {
                            pendingDelete = [card]
                        } label: {
                            AccentLabel(L10n.t("Delete card"), "trash")
                        }
                    }
                    }
                }
                .onDelete { indexSet in
                    pendingDelete = indexSet.map { filtered[$0] }
                }
            }
        }
        .searchable(text: $search, prompt: L10n.t("name, UID or type"))
        .refreshable {
            Haptics.light()
            try? await app.refreshSlots()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        .navigationTitle(L10n.t("Saved cards"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectMode {
                    Button(L10n.t("Cancel")) { exitSelectMode() }
                } else {
                    Button(L10n.t("Select")) { selectMode = true }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if selectMode {
                    Button(selection.count == filtered.count && !filtered.isEmpty
                            ? L10n.t("Deselect all") : L10n.t("Select all")) {
                        toggleSelectAll()
                    }
                    .disabled(filtered.isEmpty)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selectMode {
                    Button("\(L10n.t("Delete")) (\(selection.count))", role: .destructive) {
                        confirmBatchDelete = true
                    }
                    .tint(themeAccent)
                    .disabled(selection.isEmpty)
                } else {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down.on.square")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !selectMode {
                    NavigationLink {
                        DictionaryManagerView()
                    } label: {
                        Image(systemName: "key.horizontal")
                    }
                }
            }
        }
        .contextMenu {
            Button {
                showImporter = true
            } label: {
                AccentLabel(L10n.t("Import cards"), "square.and.arrow.down.on.square")
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(contentTypes: [.json, UTType(filenameExtension: "bin") ?? .data, .data]) { url in
                if let data = try? Data(contentsOf: url) {
                    let count = store.importCards(from: data)
                    if count > 0 { app.toast("✓ \(count) \(L10n.t("Imported"))") }
                    else { app.toast(L10n.t("No compatible cards found in file"), isError: true) }
                }
            }
        }
        .alert(L10n.t("Confirm deletion"), isPresented: deleteDialogShown) {
            Button(L10n.t("Delete"), role: .destructive) {
                pendingDelete?.forEach { store.delete($0) }
                pendingDelete = nil
            }
            Button(L10n.t("Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(L10n.t("This cannot be undone."))
        }
        .alert(L10n.t("Confirm deletion"), isPresented: $confirmBatchDelete) {
            Button(L10n.t("Delete"), role: .destructive) {
                let doomed = store.cards.filter { selection.contains($0.id) }
                doomed.forEach { store.delete($0) }
                exitSelectMode()
            }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: {
            Text("\(L10n.t("Delete")) \(selection.count) · \(L10n.t("This cannot be undone."))")
        }
    }

    // MARK: - Batch selection helpers

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleSelectAll() {
        if selection.count == filtered.count {
            selection.removeAll()
        } else {
            selection = Set(filtered.map(\.id))
        }
    }

    private func exitSelectMode() {
        selectMode = false
        selection.removeAll()
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
                Text("\(card.displayType) · \(card.uidData.hexSpaced.isEmpty ? card.uid.uppercased() : card.uidData.hexSpaced)")
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
    // card actions
    @State private var showEditSheet = false
    @State private var editName = ""
    @State private var editUID = ""
    @State private var showSaveAsSheet = false
    @State private var saveAsName = ""
    @State private var saveAsJSON = true
    @State private var showComparePicker = false
    @State private var compareTarget: CardSave?

    /// Same block size, not this card — those are the only comparable dumps.
    private var compareCandidates: [CardSave] {
        store.cards.filter { $0.id != card.id && ($0.isMifareClassic == card.isMifareClassic) }
    }

    private var compareCandidatesList: some View {
        NavigationStack {
            Group {
                if compareCandidates.isEmpty {
                    Label(L10n.t("No comparable cards"), systemImage: "tray")
                        .foregroundStyle(.secondary)
                } else {
                    List(compareCandidates) { candidate in
                        NavigationLink {
                            DumpEditorView(
                                title: "\(card.name) ↔ \(candidate.name)",
                                blocks: card.data.isEmpty
                                    ? Array(repeating: [UInt8](repeating: 0, count: blockSize), count: card.tagType.blockCount)
                                    : card.data,
                                blockSize: blockSize,
                                compareName: candidate.name,
                                compareTo: candidate.data.isEmpty
                                    ? Array(repeating: [UInt8](repeating: 0, count: blockSize), count: candidate.tagType.blockCount)
                                    : candidate.data)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name).font(.headline)
                                Text("\(candidate.displayType) · \(candidate.data.count) \(L10n.t("Blocks"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.t("Select a card to compare"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var blockSize: Int { card.isMifareClassic ? 16 : 4 }

    var body: some View {
        List {
            Section(L10n.t("Card")) {
                TextField(L10n.t("Name"), text: $editableName, onCommit: saveName)
                LabeledContent(L10n.t("Type"), value: card.displayType)
                LabeledContent("UID", value: card.uidData.hexSpaced.isEmpty ? card.uid.uppercased() : card.uidData.hexSpaced)
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
                        showApplySheet = true
                    } label: {
                        HStack {
                            AccentLabel(L10n.t("Apply to device slot…"), "square.grid.3x3")
                            Spacer()
                            if applyingSlot != nil { ProgressView() }
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Label(L10n.t("Connect a device to emulate this card"), systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("Export")) {
                Button {
                    export(json: true)
                } label: {
                    AccentLabel(L10n.t("Export as JSON"), "curlybraces.square")
                }
                .buttonStyle(.plain)

                Button {
                    export(json: false)
                } label: {
                    AccentLabel(L10n.t("Export as binary dump"), "doc.zipper")
                }
                .buttonStyle(.plain)

                if card.isMifareClassic && !card.dumpKeys.isEmpty {
                    Menu {
                        Button {
                            exportDumpKeys(saveToDictionaries: true)
                        } label: {
                            AccentLabel(L10n.t("Save to dictionaries"), "book")
                        }
                        Button {
                            exportDumpKeys(saveToDictionaries: false)
                        } label: {
                            AccentLabel(L10n.t("Share as .dic"), "square.and.arrow.up")
                        }
                    } label: {
                        AccentLabel(L10n.t("Export keys from dump"), "key.horizontal")
                    }
                    .buttonStyle(.plain)
                }
            }

            Section(L10n.t("Card actions")) {
                Button {
                    editName = card.name
                    editUID = card.uid
                    showEditSheet = true
                } label: {
                    AccentLabel(L10n.t("Edit card"), "pencil")
                }
                .buttonStyle(.plain)

                Button {
                    duplicateCard()
                } label: {
                    AccentLabel(L10n.t("Duplicate card"), "plus.square.on.square")
                }
                .buttonStyle(.plain)

                NavigationLink {
                    DumpEditorView(title: card.name,
                                   blocks: card.data.isEmpty
                                       ? Array(repeating: [UInt8](repeating: 0, count: blockSize), count: card.tagType.blockCount)
                                       : card.data,
                                   blockSize: blockSize) { newBlocks in
                        card.data = newBlocks
                        store.update(card)
                    }
                } label: {
                    AccentLabel(L10n.t("Dump editor"), "square.and.pencil")
                }

                Button {
                    showComparePicker = true
                } label: {
                    AccentLabel(L10n.t("Compare dump…"), "square.split.2x1")
                }
                .buttonStyle(.plain)
                .disabled(compareCandidates.isEmpty)

                Button {
                    saveAsName = card.name
                    saveAsJSON = true
                    showSaveAsSheet = true
                } label: {
                    AccentLabel(L10n.t("Save as…"), "wand.and.stars")
                }
                .buttonStyle(.plain)
            }

            Section(L10n.t("Danger zone")) {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    AccentLabel(L10n.t("Delete card"), "trash")
                }
                .buttonStyle(.plain)
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
        .sheet(isPresented: $showEditSheet) { editSheet }
        .sheet(isPresented: $showSaveAsSheet) { saveAsSheet }
        .sheet(isPresented: $showComparePicker) { compareCandidatesList }
        .alert(L10n.t("Confirm deletion"), isPresented: $showDeleteConfirm) {
            Button(L10n.t("Delete"), role: .destructive) {
                store.delete(card)
            }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text("\(L10n.t("Delete this card?")) \(L10n.t("This cannot be undone."))")
        }
    }

    private var applySheet: some View {
        NavigationStack {
            List(0..<app.slotCount, id: \.self) { slot in
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
                .buttonStyle(.plain)
                .disabled(applyingSlot != nil)
            }
            .navigationTitle(L10n.t("Choose slot"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    private func apply(to slot: Int) {
        applyingSlot = slot
        Task {
            do {
                try await app.applyCardToSlot(card, slot: slot)
                applyingSlot = -slot - 1   // done marker
                message = L10n.tf("Applied to slot %d", slot)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                showApplySheet = false
            } catch {
                message = error.localizedDescription
                showApplySheet = false
            }
            applyingSlot = nil
        }
    }

    private func saveName() {
        card.name = editableName
        store.update(card)
    }

    private func duplicateCard() {
        var copy = card
        copy.id = UUID()
        copy.name = card.name + " " + L10n.t("Copy")
        store.add(copy)
        app.toast(L10n.t("Copy"))
    }

    private var editSheet: some View {
        NavigationStack {
            Form {
                TextField(L10n.t("Name"), text: $editName)
                TextField("UID", text: $editUID)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            }
            .navigationTitle(L10n.t("Edit card"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { showEditSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save")) {
                        card.name = editName
                        let uid = editUID.replacingOccurrences(of: " ", with: "")
                        if !uid.isEmpty { card.uid = uid }
                        store.update(card)
                        showEditSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var saveAsSheet: some View {
        NavigationStack {
            Form {
                TextField(L10n.t("Name"), text: $saveAsName)
                Picker(L10n.t("Save as…"), selection: $saveAsJSON) {
                    Text(L10n.t("JSON")).tag(true)
                    Text(L10n.t("Binary")).tag(false)
                }
                .pickerStyle(.segmented)
            }
            .navigationTitle(L10n.t("Save as…"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("Cancel")) { showSaveAsSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("Save")) {
                        showSaveAsSheet = false
                        var asCard = card
                        asCard.name = saveAsName.isEmpty ? card.name : saveAsName
                        do {
                            let ext = saveAsJSON ? "json" : "bin"
                            let url = FileManager.default.temporaryDirectory
                                .appendingPathComponent("\(asCard.name.replacingOccurrences(of: "/", with: "_")).\(ext)")
                            if saveAsJSON {
                                try JSONEncoder().encode([asCard]).write(to: url)
                            } else {
                                try asCard.binaryDump.write(to: url)
                            }
                            shareURL = url
                            showShare = true
                        } catch {
                            message = error.localizedDescription
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium])
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
    @Environment(\.themeAccent) private var themeAccent
    @State private var newText = ""
    @State private var newName = ""
    @State private var showAdd = false
    @State private var showImporter = false
    @State private var pendingDeleteDict: KeyDictionary?
    @State private var selectMode = false
    @State private var selection = Set<UUID>()
    @State private var confirmBatchDelete = false

    var body: some View {
        List {
            Section {
                ForEach(store.dictionaries) { dict in
                    if selectMode {
                        Button {
                            toggle(dict.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: selection.contains(dict.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selection.contains(dict.id) ? Color.accentColor : Color(.systemGray3))
                                VStack(alignment: .leading) {
                                    Text(dict.name).font(.headline)
                                    Text("\(dict.keys.count) \(L10n.t("keys"))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
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
                }
                .onDelete { indexSet in
                    pendingDeleteDict = indexSet.map { store.dictionaries[$0] }.first
                }
            }
        }
        .navigationTitle(L10n.t("Dictionaries"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if selectMode {
                    Button(L10n.t("Cancel")) { exitSelectMode() }
                } else {
                    Button(L10n.t("Select")) { selectMode = true }
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if selectMode {
                    Button(selection.count == store.dictionaries.count && !store.dictionaries.isEmpty
                            ? L10n.t("Deselect all") : L10n.t("Select all")) {
                        toggleSelectAll()
                    }
                    .disabled(store.dictionaries.isEmpty)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if selectMode {
                    Button("\(L10n.t("Delete")) (\(selection.count))", role: .destructive) {
                        confirmBatchDelete = true
                    }
                    .tint(themeAccent)
                    .disabled(selection.isEmpty)
                } else {
                    Button {
                        showAdd = true
                    } label: { Image(systemName: "plus") }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !selectMode {
                    Button {
                        showImporter = true
                    } label: { Image(systemName: "square.and.arrow.down") }
                }
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
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(contentTypes: [.plainText, .json, UTType(filenameExtension: "dic") ?? .data, UTType(filenameExtension: "txt") ?? .data, .data]) { url in
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let name = url.deletingPathExtension().lastPathComponent
                    let dict = KeyDictionary.fromText(text, name: name)
                    guard !dict.keys.isEmpty else { return }
                    store.add(dictionary: dict)
                }
            }
        }
        .alert(L10n.t("Confirm deletion"), isPresented: deleteDictShown) {
            Button(L10n.t("Delete"), role: .destructive) {
                if let dict = pendingDeleteDict { store.delete(dictionary: dict) }
                pendingDeleteDict = nil
            }
            Button(L10n.t("Cancel"), role: .cancel) { pendingDeleteDict = nil }
        } message: {
            Text("\(L10n.t("Delete this dictionary?")) \(L10n.t("This cannot be undone."))")
        }
        .alert(L10n.t("Confirm deletion"), isPresented: $confirmBatchDelete) {
            Button(L10n.t("Delete"), role: .destructive) {
                let doomed = store.dictionaries.filter { selection.contains($0.id) }
                doomed.forEach { store.delete(dictionary: $0) }
                exitSelectMode()
            }
            Button(L10n.t("Cancel"), role: .cancel) { }
        } message: {
            Text("\(L10n.t("Delete")) \(selection.count) · \(L10n.t("This cannot be undone."))")
        }
    }

    private var deleteDictShown: Binding<Bool> {
        Binding(get: { pendingDeleteDict != nil }, set: { if !$0 { pendingDeleteDict = nil } })
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func toggleSelectAll() {
        if selection.count == store.dictionaries.count {
            selection.removeAll()
        } else {
            selection = Set(store.dictionaries.map(\.id))
        }
    }

    private func exitSelectMode() {
        selectMode = false
        selection.removeAll()
    }
}

struct DictionaryDetailView: View {
    @EnvironmentObject var store: CardStore
    @Environment(\.dismiss) private var dismiss
    let dictionary: KeyDictionary
    @State private var showShare = false
    @State private var shareURL: URL?
    @State private var confirmDelete = false

    var body: some View {
        List(dictionary.keys, id: \.self) { key in
            Text(key.map { String(format: "%02X", $0) }.joined(separator: ""))
                .font(.system(size: 13, design: .monospaced))
        }
        .navigationTitle(dictionary.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    let text = dictionary.keyData.map { $0.hex.uppercased() }.joined(separator: "\n") + "\n"
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(dictionary.name).dic")
                    try? text.data(using: .utf8)?.write(to: url)
                    shareURL = url
                    showShare = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
        .alert(L10n.t("Confirm deletion"), isPresented: $confirmDelete) {
            Button(L10n.t("Delete"), role: .destructive) {
                store.delete(dictionary: dictionary)
                dismiss()
            }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text("\(L10n.t("Delete this dictionary?")) \(L10n.t("This cannot be undone."))")
        }
    }
}
