import SwiftUI

/// 8-slot manager (port of `gui/page/slot_manager.dart`).
struct SlotManagerView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: CardStore
    @State private var error: String?
    @State private var busySlot: Int?
    @State private var confirmReset: (Int, TagFrequency)?
    @State private var showExport = false
    @State private var exportURL: URL?

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            ForEach(0..<8, id: \.self) { slot in
                Section(app.activeSlot == slot
                        ? "\(L10n.t("Slot")) \(slot)  •  \(L10n.t("active"))"
                        : "\(L10n.t("Slot")) \(slot)") {
                    slotRow(slot, frequency: .hf)
                    slotRow(slot, frequency: .lf)
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
    }

    private var resetDialogShown: Binding<Bool> {
        Binding(get: { confirmReset != nil }, set: { if !$0 { confirmReset = nil } })
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
                    if !name.isEmpty {
                        Button(role: .destructive) {
                            Task {
                                try? await app.communicator?.deleteSlotTagNick(slot, frequency: frequency)
                                try? await app.refreshSlots()
                            }
                        } label: {
                            Label(L10n.t("Clear nickname"), systemImage: "xmark")
                        }
                    }
                } label: {
                    Text(name.isEmpty ? L10n.t("Load card…") : name)
                        .font(name.isEmpty ? .subheadline : .subheadline)
                        .foregroundStyle(name.isEmpty ? Color.accentColor.opacity(0.75) : Color.secondary)
                        .lineLimit(1)
                }
                .disabled(store.cards.filter { $0.tagType.frequency == frequency }.isEmpty && name.isEmpty)
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
                    hapticFeedback()
                    confirmReset = (slot, frequency)
                } label: {
                    Text(L10n.t("Reset slot"))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.red.opacity(0.15), in: Capsule())
                        .foregroundStyle(.red)
                }
                .buttonStyle(PressableButtonStyle())

                if app.activeSlot != slot {
                    Button {
                        hapticFeedback()
                        Task { await app.activateSlot(slot) }
                    } label: {
                        Text(L10n.t("Activate"))
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.accentColor, in: Capsule())
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
        hapticFeedback()
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
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                case .updateCard(let existing):
                    card.id = existing.id
                    card.name = existing.name
                    card.color = existing.color
                    store.update(card)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
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
