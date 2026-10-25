import SwiftUI

/// 8-slot manager (port of `gui/page/slot_manager.dart`).
struct SlotManagerView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var store: CardStore
    @State private var error: String?
    @State private var busySlot: Int?

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
            ForEach(0..<8, id: \.self) { slot in
                Section(app.activeSlot == slot ? "Slot \(slot)  •  active" : "Slot \(slot)") {
                    slotRow(slot, frequency: .hf)
                    slotRow(slot, frequency: .lf)
                }
            }
            Section {
                Button {
                    Task { try? await app.communicator?.saveSlotData() }
                } label: {
                    Label("Save slot names to flash", systemImage: "square.and.arrow.down")
                }
            }
        }
        .navigationTitle("Slot manager")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { try? await app.refreshSlots() }
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
                Text(isHF ? "HF" : "LF")
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

            Picker("Tag type", selection: Binding(
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
                Text("Not set").tag(TagType.unknown)
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
                    Label("Load saved card…", systemImage: "creditcard")
                        .font(.subheadline)
                }
            }

            HStack {
                Button {
                    Task {
                        do {
                            try await app.communicator?.deleteSlotInfo(slot, frequency: frequency)
                            try await app.refreshSlots()
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Label("Reset slot", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                if app.activeSlot != slot {
                    Button {
                        Task { await app.activateSlot(slot) }
                    } label: {
                        Label("Activate", systemImage: "bolt.fill")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderedProminent)
                }
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
