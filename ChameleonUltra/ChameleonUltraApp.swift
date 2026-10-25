import SwiftUI

@main
struct ChameleonUltraApp: App {
    @StateObject private var app = AppModel.shared
    @AppStorage("themeColor") private var themeColor: String = "orange"

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(app)
                .environmentObject(app.store)
                .tint(Color(hexString: themeColor))
                .preferredColorScheme(ColorSchemePreference.current)
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
                .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack { ReadCardView() }
                .tabItem { Label("Read", systemImage: "creditcard.viewfinder") }
                .disabled(!app.isConnected)

            NavigationStack { SavedCardsView() }
                .tabItem { Label("Cards", systemImage: "rectangle.stack.fill") }

            NavigationStack { WriteCardView() }
                .tabItem { Label("Write", systemImage: "square.and.pencil") }
                .disabled(!app.isConnected)

            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}

/// Home tab shows the connect screen or the dashboard depending on state.
struct HomeEntryPoint: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        switch app.connectionState {
        case .connected:
            HomeDashboardView()
        case .dfuMode:
            FlashingView()
        case .connecting:
            ScrollView {
                GlassCard {
                    VStack(spacing: 16) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Connecting to \(app.deviceName.isEmpty ? "Chameleon" : app.deviceName)…")
                            .font(.headline)
                        Text("This can take a few seconds.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button {
                            app.cancelConnection()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle.fill")
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
