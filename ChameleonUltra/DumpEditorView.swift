import SwiftUI

/// Hex dump editor: sector-grouped blocks, byte-level color coding with an
/// explanatory legend, plus ASCII / ACL / Value / Compare views
/// (port of the original `dump_editor` + `dump_highlighter`, simplified).
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
    /// read-only compare mode: shows a block-by-block diff against `compareTo`
    var readOnly: Bool = false
    var compareTo: [[UInt8]]? = nil
    var compareName: String = ""
    var onSave: ([[UInt8]]) -> Void = { _ in }

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

    /// Read-only compare entry: diff this dump against another card's dump.
    init(title: String, blocks: [[UInt8]], blockSize: Int,
         compareName: String, compareTo: [[UInt8]]) {
        self.init(title: title, blocks: blocks, blockSize: blockSize, onSave: { _ in })
        self.readOnly = true
        self.compareTo = compareTo
        self.compareName = compareName
        _mode = State(initialValue: .compare)
    }

    var body: some View {
        List {
            if readOnly, compareTo != nil {
                compareSection
            } else {
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
                case .hex: hexSections
                case .ascii: asciiSections
                case .acl: aclSection
                case .value: valueSection
                case .compare: valueSection
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !readOnly {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.t("Save")) { save() }
                }
            }
        }
    }

    // MARK: - Card-to-card diff (read only)

    private func padded(_ block: [UInt8]) -> [UInt8] {
        var b = block
        while b.count < blockSize { b.append(0) }
        return Array(b.prefix(blockSize))
    }

    private var compareStats: (differing: Int, total: Int, differingBytes: Int) {
        guard let other = compareTo else { return (0, 0, 0) }
        let count = max(blocks.count, other.count)
        var differing = 0
        var diffBytes = 0
        for i in 0..<count {
            let mine = padded(i < blocks.count ? blocks[i] : [])
            let theirs = padded(i < other.count ? other[i] : [])
            if mine != theirs {
                differing += 1
                diffBytes += (0..<blockSize).filter { mine[$0] != theirs[$0] }.count
            }
        }
        return (differing, count, diffBytes)
    }

    private var compareSection: some View {
        let stats = compareStats
        let other = compareTo ?? []
        return Group {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tf("%d of %d blocks differ", stats.differing, stats.total))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stats.differing == 0 ? Color.green : Color.orange)
                    Text(L10n.tf("%d bytes differ in total", stats.differingBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            Section {
                ForEach(0..<max(blocks.count, other.count), id: \.self) { index in
                    compareRow(index, other: other)
                }
            } header: {
                Text(L10n.t("Compare with") + " " + compareName)
            }
        }
    }

    private func compareRow(_ index: Int, other: [[UInt8]]) -> some View {
        let mine = padded(index < blocks.count ? blocks[index] : [])
        let theirs = padded(index < other.count ? other[index] : [])
        let isDiff = mine != theirs
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(String(format: "%03d", index))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Text(isDiff ? L10n.t("Different") : L10n.t("Identical"))
                    .font(.system(size: 8, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(isDiff ? Color.red.opacity(0.18) : Color.green.opacity(0.18), in: Capsule())
                    .foregroundStyle(isDiff ? Color.red : Color.green)
                Spacer(minLength: 0)
            }
            Text(diffPreview(mine, other: theirs, showDiff: isDiff))
                .font(.system(size: 11, design: .monospaced))
            Text(diffPreview(theirs, other: mine, showDiff: isDiff))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(isDiff ? Color.red.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
    }

    /// Two colored hex lines (this dump / other dump); differing bytes red.
    private func diffPreview(_ bytes: [UInt8], other: [UInt8], showDiff: Bool) -> AttributedString {
        let mineP = padded(bytes)
        let otherP = padded(other)
        var out = AttributedString()
        for i in 0..<blockSize {
            if i > 0 {
                var sep = AttributedString(i % 4 == 0 ? "  " : " ")
                sep.foregroundColor = .secondary
                out.append(sep)
            }
            var piece = AttributedString(String(format: "%02X", mineP[i]))
            if showDiff {
                piece.foregroundColor = mineP[i] != otherP[i] ? Color.red : Color.secondary
            }
            out.append(piece)
        }
        return out
    }

    // MARK: - Grouping (Mifare Classic: sectors; UL/NTAG: 4-page groups)

    private var groups: [(header: String, indices: [Int])] {
        var result: [(String, [Int])] = []
        if blockSize == 16 {
            var sector = 0
            var start = 0
            while start < blocks.count {
                let count = min(MifareClassic.blockCountInSector(sector: sector), blocks.count - start)
                result.append(("\(L10n.t("Sector")) \(sector)", Array(start..<(start + count))))
                start += count
                sector += 1
            }
        } else {
            var start = 0
            while start < blocks.count {
                let end = min(start + 3, blocks.count - 1)
                result.append(("\(L10n.t("Pages")) \(start)–\(end)", Array(start...end)))
                start += 4
            }
        }
        return result
    }

    // MARK: - HEX (grouped, byte-colored, editable)

    private var hexSections: some View {
        Group {
            legendSection
            ForEach(groups.indices, id: \.self) { g in
                Section(groups[g].header) {
                    ForEach(groups[g].indices, id: \.self) { index in
                        hexRow(index)
                    }
                }
            }
        }
    }

    private var legendSection: some View {
        Section(L10n.t("Legend")) {
            VStack(alignment: .leading, spacing: 10) {
                // block-kind row colors
                HStack(spacing: 12) {
                    blockSwatch(.blue, L10n.t("Manufacturer"))
                    blockSwatch(.green, L10n.t("Value block"))
                    blockSwatch(.purple, L10n.t("Trailer"))
                    Spacer(minLength: 0)
                }
                // trailer byte segments
                Text(L10n.t("Trailer bytes"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    byteSwatch(.red, L10n.t("Key A"))
                    byteSwatch(.purple, L10n.t("Access bits"))
                    byteSwatch(.gray, L10n.t("GPB"))
                    byteSwatch(.blue, L10n.t("Key B"))
                }
                // value block byte segments
                Text(L10n.t("Value block bytes"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    byteSwatch(.green, L10n.t("Value"))
                    byteSwatch(.teal, L10n.t("Address"))
                }
                Text(L10n.t("preview note"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private func blockSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.30))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
                .frame(width: 14, height: 14)
            Text(label).font(.caption2)
        }
    }

    private func byteSwatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            Rectangle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(size: 9))
            Spacer(minLength: 6)
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
            }
            // read-only colored byte preview of the current content
            Text(previewText(index, kind: kind))
                .font(.system(size: 12, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            TextField("", text: $hexLines[index])
                .font(.system(size: 11, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .padding(6)
                .background(rowTint(kind), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 2)
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
        case .manufacturer: return .blue.opacity(0.10)
        case .value: return .green.opacity(0.10)
        case .trailer: return .purple.opacity(0.10)
        case .data: return Color(.tertiarySystemFill)
        }
    }

    /// Live colored hex preview. Reflects the CURRENT text in the edit field,
    /// so the coloring follows the user's typing (once the field is valid hex).
    private func previewText(_ index: Int, kind: BlockKind) -> AttributedString {
        let clean = hexLines[index].replacingOccurrences(of: " ", with: "")
        let bytes: [UInt8]
        if clean.count == blockSize * 2, clean.allSatisfy(\.isHexDigit) {
            bytes = Array(Data(hex: clean))
        } else {
            bytes = blocks[index]
        }
        var out = AttributedString()
        for i in 0..<blockSize {
            if i > 0 {
                var sep = AttributedString(i % 4 == 0 ? "  " : " ")
                sep.foregroundColor = .secondary
                out.append(sep)
            }
            let byte = i < bytes.count ? bytes[i] : 0
            var piece = AttributedString(String(format: "%02X", byte))
            piece.foregroundColor = byteColor(byte: i, kind: kind)
            out.append(piece)
        }
        return out
    }

    private func byteColor(byte: Int, kind: BlockKind) -> Color {
        switch kind {
        case .manufacturer:
            return .blue
        case .trailer:
            if byte < 6 { return .red }                     // Key A
            if byte < 9 { return .purple }                  // access bits C1-C3
            if byte == 9 { return .gray }                   // GPB
            return .blue                                    // Key B
        case .value:
            if byte < 12 { return .green }                  // value / inverse / duplicate
            return .teal                                    // address + guards
        case .data:
            return .primary
        }
    }

    // MARK: - ASCII (grouped, editable)

    private var asciiSections: some View {
        ForEach(groups.indices, id: \.self) { g in
            Section(groups[g].header) {
                ForEach(groups[g].indices, id: \.self) { index in
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
    }

    // MARK: - ACL (per sector)

    private var aclSection: some View {
        Section {
            let trailers = trailerIndices()
            if trailers.isEmpty {
                Text(L10n.t("Not set")).foregroundStyle(.secondary)
            }
            ForEach(trailers, id: \.self) { index in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(L10n.t("Sector")) \(MifareClassic.sectorByBlock(index))")
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
                        Text("\(L10n.t("Block")) \(index) · \(L10n.t("Sector")) \(MifareClassic.sectorByBlock(index))")
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
        if trailerSet.contains(index) { return .trailer }
        if isValueBlock(blocks[index]) { return .value }
        return .data
    }

    private var trailerSet: Set<Int> { Set(trailerIndices()) }

    private func trailerIndices() -> [Int] {
        guard blockSize == 16 else { return [] }
        var trailers: [Int] = []
        var sector = 0
        while true {
            let trailer = MifareClassic.sectorTrailerBlock(sector: sector)
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
