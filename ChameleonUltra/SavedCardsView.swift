import SwiftUI

/// Saved cards browser (port of `gui/page/saved_cards.dart`).
struct SavedCardsView: View {
    @EnvironmentObject var store: CardStore
    @EnvironmentObject var app: AppModel
    @State private var search = ""
    @State private var showImporter = false
    @State private var message: String?

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
                    let targets = indexSet.map { filtered[$0] }
                    targets.forEach { store.delete($0) }
                }
            }
        }
        .searchable(text: $search, prompt: "Search name, UID or type")
        .navigationTitle("Saved cards")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showImporter = true
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
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
                    message = count > 0 ? "Imported \(count) card(s)" : "No compatible cards found in file"
                }
            }
        }
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

    private var blockSize: Int { card.isMifareClassic ? 16 : 4 }

    var body: some View {
        List {
            Section("Card") {
                TextField("Name", text: $editableName, onCommit: saveName)
                LabeledContent("Type", value: card.displayType)
                LabeledContent("UID", value: card.uid.uppercased())
                if card.tagType.frequency == .hf {
                    LabeledContent("SAK", value: String(format: "%02X", card.sak))
                    LabeledContent("ATQA", value: card.atqa.map { String(format: "%02X", $0) }.joined(separator: " "))
                    if !card.ats.isEmpty {
                        LabeledContent("ATS", value: card.ats.map { String(format: "%02X", $0) }.joined(separator: " "))
                    }
                }
                LabeledContent("Blocks", value: "\(card.data.count)")
            }

            if !card.data.isEmpty {
                Section("Dump") {
                    HexDumpView(blocks: card.data, blockSize: blockSize)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }
            }

            Section {
                if app.isConnected {
                    Button {
                        showApplySheet = true
                    } label: {
                        Label("Apply to device slot…", systemImage: "square.grid.3x3")
                    }
                } else {
                    Label("Connect a device to emulate this card", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Export") {
                Button {
                    export(json: true)
                } label: {
                    Label("Export as JSON", systemImage: "curlybraces.square")
                }
                Button {
                    export(json: false)
                } label: {
                    Label("Export as binary dump", systemImage: "doc.binary")
                }
            }

            Section("Danger zone") {
                Button(role: .destructive) {
                    store.delete(card)
                } label: {
                    Label("Delete card", systemImage: "trash")
                }
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
    }

    private var applySheet: some View {
        NavigationStack {
            List(0..<8, id: \.self) { slot in
                Button("Slot \(slot)  (\(app.slotTypes[slot].hf.displayName) / \(app.slotTypes[slot].lf.displayName))") {
                    Task {
                        do {
                            try await app.applyCardToSlot(card, slot: slot)
                            message = "Applied to slot \(slot)"
                        } catch {
                            message = error.localizedDescription
                        }
                        showApplySheet = false
                    }
                }
            }
            .navigationTitle("Choose slot")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
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
}

// MARK: - Dictionary manager

struct DictionaryManagerView: View {
    @EnvironmentObject var store: CardStore
    @State private var newText = ""
    @State private var newName = ""
    @State private var showAdd = false
    @State private var showImporter = false

    var body: some View {
        List {
            Section {
                ForEach(store.dictionaries) { dict in
                    NavigationLink {
                        DictionaryDetailView(dictionary: dict)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(dict.name).font(.headline)
                            Text("\(dict.keys.count) keys")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { indexSet in
                    indexSet.map { store.dictionaries[$0] }.forEach { store.delete(dictionary: $0) }
                }
            }
        }
        .navigationTitle("Dictionaries")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: { Image(systemName: "square.and.arrow.down") }
            }
        }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                Form {
                    TextField("Name", text: $newName)
                    Section("Keys (one hex key per line)") {
                        TextEditor(text: $newText)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(minHeight: 180)
                    }
                }
                .navigationTitle("New dictionary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showAdd = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add") {
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
            DocumentPicker(contentTypes: [.plainText, .json]) { url in
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let name = url.deletingPathExtension().lastPathComponent
                    let dict = KeyDictionary.fromText(text, name: name)
                    guard !dict.keys.isEmpty else { return }
                    store.add(dictionary: dict)
                }
            }
        }
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
        }
        .sheet(isPresented: $showShare) {
            if let shareURL { ShareSheet(items: [shareURL]) }
        }
    }
}
