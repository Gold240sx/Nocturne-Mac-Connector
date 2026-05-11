import SwiftUI

struct SetupWizardView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var spotify: SpotifyService

    @State private var step: Int = 0
    @State private var finishing: Bool = false
    @State private var finishError: String? = nil

    private let steps = ["Welcome", "Account", "Spotify", "Bluetooth", "Analytics", "Done"]

    var body: some View {
        VStack(spacing: 0) {
            NocturneLogo(height: 30)
                .padding(.top, 24)
                .padding(.bottom, 16)

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .tint(Theme.accent)
                .padding(.horizontal, 24)

            stepIndicators

            ScrollView {
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: NocturneAuthView()
                    case 2: SpotifyAuthView(onLinked: { advance() })
                    case 3: BluetoothPairingView()
                    case 4: AnalyticsConsentView()
                    case 5: doneStep
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }

            if step > 0 && step < 5 {
                navigationBar
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
        }
        .background(Theme.bg)
        .onChange(of: auth.status.authenticated) { _, newValue in
            if step == 1 && newValue { advance() }
        }
    }

    private var progress: Double {
        Double(step) / Double(steps.count - 1)
    }

    private var stepIndicators: some View {
        HStack(spacing: 12) {
            ForEach(0..<steps.count, id: \.self) { i in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(i == step ? Theme.accent : Theme.inset)
                        Text("\(i + 1)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(i == step ? Color.white : (i < step ? Theme.fg : Theme.muted))
                    }
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(i < step ? Theme.line : Color.clear, lineWidth: 1))
                    Text(steps[i])
                        .font(.system(size: 12))
                        .foregroundStyle(i == step ? Theme.fg : (i < step ? Theme.secondary : Theme.muted))
                }
                if i < steps.count - 1 {
                    Rectangle().fill(Theme.line).frame(width: 18, height: 1)
                }
            }
        }
        .padding(.top, 24)
    }

    private var welcomeStep: some View {
        Card {
            VStack(spacing: 16) {
                Text("Welcome to Nocturne")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Text("Let's set up your Mac to connect with your Car Thing.")
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Button("Get Started") { advance() }
                    .buttonStyle(PrimaryButtonStyle(prominent: true))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var doneStep: some View {
        Card {
            VStack(spacing: 16) {
                Text("All Set!")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Text("Your Nocturne connector is ready. Head to the dashboard to manage your devices.")
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                Button(finishing ? "Saving..." : "Go to Dashboard") {
                    finish()
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .disabled(finishing)
                if let finishError {
                    Text(finishError)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.destructive)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var navigationBar: some View {
        HStack {
            Button("Back") { goBack() }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            Spacer()
            Button(step == 4 ? "Finish" : "Next") { advance() }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .disabled(nextDisabled)
        }
    }

    private var nextDisabled: Bool {
        if step == 1 && !auth.status.authenticated { return true }
        if step == 2 && !spotify.authState.isLinked { return true }
        return false
    }

    private func advance() {
        guard step < steps.count - 1 else { return }
        step += 1
    }

    private func goBack() {
        guard step > 0 else { return }
        step -= 1
    }

    private func finish() {
        finishing = true
        auth.markSetupComplete()
        finishing = false
    }
}
