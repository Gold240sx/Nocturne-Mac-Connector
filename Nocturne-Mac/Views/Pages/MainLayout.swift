import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard, bluetooth, spotify, settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .bluetooth: return "Bluetooth"
        case .spotify: return "Spotify"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: return "rectangle.grid.2x2"
        case .bluetooth: return "wave.3.right"
        case .spotify: return "music.note"
        case .settings: return "gearshape"
        }
    }
}

/// The app's main "logged-in, setup-complete" layout. Mirrors the Layout.tsx route
/// host from the React UI.
struct MainLayout: View {
    @State private var selection: SidebarSection = .dashboard

    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarSection.allCases) { section in
                        Label(section.label, systemImage: section.icon)
                            .tag(section)
                    }
                } header: {
                    NocturneLogo(height: 26)
                        .padding(.vertical, 8)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detailContent
        }
        #else
        // iOS fallback. The app is macOS-only; this exists just so an accidental
        // iOS build (e.g. wrong Xcode destination) still compiles.
        TabView(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                detailContent
                    .tabItem { Label(section.label, systemImage: section.icon) }
                    .tag(section)
            }
        }
        #endif
    }

    private var detailContent: some View {
        ScrollView {
            Group {
                switch selection {
                case .dashboard: DashboardView()
                case .bluetooth: BluetoothPairingView()
                case .spotify: SpotifyAuthView()
                case .settings: SettingsView()
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
    }
}
