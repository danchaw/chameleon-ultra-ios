import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Press feedback

/// Capsule/icon buttons: dim + slight scale while pressed, and a short
/// afterglow on release so a quick tap is clearly visible (the plain
/// press-only effect was too fast to notice).
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }

    private struct PressableBody: View {
        let configuration: Configuration
        @State private var releaseGlow = false

        var body: some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.6 : (releaseGlow ? 0.8 : 1))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .onChange(of: configuration.isPressed) { _, pressed in
                    guard !pressed else { return }
                    releaseGlow = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 130_000_000)
                        withAnimation(.easeOut(duration: 0.16)) { releaseGlow = false }
                    }
                }
        }
    }
}

/// Label whose icon follows the app theme accent color.
struct AccentLabel: View {
    let title: String
    let icon: String
    @Environment(\.themeAccent) private var accent

    init(_ title: String, _ icon: String) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        Label { Text(title) } icon: {
            Image(systemName: icon).foregroundStyle(accent)
        }
    }
}

/// System-gray row highlight: the fill spans the FULL row width and the
/// row's own height, inset slightly so its rounded corners sit cleanly
/// inside the list card (no bleed past card edges like the old rectangle).
/// A short afterglow on release makes quick taps clearly visible.
struct ListRowHighlightStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ListRowHighlightBody(configuration: configuration)
    }

    private struct ListRowHighlightBody: View {
        let configuration: Configuration
        @State private var releaseGlow = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(uiColor: .systemGray4).opacity(0.55))
                        .opacity(configuration.isPressed ? 1 : (releaseGlow ? 0.85 : 0))
                )
                .onChange(of: configuration.isPressed) { _, pressed in
                    guard !pressed else { return }
                    releaseGlow = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        withAnimation(.easeOut(duration: 0.18)) { releaseGlow = false }
                    }
                }
        }
    }
}

private struct ThemeAccentKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var themeAccent: Color {
        get { self[ThemeAccentKey.self] }
        set { self[ThemeAccentKey.self] = newValue }
    }
}

// MARK: - Device photo (official product images from the original project)

struct DeviceImageView: View {
    var device: ChameleonDevice

    var body: some View {
        Image(device == .ultra ? "DeviceUltra" : "DeviceLite")
            .resizable()
            .scaledToFit()
            .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
    }
}

// MARK: - Segmented progress bar (design A: blocks + right percentage)

/// LED-style segmented progress: filled blocks in the theme color, empty
/// blocks as outlined slots, the leading filled block softly pulsing while
/// progress is running. Percentage shown right-aligned in monospaced digits.
struct SegmentedProgress: View {
    let progress: Double          // 0...1
    var count: Int = 22
    @Environment(\.themeAccent) private var accent
    @State private var pulse = false

    private var filled: Int {
        max(0, min(count, Int((Swift.min(max(progress, 0), 1) * Double(count)).rounded(.down))))
    }

    var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                let spacing: CGFloat = 3
                let blockWidth = max(3, (geo.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))
                HStack(spacing: spacing) {
                    ForEach(0..<count, id: \.self) { i in
                        let isFilled = i < filled
                        let isHead = i == filled - 1 && progress > 0 && progress < 1
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(isFilled ? accent : Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .stroke(isFilled ? Color.clear
                                                      : Color.secondary.opacity(0.30), lineWidth: 1)
                            )
                            .opacity(isHead ? (pulse ? 0.55 : 1) : 1)
                            .frame(width: blockWidth, height: geo.size.height)
                    }
                }
            }
            .frame(height: 16)

            Text("\(Int((Swift.min(max(progress, 0), 1) * 100).rounded()))%")
                .font(.subheadline.bold().monospacedDigit())
                .foregroundStyle(accent)
        }
        .animation(pulse ? .easeInOut(duration: 0.6).repeatForever(autoreverses: true) : .default,
                   value: pulse)
        .onAppear { pulse = progress > 0 && progress < 1 }
        .onChange(of: progress) { _, newValue in
            pulse = newValue > 0 && newValue < 1
        }
    }
}

// MARK: - Liquid-glass style card

struct GlassCard<Content: View>: View {
    var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }
}

// MARK: - Color helpers

extension Color {
    init(hexString: String) {
        var value: UInt64 = 0xE64A19
        var sanitized = hexString
        if sanitized.hasPrefix("#") { sanitized.removeFirst() }
        Scanner(string: sanitized).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

let themeColors: [(name: String, hex: String)] = [
    ("Orange", "#E64A19"), ("Green", "#2E7D32"), ("Teal", "#00796B"),
    ("Blue", "#1565C0"), ("Purple", "#6A1B9A"), ("Pink", "#AD1457"),
]

// MARK: - Share sheet (export files)

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Document picker (import files)

struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) }
        }
    }
}

// MARK: - Hex dump viewer

struct HexDumpView: View {
    let blocks: [[UInt8]]
    var blockSize: Int = 16

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                if !block.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        Text(String(format: "%03d", index * blockSize / max(block.count, 1)))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                        Text(block.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - Mifare key check grid (sector x A/B)

struct KeyCheckGridView: View {
    @ObservedObject var recovery: MifareClassicRecovery
    private let columns = [GridItem(.adaptive(minimum: 64), spacing: 6)]

    var body: some View {
        let sectorCount = recovery.sectorCount
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<max(sectorCount, 1), id: \.self) { sector in
                VStack(spacing: 3) {
                    Text("\(sector)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 3) {
                        keyMark(recovery.mark(sector: sector, keyType: 0))
                        keyMark(recovery.mark(sector: sector, keyType: 1))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keyMark(_ mark: KeyCheckmark) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color(for: mark))
            .frame(height: 14)
            .overlay {
                if mark == .checking {
                    ProgressView().controlSize(.mini).tint(.white)
                }
            }
    }

    private func color(for mark: KeyCheckmark) -> Color {
        switch mark {
        case .none: return Color(.systemGray5)
        case .checking: return Color.blue.opacity(0.7)
        case .found: return .green
        case .missing: return .red.opacity(0.75)
        case .disabled: return Color(.systemGray3)
        }
    }
}

// MARK: - Error banner

struct ErrorBanner: View {
    @Binding var message: String?

    var body: some View {
        if let message {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).lineLimit(3)
                Spacer()
                Button {
                    self.message = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .padding(12)
            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.red)
        }
    }
}

// MARK: - Slot picker (horizontal)

struct SlotChanger: View {
    @Environment(\.themeAccent) private var themeAccent
    @EnvironmentObject var app: AppModel
    @State private var animating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("Emulation slot"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { slot in
                    Button {
                        guard !animating else { return }
                        animating = true
                        Task {
                            await app.activateSlot(slot)
                            animating = false
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text("\(slot)")
                                .font(.headline)
                            HStack(spacing: 3) {
                                Circle().fill(app.slotEnabled[slot].hf ? .green : Color(.systemGray4)).frame(width: 5, height: 5)
                                Circle().fill(app.slotEnabled[slot].lf ? .blue : Color(.systemGray4)).frame(width: 5, height: 5)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            app.activeSlot == slot
                                ? AnyShapeStyle(themeAccent.opacity(0.25))
                                : AnyShapeStyle(Color(.systemBackground).opacity(0.5))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            // alias column: one label per slot, same widths as the blocks above
            HStack(spacing: 8) {
                ForEach(0..<8, id: \.self) { slot in
                    Text(app.slotAliases[slot])
                        .font(.system(size: 8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(app.activeSlot == slot ? themeAccent : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, -2)
        }
    }
}
