import SwiftUI

/// Hex dump editor for a card/slot (port of `gui/menu/pages/dump_editor.dart`,
/// simplified): each block is one editable hex line; Save validates and writes back.
struct DumpEditorView: View {
    let title: String
    let blockSize: Int
    var onSave: ([[UInt8]]) -> Void

    @State private var lines: [String]
    @State private var error: String?

    init(title: String, blocks: [[UInt8]], blockSize: Int, onSave: @escaping ([[UInt8]]) -> Void) {
        self.title = title
        self.blockSize = blockSize
        self.onSave = onSave
        _lines = State(initialValue: blocks.map { $0.map { String(format: "%02X", $0) }.joined() })
    }

    var body: some View {
        List {
            if let error {
                Section { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                ForEach(lines.indices, id: \.self) { index in
                    HStack(spacing: 10) {
                        Text(String(format: "%03d", index * blockSize / max(blockSize, 1)))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                        TextField("", text: $lines[index])
                            .font(.system(size: 13, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                    }
                }
            } footer: {
                Text("\(blockSize * 2) hex chars per block")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    save()
                } label: {
                    Text(L10n.t("Save"))
                }
            }
        }
    }

    private func save() {
        var blocks: [[UInt8]] = []
        for (index, line) in lines.enumerated() {
            let clean = line.replacingOccurrences(of: " ", with: "")
            guard clean.count == blockSize * 2, clean.allSatisfy(\.isHexDigit) else {
                error = "\(L10n.t("Invalid hex")) — \(L10n.t("Block")) \(index)"
                return
            }
            blocks.append(Array(Data(hex: clean)))
        }
        error = nil
        onSave(blocks)
    }
}
