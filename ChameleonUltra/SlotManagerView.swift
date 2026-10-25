import SwiftUI

/// 8-slot manager (port of `gui/page/slot_manager.dart`).
struct SlotManagerView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: CardStore
    @State private var error: String?
    @State private var busySlot: Int?
    @State private var confirmReset: (Int, TagFrequency)?

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
                if !name.isEmpty {
                    Text(name).foregroundStyle(.secondary)
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

            if !store.cards.filter({ $0.tagType.frequency == frequency }).isEmpty {
                Menu {
                    ForEach(store.cards.filter { $0.tagType.frequency == frequency }) { card in
                        Button("\(card.name) (\(card.tagType.displayName))") {
                            applyCard(card, to: slot)
                        }
                    }
                } label: {
                    Label(L10n.t("Load saved card…"), systemImage: "creditcard")
                        .font(.subheadline)
                }
            }

            HStack {
                Button(role: .destructive) {
                    confirmReset = (slot, frequency)
                } label: {
                    Label(L10n.t("Reset slot"), systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .fixedSize()

                if app.activeSlot != slot {
                    Button {
                        Task { await app.activateSlot(slot) }
                    } label: {
                        Label(L10n.t("Activate"), systemImage: "bolt.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
                }
                Spacer(minLength: 0)
                if busySlot == slot { ProgressView() }
            }
        }
        .padding(.vertical, 2)
    }

    private func applyCard(_ card: CardSave, to slot: Int) {
        Task {
            busySlot = slot
            do {
                try await app.applyCardToSlot(card, slot: slot)
            } catch {
                self.error = error.localizedDescription
            }
            busySlot = nil
        }
    }
}
