import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var auth: AuthService
    @EnvironmentObject var analytics: AnalyticsService

    @State private var deleteOpen = false
    @State private var deleting = false
    @State private var deleteError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("Manage your account, view system info, and configure your connector.")
                    .foregroundStyle(Theme.secondary)
            }

            section("Account") {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Signed in as")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                                Text(auth.status.user?.email ?? "—")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Theme.fg)
                            }
                            Spacer()
                            Button("Sign Out") {
                                Task { await auth.signOut() }
                            }
                            .buttonStyle(PrimaryButtonStyle(prominent: false))
                        }
                        Divider().overlay(Theme.line)
                        HStack(spacing: 4) {
                            Text("Manage your account at")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                            Link("usenocturne.com", destination: URL(string: "https://usenocturne.com/login")!)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            section("System") {
                Card {
                    VStack(spacing: 6) {
                        infoRow("Connector Version", AppConfig.connectorVersion)
                        infoRow("OS Version", AppConfig.osVersion)
                    }
                }
            }

            section("Privacy") {
                Card {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Analytics")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Theme.fg)
                            Text("Help improve Nocturne by sharing usage data.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { analytics.isEnabled },
                            set: { analytics.setEnabled($0) }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }

            section("Danger Zone") {
                Card {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Delete Account")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Theme.fg)
                                Text("Permanently removes your account and all associated data.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.secondary)
                            }
                            Spacer()
                            Button("Delete Account") { deleteOpen = true }
                                .buttonStyle(DestructiveButtonStyle())
                        }
                        if let deleteError {
                            Text(deleteError)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.destructive)
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14).stroke(Theme.destructive.opacity(0.25), lineWidth: 1)
                )
            }
        }
        .padding(.bottom, 24)
        .alert("Delete account?", isPresented: $deleteOpen) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { performDelete() }
        } message: {
            Text("Deleting your account will remove all associated data. This action cannot be undone.")
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(2)
                .foregroundStyle(Theme.muted)
            content()
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.fg)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 8))
    }

    private func performDelete() {
        deleting = true
        deleteError = nil
        Task {
            do {
                try await auth.deleteAccount()
            } catch {
                deleteError = error.localizedDescription
            }
            deleting = false
        }
    }
}
