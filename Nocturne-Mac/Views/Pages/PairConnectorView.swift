import SwiftUI

struct PairConnectorView: View {
    @EnvironmentObject var auth: AuthService

    @State private var rawCode: String = ""
    @State private var submitting: Bool = false
    @State private var errorMessage: String? = nil
    @FocusState private var codeFocused: Bool

    private var formattedCode: String {
        Self.format(rawCode)
    }

    private var canSubmit: Bool {
        rawCode.count == 8 && !submitting
    }

    var body: some View {
        ZStack {
            GradientBackdrop()
            VStack(spacing: 24) {
                NocturneLogo(height: 36)
                Card {
                    VStack(spacing: 20) {
                        VStack(spacing: 8) {
                            Text("Pair Nocturne Connector")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Theme.fg)
                                .multilineTextAlignment(.center)
                            Text("Visit usenocturne.com/login on your phone or computer to get a pairing code.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondary)
                                .multilineTextAlignment(.center)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Pairing Code")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.fg)
                            TextField("XXXX-XXXX", text: Binding(
                                get: { formattedCode },
                                set: { newValue in
                                    rawCode = Self.strip(newValue)
                                }
                            ))
                            .focused($codeFocused)
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .multilineTextAlignment(.center)
                            .textFieldStyle(.plain)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Theme.inset)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Theme.line, lineWidth: 1)
                            )
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
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(maxWidth: 400)
            }
            .padding(40)
        }
        .onAppear { codeFocused = true }
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

    static func strip(_ s: String) -> String {
        let allowed = s.uppercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        return String(String.UnicodeScalarView(allowed)).prefix(8).description
    }

    static func format(_ raw: String) -> String {
        if raw.count <= 4 { return raw }
        let idx = raw.index(raw.startIndex, offsetBy: 4)
        return raw[..<idx] + "-" + raw[idx...]
    }
}
