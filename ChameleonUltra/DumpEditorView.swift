import SwiftUI

/// Hex dump editor with color-coded block kinds and multiple views
/// (HEX / ASCII / ACL / Value / Compare) — port of the original
/// `dump_editor` + `dump_highlighter`, simplified.
struct DumpEditorView: View {

    enum ViewMode: String, CaseIterable, Identifiable {
        case hex, ascii, acl, value, compare
        var id: String { rawValue }
        var label: String {
            switch self {
            case .hex: return "HEX"
            case .ascii: return L10n.t("ASCII")
            case .acl: return L10n.t("ACL")
            case .value: return L10n.t("Value")
            case .compare: return L10n.t("Compare")
            }
        }
    }

    enum BlockKind {
        case manufacturer, data, value, trailer
    }

    let title: String
    let blockSize: Int
    var onSave: ([[UInt8]]) -> Void

    @State private var blocks: [[UInt8]]
    @State private var hexLines: [String]
    @State private var asciiLines: [String]
    @State private var mode: ViewMode = .hex
    @State private var error: String?

    init(title: String, blocks: [[UInt8]], blockSize: Int, onSave: @escaping ([[UInt8]]) -> Void) {
        self.title = title
        self.blockSize = blockSize
        self.onSave = onSave
        _blocks = State(initialValue: blocks)
        _hexLines = State(initialValue: blocks.map { $0.map { String(format: "%02X", $0) }.joined() })
        _asciiLines = State(initialValue: blocks.map { DumpEditorView.asciiString($0) })
    }

    var body: some View {
        List {
            Picker(L10n.t("View"), selection: $mode) {
                ForEach(ViewMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }

            switch mode {
            case .hex: hexSection
            case .ascii: asciiSection
            case .acl: aclSection
            case .value: valueSection
            case .compare: valueSection
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.t("Save")) { save() }
            }
        }
    }

    // MARK: - HEX (editable, color coded)

    private var hexSection: some View {
        Section {
            // legend
            HStack(spacing: 10) {
                legendDot(.blue, L10n.t("Manufacturer"))
                legendDot(.green, L10n.t("Value block"))
                legendDot(.purple, L10n.t("Trailer"))
            }
            .font(.caption2)
            .listRowBackground(Color.clear)

            ForEach(blocks.indices, id: \.self) { index in
                hexRow(index)
            }
        }
    }

