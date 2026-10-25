import SwiftUI
import UIKit

/// Tools page (port of `gui/page/tools.dart`): T55xx password cleaner,
/// LF sniffing, HF sniffing.
struct ToolsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        List {
            Section("Sniffing") {
                NavigationLink {
                    SniffingView(isLF: true)
                } label: {
                    Label("LF sniffing (125 kHz)", systemImage: "waveform.path")
                        .foregroundStyle(.blue)
                }
                NavigationLink {
                    SniffingView(isLF: false)
                } label: {
                    Label("HF sniffing (13.56 MHz)", systemImage: "dot.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                }
            }
            Section("Tag tools") {
                NavigationLink {
                    T55XXPasswordCleanerView()
                } label: {
                    Label("T55xx password cleaner", systemImage: "password")
                }
            }
            Section {
                Label("Mifare Classic Gen4 config is not available in this build.",
                      systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Tools")
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
                            Label(running ? "Sniffing…" : "Start sniff", systemImage: "record.circle")
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
                    if busy { ProgressView() } else { Label("Reset tag", systemImage: "arrow.counterclockwise.circle.fill") }
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
        .navigationTitle("T55xx cleaner")
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
