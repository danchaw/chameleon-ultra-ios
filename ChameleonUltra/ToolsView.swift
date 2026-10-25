import SwiftUI
import UIKit

/// Tools page (port of `gui/page/tools.dart`): T55xx password cleaner,
/// LF sniffing, HF sniffing.
struct ToolsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        List {
            Section(L10n.t("Sniffing")) {
                NavigationLink {
                    SniffingView(isLF: true)
                } label: {
                    Label(L10n.t("LF sniffing (125 kHz)"), systemImage: "waveform.path")
                        .foregroundStyle(.blue)
                }
                NavigationLink {
                    SniffingView(isLF: false)
                } label: {
                    Label(L10n.t("HF sniffing (13.56 MHz)"), systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }
            }
            Section(L10n.t("Tag tools")) {
                NavigationLink {
                    T55XXPasswordCleanerView()
                } label: {
                    Label(L10n.t("T55xx password cleaner"), systemImage: "password")
                }
                NavigationLink {
                    DictionaryDownloadView()
                } label: {
                    Text(L10n.t("Dictionary download"))
                }
            }
            Section {
                Label("Mifare Classic Gen4 config is not available in this build.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.t("Tools"))
    }
}

// MARK: - Sniffing

struct SniffingView: View {
    @EnvironmentObject var app: AppModel
    let isLF: Bool
    @State private var result: Data?
    @State private var running = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ErrorBanner(message: $error)
                GlassCard {
                    VStack(spacing: 12) {
                        Image(systemName: isLF ? "waveform.path" : "dot.radiowaves.left.and.right")
                            .font(.system(size: 36))
                            .foregroundStyle(.tint)
                        Text(isLF
                             ? "Capture LF signal while a reader talks to a tag."
                             : "Capture HF traffic between reader and tag.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            Task { await sniff() }
                        } label: {
                            Label(running ? L10n.t("Sniffing…") : L10n.t("Start sniff"), systemImage: "record.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(running || !app.isConnected)
                    }
                }

                if let result {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Captured data (\(result.count) bytes)").font(.headline)
                                Spacer()
                                Button {
                                    UIPasteboard.general.string = result.hexSpaced
                                } label: {
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                            if result.isEmpty {
                                Text("Nothing captured.").foregroundStyle(.secondary)
                            } else {
                                Text(result.hexSpaced)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(isLF ? "LF sniffing" : "HF sniffing")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sniff() async {
        guard let communicator = app.communicator else { return }
        running = true
        error = nil
        result = nil
        do {
            result = isLF
                ? try await communicator.lfSniff(timeoutMs: 5000)
                : try await communicator.hf14aSniff(timeoutMs: 5000)
        } catch {
            self.error = error.localizedDescription
        }
        running = false
    }
}

// MARK: - T55xx password cleaner

struct T55XXPasswordCleanerView: View {
    @EnvironmentObject var app: AppModel
    @State private var password = "00000000"
    @State private var newTestPassword = "51243648"
    @State private var message: String?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section {
                TextField("Old password (hex, 8 chars)", text: $password)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                TextField("New password to set (hex, 8 chars)", text: $newTestPassword)
                    .font(.system(size: 14, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
            } footer: {
                Text("Resets a password-protected T55xx tag to factory defaults by writing the default configuration to page 0 with the given old password. Leave 00000000 for tags without a password.")
            }
            Section {
                Button {
                    Task { await clean() }
                } label: {
                    if busy { ProgressView() } else { Label(L10n.t("Reset tag"), systemImage: "arrow.counterclockwise.circle.fill") }
                }
                .disabled(busy)
            }
            if let message {
                Section { Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(L10n.t("T55xx cleaner"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clean() async {
        guard let communicator = app.communicator else { return }
        busy = true
        error = nil
        message = nil
        do {
            let old = Data(hex: password)
            let new = Data(hex: newTestPassword)
            guard old.count == 4, new.count == 4 else {
                throw ChameleonError.invalidResponse("Passwords must be 8 hex characters")
            }
            // default T55xx configuration word + reset
            try await communicator.writeT55XX(block: 0, word: Data([0x00, 0x00, 0x80, 0x40]), password: old.allSatisfy({ $0 == 0 }) ? nil : old)
            message = "Reset command sent"
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}

// MARK: - Dictionary download (same five sources as the original app)

struct DictionaryDownloadView: View {
    @EnvironmentObject var store: CardStore

    /// name / url pairs identical to `dictionary_download.dart`
    private let sources: [(name: String, urlString: String)] = [
        ("Proxmark3 (Mifare Classic)",
         "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfc_default_keys.dic"),
        ("Proxmark3 (T55XX)",
         "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/t55xx_default_pwds.dic"),
        ("Proxmark3 (Mifare Ultralight C)",
         "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfulc_default_keys.dic"),
        ("Proxmark3 (Mifare Plus)",
         "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfp_default_keys.dic"),
        ("Flipper Zero Unleashed Firmware (Mifare Classic)",
         "https://raw.githubusercontent.com/DarkFlippers/unleashed-firmware/refs/heads/dev/applications/main/nfc/resources/nfc/assets/mf_classic_dict.nfc"),
    ]

    @State private var downloadingIndex: Int? = nil
    @State private var results: [Int: String] = [:]

    var body: some View {
        List {
            Section {
                ForEach(sources.indices, id: \.self) { index in
                    row(index)
                }
            }
        }
        .navigationTitle(L10n.t("Dictionary download"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ index: Int) -> some View {
        let source = sources[index]
        let isDownloaded = store.dictionaries.contains { $0.name == source.name }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.subheadline)
                if let result = results[index] {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.red)
                }
            }
            Spacer(minLength: 8)
            if downloadingIndex == index {
                ProgressView()
            } else if isDownloaded {
                Text(L10n.t("Downloaded"))
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Button {
                    download(index)
                } label: {
                    Text(L10n.t("Download"))
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.vertical, 2)
    }

    private func download(_ index: Int) {
        let source = sources[index]
        guard let url = URL(string: source.urlString) else { return }
        hapticFeedback()
        downloadingIndex = index
        Task {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                let (data, _) = try await URLSession.shared.data(for: request)
                let text = String(data: data, encoding: .utf8) ?? ""
                var dictionary = KeyDictionary.fromText(text, name: source.name)
                dictionary.name = source.name
                guard !dictionary.keys.isEmpty else {
                    results[index] = "✗ " + L10n.t("Download failed")
                    downloadingIndex = nil
                    return
                }
                store.add(dictionary: dictionary)
                results[index] = "✓ \(dictionary.keys.count) \(L10n.t("keys imported"))"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                results[index] = "✗ " + L10n.t("Download failed")
            }
            downloadingIndex = nil
        }
    }
}
