import SwiftUI
import UIKit

/// Settings page (port of `gui/page/settings.dart`, iOS-relevant subset).
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("themeColor") private var themeColor: String = "orange"
    @AppStorage("colorScheme") private var colorScheme: String = "system"
    @AppStorage("hapticsEnabled") private var hapticsEnabled: Bool = true

    var body: some View {
        List {
            Section("Appearance") {
                Picker("Theme", selection: $colorScheme) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                HStack {
                    Text("Accent color")
                    Spacer()
                    ForEach(themeColors, id: \.hex) { color in
                        Button {
                            themeColor = color.hex
                        } label: {
                            Circle()
                                .fill(Color(hexString: color.hex))
                                .frame(width: 26, height: 26)
                                .overlay(Circle().stroke(.primary.opacity(0.2), lineWidth: 1))
                                .overlay {
                                    if themeColor == color.hex {
                                        Image(systemName: "checkmark")
                                            .font(.caption2.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if app.isConnected {
                Section("Device") {
                    NavigationLink {
                        DeviceSettingsView()
                    } label: {
                        Label("Device settings", systemImage: "gearshape.2")
                    }
                    NavigationLink {
                        FlashingView(embedded: true)
                    } label: {
                        Label("Firmware update (DFU)", systemImage: "arrow.down.doc")
                    }
                }
            }

            Section("About") {
                LabeledContent("App", value: "Chameleon Ultra GUI for iOS 1.0")
                LabeledContent("License", value: "GPL-3.0")
                NavigationLink {
                    LogsView()
                } label: {
                    Label("Protocol log", systemImage: "doc.text.magnifyingglass")
                }
                Link(destination: URL(string: "https://github.com/GameTec-live/ChameleonUltraGUI")!) {
                    Label("Original project (Flutter)", systemImage: "safari")
                }
            }

            Section {
                Text("For authorized security research and testing of RFID/NFC systems you own or have permission to test.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

// MARK: - Device settings

struct DeviceSettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var animation: AnimationSetting?
    @State private var wakeTime: Int?
    @State private var pairing: Bool?
    @State private var error: String?

    var body: some View {
        Form {
            if let currentAnimation = animation {
                Picker("LED animation", selection: Binding(
                    get: { animation ?? currentAnimation },
                    set: { newValue in
                        animation = newValue
                        Task { try? await app.communicator?.setAnimationMode(newValue) }
                    })) {
                    ForEach(AnimationSetting.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            if let currentWakeTime = wakeTime {
                Stepper(currentWakeTime == 0 ? "Sleep timeout: never" : "Sleep timeout: \(currentWakeTime) min",
                        value: Binding(
                            get: { wakeTime ?? currentWakeTime },
                            set: { newValue in
                                wakeTime = newValue
                                Task { try? await app.communicator?.setSleepTimeout(newValue) }
                            }), in: 0...120, step: 5)
            }
            if let currentPairing = pairing {
                Toggle("BLE pairing", isOn: Binding(
                    get: { pairing ?? currentPairing },
                    set: { newValue in
                        pairing = newValue
                        Task { try? await app.communicator?.setBLEPairEnabled(newValue) }
                    }))
            }
            Section {
                Button(role: .destructive) {
                    Task {
                        try? await app.communicator?.resetSettings()
                    }
                } label: {
                    Label("Reset device settings", systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text("Applies device defaults. Does not erase slots.")
            }
            Section {
                Button(role: .destructive) {
                    Task {
                        try? await app.communicator?.factoryReset()
                    }
                } label: {
                    Label("Factory reset (erases everything)", systemImage: "exclamationmark.triangle")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Device settings")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let communicator = app.communicator else { return }
            animation = try? await communicator.getAnimationMode()
            wakeTime = try? await communicator.getSleepTimeout()
            pairing = try? await communicator.isBLEPairEnabled()
        }
    }
}

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(app.logLines.enumerated().reversed()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding()
        }
        .navigationTitle("Protocol log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = app.logLines.joined(separator: "\n")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
    }
}
