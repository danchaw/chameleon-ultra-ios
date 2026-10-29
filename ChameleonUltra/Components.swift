import SwiftUI
import UIKit
import UniformTypeIdentifiers


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
            .modifier(GlassBackgroundModifier())
    }
}

/// Legacy wrapper around the v1.36 card surface — pages migrate to
/// `.lgCard()`, this keeps old call sites compiling with the new look.
struct GlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.clear,
                                in: .rect(cornerRadius: 22, style: .continuous))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                )
        }
    }
}

// MARK: - Haptics

enum Haptics {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - App-wide toast (bound to AppModel.lastError)

struct ToastModifier: ViewModifier {
    @EnvironmentObject var app: AppModel
    @Environment(\.themeAccent) private var themeAccent
    @State private var visible = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if visible, let message = app.lastToast {
                HStack(spacing: 8) {
                    Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(message.isError ? .orange : themeAccent)
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .modificationIndicatorChrome()
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onChange(of: app.lastToast?.id) { _, newID in
            guard newID != nil else { return }
            withAnimation(.snappy) { visible = true }
            Haptics.light()
            Task {
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                withAnimation(.snappy) { visible = false }
                try? await Task.sleep(nanoseconds: 400_000_000)
                if app.lastToast?.id == newID { app.lastToast = nil }
            }
        }
    }
}

/// Capsule material background shared by toast + empty-state chrome.
private struct ModificationIndicatorChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular, in: .capsule)
        } else {
            content
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
    }
}

extension View {
    func modificationIndicatorChrome() -> some View { modifier(ModificationIndicatorChrome()) }
    /// Toast / banner entry point: set `app.lastToast`.
    func appToast() -> some View { modifier(ToastModifier()) }
}

// MARK: - Empty state

struct EmptyState: View {
    let icon: String
    let title: String
    let subtitle: String?
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .lgTile(prominent: true)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
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
        LGMorphScope {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.t("Emulation slot"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                // 8 columns: official devices show one row, 16-slot Mocha firmware two.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(0..<app.slotCount, id: \.self) { slot in
                        Button {
                            guard !animating else { return }
                            animating = true
                            Task {
                                await app.activateSlot(slot)
                                Haptics.light()
                                animating = false
                            }
                        } label: {
                            VStack(spacing: 2) {
                                Text("\(slot)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(app.activeSlot == slot ? themeAccent : .primary)
                                    .lgNumber()
                                HStack(spacing: 3) {
                                    Circle().fill(app.slotEnabled[slot].hf ? .green : Color(.systemGray4)).frame(width: 4, height: 4)
                                    Circle().fill(app.slotEnabled[slot].lf ? .blue : Color(.systemGray4)).frame(width: 4, height: 4)
                                }
                                Text(app.slotAliases[slot])
                                    .font(.system(size: 7))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.6)
                                    .foregroundStyle(.secondary)
                                    .frame(height: 9)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(
                                app.activeSlot == slot
                                    ? AnyShapeStyle(themeAccent.opacity(0.10))
                                    : AnyShapeStyle(Color(.systemBackground).opacity(0.35)),
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .modifier(SlotCellGlass(active: app.activeSlot == slot))
                        .accessibilityLabel("\(L10n.t("Slot")) \(slot)")
                    }
                }
            }
        }
    }

    /// On iOS 26 the active cell carries a tinted glass with a stable morph
    /// ID, so the highlight glides between slots instead of blinking
    /// (Apple "Applying Liquid Glass", example 2).
    private struct SlotCellGlass: ViewModifier {
        let active: Bool
        @Environment(\.lgNamespace) private var ns
        @Environment(\.themeAccent) private var accent

        func body(content: Content) -> some View {
            if #available(iOS 26.0, *), let ns, active {
                content.glassEffect(Glass.regular.tint(accent.opacity(0.45)).interactive(),
                                    in: .rect(cornerRadius: 9, style: .continuous))
                    .glassEffectID("slot.active", in: ns)
            } else {
                content
            }
        }
    }
}
