import SwiftUI

struct NocturneAuthView: View {
    @EnvironmentObject var auth: AuthService

    var body: some View {
        Group {
            if auth.status.authenticated {
                signedIn
            } else {
                signIn
            }
        }
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Account")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.fg)
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Signed in as")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.muted)
                    Text(auth.status.user?.email ?? "—")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.fg)
                    Button("Sign Out") {
                        Task { await auth.signOut() }
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                }
            }
            .frame(maxWidth: 480)
        }
    }

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Account")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.fg)
            // Reuse the pairing form (without the gradient backdrop).
            Card {
                PairConnectorForm()
            }
            .frame(maxWidth: 480)
        }
    }
}

/// Just the form body, no decorative backdrop. Used inside the setup wizard.
struct PairConnectorForm: View {
    @EnvironmentObject var auth: AuthService

    @State private var rawCode: String = ""
    @State private var submitting: Bool = false
    @State private var errorMessage: String? = nil

    private var formattedCode: String {
        PairConnectorView.format(rawCode)
    }

    private var canSubmit: Bool {
        rawCode.count == 8 && !submitting
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("Sign in to continue")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Text("Visit usenocturne.com/login on your phone or computer, then enter the code below.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Pairing Code")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.fg)
                TextField("XXXX-XXXX", text: Binding(
                    get: { formattedCode },
                    set: { newValue in
                        rawCode = PairConnectorView.strip(newValue)
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                .disabled(submitting)
                .onSubmit(submit)
            }

            Button(action: submit) {
                Text(submitting ? "Pairing..." : "Pair Connector")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSubmit)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.destructive)
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        errorMessage = nil
        Task {
            do {
                _ = try await auth.pair(code: formattedCode)
            } catch {
                errorMessage = error.localizedDescription
            }
            submitting = false
        }
    }
}
