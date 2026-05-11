import SwiftUI

/// Mirrors src/client/App.tsx — the auth/setup-state router.
struct RootView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        Group {
            if auth.status.isInitializing {
                loading
            } else if !auth.status.setupComplete {
                SetupWizardView()
            } else if auth.status.authenticated {
                MainLayout()
            } else {
                PairConnectorView()
            }
        }
        .preferredColorScheme(.dark)
        .background(Theme.bg)
    }

    private var loading: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Theme.accent)
                Text("Loading...")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
            }
        }
    }
}