    private func hexRow(_ index: Int) -> some View {
        let kind = blockKind(index)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(String(format: "%03d", index))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                kindBadge(kind)
                Spacer(minLength: 0)
                if kind == .trailer {
                    trailerSegments
                }
            }
            TextField("", text: $hexLines[index])
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .padding(6)
                .background(rowTint(kind).opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 2)
    }

    /// KeyA | access | GPB | KeyB proportions inside a trailer row.
    private var trailerSegments: some View {
        HStack(spacing: 2) {
            Capsule().fill(Color.red.opacity(0.65)).frame(width: 18)
            Text(L10n.t("Key A")).font(.system(size: 7)).foregroundStyle(.red)
            Capsule().fill(Color.purple.opacity(0.65)).frame(width: 12)
            Text(L10n.t("ACB")).font(.system(size: 7)).foregroundStyle(.purple)
            Capsule().fill(Color.blue.opacity(0.65)).frame(width: 18)
            Text(L10n.t("Key B")).font(.system(size: 7)).foregroundStyle(.blue)
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
        }
    }

    @ViewBuilder
    private func kindBadge(_ kind: BlockKind) -> some View {
        switch kind {
        case .manufacturer:
            Text(L10n.t("Manufacturer")).font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.blue.opacity(0.2), in: Capsule())
                .foregroundStyle(.blue)
        case .value:
            Text(L10n.t("Value block")).font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.green.opacity(0.2), in: Capsule())
                .foregroundStyle(.green)
        case .trailer:
            Text(L10n.t("Trailer")).font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.purple.opacity(0.2), in: Capsule())
                .foregroundStyle(.purple)
        case .data:
            EmptyView()
        }
    }

    private func rowTint(_ kind: BlockKind) -> Color {
        switch kind {
        case .manufacturer: return .blue
        case .value: return .green
        case .trailer: return .purple
        case .data: return .secondary.opacity(0.1)
        }
    }

    // MARK: - ASCII (editable)

    private var asciiSection: some View {
        Section {
            ForEach(blocks.indices, id: \.self) { index in
                HStack(spacing: 8) {
                    Text(String(format: "%03d", index))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                    TextField("", text: $asciiLines[index])
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                }
            }
        }
    }

    // MARK: - ACL (access conditions, read only)

    private var aclSection: some View {
        Section {
            let trailers = trailerIndices()
            if trailers.isEmpty {
                Text(L10n.t("Not set")).foregroundStyle(.secondary)
            }
            ForEach(trailers, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(L10n.t("Block")) \(index)")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(String(format: "%02X %02X %02X", blocks[index][6], blocks[index][7], blocks[index][8]))
                            .font(.caption.monospaced())
                            .foregroundStyle(.purple)
                    }
                    Text(aclName(blocks[index])).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func aclName(_ trailer: [UInt8]) -> String {
        let a = trailer[6], b = trailer[7], c = trailer[8]
        if a == 0xFF && b == 0x07 && c == 0x80 { return L10n.t("Factory default") }
        if a == 0x78 && b == 0x77 && c == 0x88 { return L10n.t("Open access") }
        return "C1C2C3 —"
    }

    // MARK: - Value / Compare

    private var valueSection: some View {
        Section {
            let values = blocks.indices.filter { blockKind($0) == .value }
            if values.isEmpty {
                Text(L10n.t("No value blocks")).foregroundStyle(.secondary)
            }
            ForEach(values, id: \.self) { index in
                let b = blocks[index]
                let value = Int32(b[0]) | Int32(b[1]) << 8 | Int32(b[2]) << 16 | Int32(b[3]) << 24
                let addr = b[12]
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(L10n.t("Block")) \(index)")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(L10n.t("Value")): \(value)   \(L10n.t("Address")): \(addr)")
                            .font(.caption.monospaced())
                    }
                    if mode == .compare {
                        let valueValid = Array(b[0...3]) == Array(b[8...11])
                            && b[4...7].elementsEqual(b[0...3].map { ~$0 })
                        let addrValid = b[12] == b[14] && b[13] == ~b[12] && b[15] == ~b[12]
                        HStack(spacing: 12) {
                            Label(L10n.t("Value"), systemImage: valueValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(valueValid ? Color.green : Color.red)
                            Label(L10n.t("Address"), systemImage: addrValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(addrValid ? Color.green : Color.red)
                        }
                        .font(.caption2)
                    }
                }
            }
        }
    }

    // MARK: - Save

    private func save() {
        // HEX lines are the source of truth when edited
        var newBlocks: [[UInt8]] = []
        for (index, line) in hexLines.enumerated() {
            let clean = line.replacingOccurrences(of: " ", with: "")
            guard clean.count == blockSize * 2, clean.allSatisfy(\.isHexDigit) else {
                error = "\(L10n.t("Invalid hex")) — \(L10n.t("Block")) \(index)"
                return
            }
            var bytes = Array(Data(hex: clean))
            // apply ASCII edits on top for the same block
            let asciiBytes = asciiBytes(from: asciiLines[index])
            if asciiBytes != DumpEditorView.rawAscii(blocks[index]) {
                bytes = asciiBytes
            }
            newBlocks.append(bytes)
        }
        error = nil
        onSave(newBlocks)
    }

    // MARK: - Block classification

    func blockKind(_ index: Int) -> BlockKind {
        if index == 0 { return .manufacturer }
        if trailerIndices().contains(index) { return .trailer }
        if isValueBlock(blocks[index]) { return .value }
        return .data
    }


    private func trailerIndices() -> [Int] {
        var trailers: [Int] = []
        var sector = 0
        while true {
            let trailer = sector < 32 ? sector * 4 + 3 : 32 * 4 + (sector - 32) * 16 + 15
            if trailer >= blocks.count { break }
            trailers.append(trailer)
            sector += 1
        }
        return trailers
    }

    private func isValueBlock(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        let value = Array(b[0...3])
        let inverted = value.map { ~$0 }
        return Array(b[8...11]) == value
            && Array(b[4...7]) == inverted
            && b[12] == b[14] && b[13] == ~b[12] && b[15] == ~b[12]
    }

    // MARK: - ASCII helpers

    static func asciiString(_ bytes: [UInt8]) -> String {
        String(bytes.map { byte in
            (byte >= 0x20 && byte <= 0x7E) ? Character(UnicodeScalar(byte)) : "."
        })
    }

    static func rawAscii(_ bytes: [UInt8]) -> [UInt8] { bytes }

    private func asciiBytes(from text: String) -> [UInt8] {
        var bytes = Array(text.utf8.prefix(blockSize))
        while bytes.count < blockSize { bytes.append(0x20) }
        return bytes
    }
}
