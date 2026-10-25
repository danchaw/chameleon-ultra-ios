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
                    Label(L10n.t("Dictionary download"), systemImage: "arrow.down.circle")
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

// MARK: - Dictionary download (same sources as the original app)

struct DictionaryDownloadSource: Identifiable {
    let id: String
    let nameKey: String
    let url: URL
}

/// Downloads the same external dictionaries as the original app
/// (`gui/menu/tools/dictionary_download.dart`): proxmark3 default keys.
struct DictionaryDownloadView: View {
    @EnvironmentObject var store: CardStore

    static let sources = [
        DictionaryDownloadSource(
            id: "mfc",
            nameKey: "Mifare Classic keys (proxmark3)",
            url: URL(string: "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfc_default_keys.dic")!),
        DictionaryDownloadSource(
            id: "t55xx",
            nameKey: "T55xx passwords (proxmark3)",
            url: URL(string: "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/t55xx_default_pwds.dic")!),
        DictionaryDownloadSource(
            id: "mfulc",
            nameKey: "Mifare Ultralight C keys (proxmark3)",
            url: URL(string: "https://raw.githubusercontent.com/RfidResearchGroup/proxmark3/refs/heads/master/client/dictionaries/mfulc_default_keys.dic")!),
    ]

    @State private var downloading: Set<String> = []
    @State private var results: [String: String] = [:]

    var body: some View {
        List {
            Section {
                ForEach(Self.sources) { source in
                    row(source)
                }
            } footer: {
                Text(L10n.t("keys imported") + " · proxmark3")
            }
        }
        .navigationTitle(L10n.t("Dictionary download"))
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(_ source: DictionaryDownloadSource) -> some View {
        let isDownloaded = store.dictionaries.contains { $0.name == source.nameKey }
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t(source.nameKey))
                if let result = results[source.id] {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.red)
                }
            }
            Spacer()
            if downloading.contains(source.id) {
                ProgressView()
            } else if isDownloaded {
                Label(L10n.t("Downloaded"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button {
                    download(source)
                } label: {
                    Label(L10n.t("Download"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
    }

    private func download(_ source: DictionaryDownloadSource) {
        hapticFeedback()
        downloading.insert(source.id)
        Task {
            do {
                var request = URLRequest(url: source.url)
                request.timeoutInterval = 20
                let (data, _) = try await URLSession.shared.data(for: request)
                let text = String(data: data, encoding: .utf8) ?? ""
                var dictionary = KeyDictionary.fromText(text, name: source.nameKey)
                dictionary.name = source.nameKey
                guard !dictionary.keys.isEmpty else {
                    results[source.id] = "✗ " + L10n.t("Download failed")
                    downloading.remove(source.id)
                    return
                }
                store.add(dictionary: dictionary)
                let count = dictionary.keys.count
                results[source.id] = "✓ \(count) \(L10n.t("keys imported"))"
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                results[source.id] = "✗ " + L10n.t("Download failed")
            }
            downloading.remove(source.id)
        }
    }
}
