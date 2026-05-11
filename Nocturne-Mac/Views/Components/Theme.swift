import SwiftUI

/// Tailwind-ish design tokens. Mirrors the bg/fg/secondary/muted/line/accent vars
/// the React UI uses in src/client/globals.css.
enum Theme {
    // Backgrounds
    static let bg = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let raised = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let inset = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let hover = Color(red: 0.12, green: 0.12, blue: 0.14)

    // Foreground
    static let fg = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let secondary = Color(red: 0.70, green: 0.70, blue: 0.74)
    static let muted = Color(red: 0.55, green: 0.55, blue: 0.60)

    // Lines
    static let line = Color(red: 0.20, green: 0.20, blue: 0.23)
    static let lineHover = Color(red: 0.27, green: 0.27, blue: 0.31)

    // Accents
    static let accent = Color(red: 0.39, green: 0.51, blue: 0.96)
    static let accentHover = Color(red: 0.49, green: 0.58, blue: 0.98)
    static let success = Color(red: 0.13, green: 0.78, blue: 0.45)
    static let destructive = Color(red: 0.94, green: 0.31, blue: 0.31)
}

struct Card<Content: View>: View {
    let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
                .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.line, lineWidth: 1)
        )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Theme.fg)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent
                          ? (configuration.isPressed ? Theme.accentHover : Theme.accent)
                          : (configuration.isPressed ? Theme.hover : Theme.raised))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(prominent ? Color.clear : Theme.line, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.95 : 1.0)
    }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white)
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(configuration.isPressed ? Theme.destructive.opacity(0.85) : Theme.destructive)
            )
    }
}

struct PillBadge: View {
    let text: String
    var tint: Color = Theme.success

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint.opacity(0.12))
            )
            .overlay(Capsule().stroke(tint.opacity(0.25), lineWidth: 1))
    }
}
