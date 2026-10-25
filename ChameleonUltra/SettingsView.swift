import SwiftUI
import UIKit

/// Settings page (port of `gui/page/settings.dart`, iOS-relevant subset).
struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage("themeColor") private var themeColor: String = "orange"
    @AppStorage("colorScheme") private var colorScheme: String = "system"
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @AppStorage("autoScan") private var autoScan = false
    @AppStorage("autoConnectFirst") private var autoConnectFirst = false
    @State private var showSettingsImporter = false
    @State private var showSettingsShare = false
    @State private var settingsURL: URL?

    static let settingsKeys = ["themeColor", "colorScheme", "appLanguage",
                               "autoScan", "autoConnectFirst", "hapticsEnabled"]

    private func exportSettings() {
        var dict: [String: String] = ["format": "chameleon-ultra-ios-settings", "version": "1"]
        for key in Self.settingsKeys {
            dict[key] = UserDefaults.standard.string(forKey: key) ?? ""
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings.json")
            try? data.write(to: url, options: .atomic)
            settingsURL = url
            showSettingsShare = true
        }
    }

    private func importSettings(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return }
        for key in Self.settingsKeys {
            if let value = dict[key], !value.isEmpty {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// Shown in About; reads the real bundle version so it never drifts.
    private var appVersionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Chameleon Ultra GUI for iOS \(version) (\(build))"
    }

    var body: some View {
        List {
            Section(L10n.t("Appearance")) {
                Picker(L10n.t("Theme"), selection: $colorScheme) {
                    Text(L10n.t("System")).tag("system")
                    Text(L10n.t("Light")).tag("light")
                    Text(L10n.t("Dark")).tag("dark")
                }
                Picker(L10n.t("Language"), selection: $appLanguage) {
                    Text(L10n.t("System")).tag("system")
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                }
                HStack {
                    Text(L10n.t("Accent color"))
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
                Section(L10n.t("Device")) {
                    NavigationLink {
                        DeviceSettingsView()
                    } label: {
                        Label(L10n.t("Device settings"), systemImage: "gearshape.2")
                    }
                }
            }

            Section(L10n.t("Connection")) {
                Toggle(L10n.t("Auto scan devices"), isOn: $autoScan)
                Toggle(L10n.t("Auto connect first device"), isOn: $autoConnectFirst)
                Button {
                    hapticFeedback()
                    exportSettings()
                } label: {
                    Label(L10n.t("Export settings"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PressableButtonStyle())
                Button {
                    hapticFeedback()
                    showSettingsImporter = true
                } label: {
                    Label(L10n.t("Import settings"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(PressableButtonStyle())
            }

            Section(L10n.t("About")) {
                LabeledContent("App", value: appVersionString)
                LabeledContent(L10n.t("License"), value: "GPL-3.0")
                NavigationLink {
                    LogsView()
                } label: {
                    Label(L10n.t("Protocol log"), systemImage: "doc.text.magnifyingglass")
                }
                Link(destination: URL(string: "https://github.com/GameTec-live/ChameleonUltraGUI")!) {
                    Label(L10n.t("Original project (Flutter)"), systemImage: "safari")
                }
            }

            Section {
                Text(L10n.t("For authorized security research and testing of RFID/NFC systems you own or have permission to test."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(L10n.t("Settings"))
        .sheet(isPresented: $showSettingsImporter) {
            DocumentPicker(contentTypes: [.json]) { url in
                importSettings(from: url)
            }
        }
        .sheet(isPresented: $showSettingsShare) {
            if let settingsURL { ShareSheet(items: [settingsURL]) }
        }
    }
}

// MARK: - Device settings

struct DeviceSettingsView: View {
    @EnvironmentObject var app: AppModel
    @State private var animation: AnimationSetting?
    @State private var wakeTime: Int?
    @State private var pairing: Bool?
    @State private var error: String?
    @State private var confirmFactoryReset = false
    @State private var confirmResetSettings = false
    // button config (original: button_config)
    @State private var aPress: ButtonConfig?
    @State private var bPress: ButtonConfig?
    @State private var aLongPress: ButtonConfig?
    @State private var bLongPress: ButtonConfig?
    @State private var longPressThreshold: Int?

    var body: some View {
        Form {
            if let currentAnimation = animation {
                Picker(L10n.t("LED animation"), selection: Binding(
                    get: { animation ?? currentAnimation },
                    set: { newValue in
                        animation = newValue
                        Task { try? await app.communicator?.setAnimationMode(newValue) }
                    })) {
                    ForEach(AnimationSetting.allCases) { mode in
                        Text(L10n.t(mode.displayName)).tag(mode)
                    }
                }
            }
            if let currentWakeTime = wakeTime {
                Stepper(sleepTimeoutTitle(currentWakeTime),
                        value: Binding(
                            get: { wakeTime ?? currentWakeTime },
                            set: { newValue in
                                wakeTime = newValue
                                Task { try? await app.communicator?.setSleepTimeout(newValue) }
                            }), in: 0...120, step: 5)
            }
            if let currentPairing = pairing {
                Toggle(L10n.t("BLE pairing"), isOn: Binding(
                    get: { pairing ?? currentPairing },
                    set: { newValue in
                        pairing = newValue
                        Task { try? await app.communicator?.setBLEPairEnabled(newValue) }
                    }))
            }
            if let currentThreshold = longPressThreshold {
                Stepper("\(L10n.t("Long press threshold")): \(currentThreshold) \(L10n.t("ms"))",
                        value: Binding<Int>(
                            get: { longPressThreshold ?? currentThreshold },
                            set: { newValue in
                                longPressThreshold = newValue
                                Task {
                                    try? await app.communicator?.setLongPressThreshold(newValue)
                                    hapticFeedback()
                                }
                            }), in: 100...5000, step: 100)
            }
            Section(L10n.t("Button config")) {
                if let current = aPress {
                    buttonPicker(L10n.t("A button"), L10n.t("Short press"), current, .a, long: false)
                }
                if let current = bPress {
                    buttonPicker(L10n.t("B button"), L10n.t("Short press"), current, .b, long: false)
                }
                if let current = aLongPress {
                    buttonPicker(L10n.t("A button"), L10n.t("Long press"), current, .a, long: true)
                }
                if let current = bLongPress {
                    buttonPicker(L10n.t("B button"), L10n.t("Long press"), current, .b, long: true)
                }
            }
            Section {
                Button(role: .destructive) {
                    confirmResetSettings = true
                } label: {
                    Label(L10n.t("Reset device settings"), systemImage: "arrow.counterclockwise")
                }
            } footer: {
                Text(L10n.t("Applies device defaults. Does not erase slots."))
            }
            Section {
                Button(role: .destructive) {
                    confirmFactoryReset = true
                } label: {
                    Label(L10n.t("Factory reset (erases everything)"), systemImage: "exclamationmark.triangle")
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle(L10n.t("Device settings"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(L10n.t("Reset device settings?"), isPresented: $confirmResetSettings) {
            Button(L10n.t("Reset device settings"), role: .destructive) {
                Task { try? await app.communicator?.resetSettings() }
            }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("Applies device defaults. Does not erase slots."))
        }
        .alert(L10n.t("Factory reset?"), isPresented: $confirmFactoryReset) {
            Button(L10n.t("Factory reset (erases everything)"), role: .destructive) {
                Task { try? await app.communicator?.factoryReset() }
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            Button(L10n.t("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("Are you sure you want to factory reset your Chameleon?"))
        }
        .task {
            guard let communicator = app.communicator else { return }
            animation = try? await communicator.getAnimationMode()
            wakeTime = try? await communicator.getSleepTimeout()
            pairing = try? await communicator.isBLEPairEnabled()
            aPress = try? await communicator.getButtonConfig(.a, long: false)
            bPress = try? await communicator.getButtonConfig(.b, long: false)
            aLongPress = try? await communicator.getButtonConfig(.a, long: true)
            bLongPress = try? await communicator.getButtonConfig(.b, long: true)
            longPressThreshold = try? await communicator.getLongPressThreshold()
        }
    }

    @ViewBuilder
    private func buttonPicker(_ button: String, _ kind: String, _ current: ButtonConfig,
                              _ type: ButtonType, long: Bool) -> some View {
        Picker("\(button) · \(kind)", selection: Binding(
            get: { current },
            set: { newValue in
                switch (type, long) {
                case (.a, false): aPress = newValue
                case (.b, false): bPress = newValue
                case (.a, true): aLongPress = newValue
                case (.b, true): bLongPress = newValue
                }
                Task {
                    try? await app.communicator?.setButtonConfig(type, mode: newValue, long: long)
                    hapticFeedback()
                }
            })) {
            ForEach(ButtonConfig.allCases) { mode in
                Text(L10n.t(mode.displayName)).tag(mode)
            }
        }
    }

    private func sleepTimeoutTitle(_ minutes: Int) -> String {
        let wakeWord = L10n.t("Sleep timeout")
        return minutes == 0
            ? "\(wakeWord): \(L10n.t("never"))"
            : "\(wakeWord): \(minutes) \(L10n.t("min"))"
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
        .navigationTitle(L10n.t("Protocol log"))
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
