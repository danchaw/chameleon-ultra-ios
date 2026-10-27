import SwiftUI

/// 8-slot manager (port of `gui/page/slot_manager.dart`).
struct SlotManagerView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: CardStore
    @Environment(\.themeAccent) private var themeAccent
    @State private var error: String?
    @State private var busySlot: Int?
    @State private var confirmReset: (Int, TagFrequency)?
    @State private var showExport = false
    @State private var exportURL: URL?
    @State private var aliasSlot: Int?
    @State private var aliasText = ""

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            ForEach(0..<8, id: \.self) { slot in
                Section {
                    slotRow(slot, frequency: .hf)
                    slotRow(slot, frequency: .lf)
                } header: {
                    // slot number stays; alias + editor sit beside it
                    HStack(spacing: 6) {
                        Text(app.activeSlot == slot
                                ? "\(L10n.t("Slot")) \(slot)  •  \(L10n.t("active"))"
                                : "\(L10n.t("Slot")) \(slot)")
                        if !app.slotAliases[slot].isEmpty {
                            Text(app.slotAliases[slot])
                                .foregroundStyle(themeAccent)
                        }
                        Spacer(minLength: 0)
                        Button {
                            aliasText = app.slotAliases[slot]
                            aliasSlot = slot
                        } label: {
                            Image(systemName: app.slotAliases[slot].isEmpty ? "plus.circle" : "pencil.line")
                                .font(.footnote)
                                .foregroundStyle(app.slotAliases[slot].isEmpty ? Color.secondary.opacity(0.6) : themeAccent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(L10n.t("Slot alias"))
                    }
                }
            }
            Section {
                Button {
                    Task { try? await app.communicator?.saveSlotData() }
                } label: {
                    Label(L10n.t("Save slot names to flash"), systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle(L10n.t("Slot manager"))
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { try? await app.refreshSlots() }
        .alert(L10n.t("Reset slot?"), isPresented: resetDialogShown) {
            Button(L10n.t("Reset slot"), role: .destructive) {
                if let (slot, frequency) = confirmReset {
                    Task {
                        do {
                            try await app.communicator?.deleteSlotInfo(slot, frequency: frequency)
                            try await app.refreshSlots()
                        } catch { self.error = error.localizedDescription }
                    }
                }
                confirmReset = nil
            }
            Button(L10n.t("Cancel"), role: .cancel) { confirmReset = nil }
        } message: {
            Text(L10n.t("This clears the slot data on the device."))
        }
        .sheet(isPresented: $showExport) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .alert(L10n.t("Slot alias"), isPresented: aliasDialogShown) {
            TextField(L10n.t("Alias name"), text: $aliasText)
            Button(L10n.t("Save")) {
                if let slot = aliasSlot { app.setSlotAlias(slot, aliasText) }
                aliasSlot = nil
            }
            Button(L10n.t("Clear alias")) {
                if let slot = aliasSlot { app.setSlotAlias(slot, "") }
                aliasSlot = nil
            }
            .tint(themeAccent)
            Button(L10n.t("Cancel"), role: .cancel) { aliasSlot = nil }
        }
    }

    private var resetDialogShown: Binding<Bool> {
        Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } })
    }

    private var aliasDialogShown: Binding<Bool> {
        Binding(get: { aliasSlot != nil }, set: { if !$0 { aliasSlot = nil } })
    }

    @ViewBuilder
    private func slotRow(_ slot: Int, frequency: TagFrequency) -> some View {
        let isHF = frequency == .hf
        let type = isHF ? app.slotTypes[slot].hf : app.slotTypes[slot].lf
        let name = isHF ? app.slotNames[slot].hf : app.slotNames[slot].lf
        let enabled = isHF ? app.slotEnabled[slot].hf : app.slotEnabled[slot].lf

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: isHF ? "waveform" : "antenna.radiowaves.left.and.right")
                    .foregroundStyle(isHF ? .green : .blue)
                Text(isHF ? L10n.t("HF") : L10n.t("LF"))
                    .font(.subheadline.bold())
                // tapping the card name area loads a saved card into the slot
                Menu {
                    ForEach(store.cards.filter { $0.tagType.frequency == frequency }) { card in
                        Button("\(card.name) (\(card.tagType.displayName))") {
                            applyCard(card, to: slot)
                        }
                    }
                    if !name.isEmpty && type != .unknown {
                        Button {
                            Task {
                                try? await app.communicator?.deleteSlotTagNick(slot, frequency: frequency)
                                try? await app.refreshSlots()
                            }
                        } label: {
                            Label(L10n.t("Clear"), systemImage: "xmark")
                        }
                        .tint(themeAccent)
                    }
                } label: {
                    // unconfigured slots always show "无卡片", never blank
                    let showName = !name.isEmpty && type != .unknown
                    Text(showName ? name : L10n.t("No card"))
                        .font(.subheadline)
                        .foregroundStyle(showName ? Color.secondary : Color.secondary.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { newValue in
                        Task {
                            do {
                                try await app.communicator?.enableSlot(slot, frequency: frequency, status: newValue)
                                try await app.refreshSlots()
                            } catch { self.error = error.localizedDescription }
                        }
                    }))
                    .labelsHidden()
            }

            Picker(L10n.t("Tag type"), selection: Binding(
                get: { type },
                set: { newType in
                    guard newType != .unknown else { return }
                    Task {
                        busySlot = slot
                        do {
                            try await app.communicator?.setSlotType(slot, type: newType)
                            try await app.communicator?.setDefaultDataToSlot(slot, type: newType)
                            try await app.refreshSlots()
                        } catch { self.error = error.localizedDescription }
                        busySlot = nil
                    }
                })) {
                Text(L10n.t("Not set")).tag(TagType.unknown)
                ForEach((isHF ? TagType.hfTypes : TagType.lfTypes), id: \.self) { tagType in
                    Text(tagType.displayName).tag(tagType)
                }
            }

            HStack(spacing: 10) {
                Button {
                    confirmReset = (slot, frequency)
                } label: {
                    Text(L10n.t("Reset slot"))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(themeAccent.opacity(0.15), in: Capsule())
                        .foregroundStyle(themeAccent)
                }
                .buttonStyle(PressableButtonStyle())

                if app.activeSlot != slot {
                    Button {
                        Task { await app.activateSlot(slot) }
                    } label: {
                        Text(L10n.t("Activate"))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(themeAccent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                Spacer(minLength: 0)
                if busySlot == slot { ProgressView() }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if type != .unknown {
                Button {
                    exportSlot(slot, mode: .file)
                } label: {
                    Label(L10n.t("Save to file"), systemImage: "doc")
                }
                Button {
                    exportSlot(slot, mode: .newCard)
                } label: {
                    Label(L10n.t("Export to new card"), systemImage: "creditcard")
                }
                if !store.cards.isEmpty {
                    Menu {
                        ForEach(store.cards) { card in
                            Button(card.name) {
                                exportSlot(slot, mode: .updateCard(card))
                            }
                        }
                    } label: {
                        Label(L10n.t("Update saved card…"), systemImage: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
    }

    enum SlotExportMode {
        case file
        case newCard
        case updateCard(CardSave)
    }

    private func exportSlot(_ slot: Int, mode: SlotExportMode) {
        Task {
            busySlot = slot
            do {
                guard var card = try await app.readSlotAsCard(slot: slot) else {
                    error = L10n.t("No dump data")
                    busySlot = nil
                    return
                }
                switch mode {
                case .file:
                    let data = try JSONEncoder().encode([card])
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(card.name.replacingOccurrences(of: "/", with: "_")).json")
                    try data.write(to: url)
                    exportURL = url
                    showExport = true
                case .newCard:
                    store.add(card)
                case .updateCard(let existing):
                    card.id = existing.id
                    card.name = existing.name
                    card.color = existing.color
                    store.update(card)
                }
            } catch {
                self.error = error.localizedDescription
            }
            busySlot = nil
        }
    }


    private func applyCard(_ card: CardSave, to slot: Int) {
        Task {
            busySlot = slot
            do {
                try await app.applyCardToSlot(card, slot: slot)
                // reflect the loaded card in the slot nickname shown next to HF/LF
                try? await app.communicator?.setSlotTagName(slot, name: card.name,
                                                            frequency: card.tagType.frequency)
                try await app.refreshSlots()
            } catch {
                self.error = error.localizedDescription
            }
            busySlot = nil
        }
    }
}
