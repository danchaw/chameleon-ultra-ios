import SwiftUI

@main
struct ChameleonUltraApp: App {
    @StateObject private var app = AppModel.shared
    @AppStorage("themeColor") private var themeColor: String = "orange"
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @AppStorage("colorScheme") private var colorScheme: String = "system"

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(app)
                .environmentObject(app.store)
                .tint(Color(hexString: themeColor))
                .environment(\.themeAccent, Color(hexString: themeColor))
                .preferredColorScheme(ColorSchemePreference.current)
                // Widget deep link: chameleonultra://activate/N
                .onOpenURL { url in
                    guard url.scheme == "chameleonultra", url.host == "activate",
                          let slot = Int(url.lastPathComponent), (0..<8).contains(slot) else { return }
                    Task { await app.activateSlot(slot) }
                }
                // Any appearance/language change rebuilds the tree so every
                // L10n string and tint refreshes immediately (no restart).
                .id("\(themeColor)|\(colorScheme)|\(appLanguage)")
        }
    }
}

enum ColorSchemePreference {
    private static let key = "colorScheme"
    static var current: ColorScheme? {
        switch UserDefaults.standard.string(forKey: key) ?? "system" {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        TabView {
            NavigationStack { HomeEntryPoint() }
                .tabItem { Label(L10n.t("Home"), systemImage: "house.fill") }

            NavigationStack { ReadCardView() }
                .tabItem { Label(L10n.t("Read"), systemImage: "creditcard.viewfinder") }
                .disabled(!app.isConnected)

            NavigationStack { SavedCardsView() }
                .tabItem { Label(L10n.t("Cards"), systemImage: "rectangle.stack.fill") }

            NavigationStack { WriteCardView() }
                .tabItem { Label(L10n.t("Write"), systemImage: "square.and.pencil") }
                .disabled(!app.isConnected)

            NavigationStack { SettingsView() }
                .tabItem { Label(L10n.t("Settings"), systemImage: "gearshape.fill") }
        }
    }
}

/// Home tab shows the connect screen or the dashboard depending on state.
struct HomeEntryPoint: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        switch app.connectionState {
        case .connected:
            // Back button on the dashboard shows the device list again while
            // the BLE connection stays alive.
            if app.showDeviceList {
                ConnectView()
            } else {
                HomeDashboardView()
            }
        case .dfuMode:
            FlashingView()
        case .connecting:
            ScrollView {
                GlassCard {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("\(L10n.t("Connecting to")) \(app.deviceName.isEmpty ? "Chameleon" : app.deviceName)…")
                            .font(.headline)
                        Text(L10n.t("This can take a few seconds."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            app.cancelConnection()
                        } label: {
                            Label(L10n.t("Cancel"), systemImage: "xmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .padding()
            }
            .navigationTitle("Chameleon")
        case .disconnected:
            ConnectView()
        }
    }
}
