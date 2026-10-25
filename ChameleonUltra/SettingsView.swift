import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
    @State private var message: String?

    static let appStringKeys = ["themeColor", "colorScheme", "appLanguage"]
    static let appBoolKeys = ["autoScan", "autoConnectFirst", "hapticsEnabled"]
    static let settingsMagic = "chameleon-ultra-ios-settings"

    /// Exports app settings and — when a device is connected — the live
    /// device settings too, in a dedicated `.cusettings` format.
    private func exportSettings() async {
        var appDict: [String: Any] = [:]
        for key in Self.appStringKeys {
            appDict[key] = UserDefaults.standard.string(forKey: key) ?? ""
        }
        for key in Self.appBoolKeys {
            appDict[key] = UserDefaults.standard.bool(forKey: key)
        }
        var dict: [String: Any] = ["format": Self.settingsMagic, "version": 2, "app": appDict]

        if app.isConnected, let c = app.communicator {
            var device: [String: Any] = [:]
            if let mode = try? await c.getAnimationMode() { device["animation"] = mode.rawValue }
            if let wake = try? await c.getSleepTimeout() { device["wakeTime"] = wake }
            if let threshold = try? await c.getLongPressThreshold() { device["longPressThreshold"] = threshold }
            if let pairing = try? await c.isBLEPairEnabled() { device["pairing"] = pairing }
            if let a = try? await c.getButtonConfig(.a, long: false) { device["aPress"] = a.rawValue }
            if let b = try? await c.getButtonConfig(.b, long: false) { device["bPress"] = b.rawValue }
            if let al = try? await c.getButtonConfig(.a, long: true) { device["aLongPress"] = al.rawValue }
            if let bl = try? await c.getButtonConfig(.b, long: true) { device["bLongPress"] = bl.rawValue }
            if !device.isEmpty { dict["device"] = device }
        }

        guard JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chameleon-settings.cusettings")
        try? data.write(to: url, options: .atomic)
        settingsURL = url
        showSettingsShare = true
    }

    /// Imports the dedicated format only; rejects any other file.
    private func importSettings(from url: URL) async {
        guard let data = try? Data(contentsOf: url),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              dict["format"] as? String == Self.settingsMagic else {
            message = L10n.t("Invalid settings file")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }

        if let appDict = dict["app"] as? [String: Any] {
            if let value = appDict["themeColor"] as? String, !value.isEmpty { themeColor = value }
            if let value = appDict["colorScheme"] as? String, !value.isEmpty { colorScheme = value }
            if let value = appDict["appLanguage"] as? String, !value.isEmpty { appLanguage = value }
            if let value = appDict["autoScan"] as? Bool { autoScan = value }
            if let value = appDict["autoConnectFirst"] as? Bool { autoConnectFirst = value }
            if let value = appDict["hapticsEnabled"] as? Bool {
                UserDefaults.standard.set(value, forKey: "hapticsEnabled")
            }
        }

        var appliedDevice = false
        if let device = dict["device"] as? [String: Any], app.isConnected, let c = app.communicator {
            if let raw = device["animation"] as? Int, let mode = AnimationSetting(rawValue: UInt8(raw)) {
                try? await c.setAnimationMode(mode)
            }
            if let wake = device["wakeTime"] as? Int { try? await c.setSleepTimeout(wake) }
            if let threshold = device["longPressThreshold"] as? Int { try? await c.setLongPressThreshold(threshold) }
            if let pairing = device["pairing"] as? Bool { try? await c.setBLEPairEnabled(pairing) }
            let buttonMap: [(String, ButtonType, Bool)] = [
                ("aPress", .a, false), ("bPress", .b, false),
                ("aLongPress", .a, true), ("bLongPress", .b, true),
            ]
            for (key, type, long) in buttonMap {
                if let raw = device[key] as? Int, let mode = ButtonConfig(rawValue: UInt8(raw)) {
                    try? await c.setButtonConfig(type, mode: mode, long: long)
                }
            }
            appliedDevice = true
        }

        message = appliedDevice
            ? "\(L10n.t("Settings imported")) · \(L10n.t("Device settings applied"))"
            : (dict["device"] != nil
                ? "\(L10n.t("Settings imported")) · \(L10n.t("Device not connected — app settings only"))"
                : L10n.t("Settings imported"))
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
                        AccentLabel(L10n.t("Device settings"), "gearshape.2")
                    }
                }
            }

            Section(L10n.t("Connection")) {
                Toggle(L10n.t("Auto scan devices"), isOn: $autoScan)
                Toggle(L10n.t("Auto connect first device"), isOn: $autoConnectFirst)
            }

            Section {
                Button {
                    hapticFeedback()
                    Task { await exportSettings() }
                } label: {
                    AccentLabel(L10n.t("Export settings"), "square.and.arrow.up")
                }
                .buttonStyle(ListRowHighlightStyle())
                Button {
                    hapticFeedback()
                    showSettingsImporter = true
                } label: {
                    AccentLabel(L10n.t("Import settings"), "square.and.arrow.down")
                }
                .buttonStyle(ListRowHighlightStyle())
            } header: {
                Text(L10n.t("Settings management"))
            } footer: {
                Text("\(L10n.t("App settings")) + \(L10n.t("Device settings")) · .cusettings")
            }

            if let message {
                Section { Text(message).foregroundStyle(.secondary).font(.footnote) }
            }

            Section(L10n.t("About")) {
                LabeledContent("App", value: appVersionString)
                LabeledContent(L10n.t("License"), value: "GPL-3.0")
                NavigationLink {
                    LogsView()
                } label: {
                    AccentLabel(L10n.t("Protocol log"), "doc.text.magnifyingglass")
                }
                Link(destination: URL(string: "https://github.com/GameTec-live/ChameleonUltraGUI")!) {
                    AccentLabel(L10n.t("Original project (Flutter)"), "safari")
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
            DocumentPicker(contentTypes: [UTType(filenameExtension: "cusettings") ?? .data, .json, .data]) { url in
                Task { await importSettings(from: url) }
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
                    AccentLabel(L10n.t("Reset device settings"), "arrow.counterclockwise")
                }
            } footer: {
                Text(L10n.t("Applies device defaults. Does not erase slots."))
            }
            Section {
                Button(role: .destructive) {
                    confirmFactoryReset = true
                } label: {
                    AccentLabel(L10n.t("Factory reset (erases everything)"), "exclamationmark.triangle")
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
