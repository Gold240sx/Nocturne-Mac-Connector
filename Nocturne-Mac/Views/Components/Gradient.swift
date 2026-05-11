import SwiftUI

/// Decorative gradient backdrop used behind the PairConnector screen.
struct GradientBackdrop: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(
                colors: [Theme.accent.opacity(0.30), .clear],
                center: .topLeading, startRadius: 50, endRadius: 600
            )
            RadialGradient(
                colors: [Color(red: 0.35, green: 0.13, blue: 0.55).opacity(0.25), .clear],
                center: .bottomTrailing, startRadius: 50, endRadius: 700
            )
        }
        .ignoresSafeArea()
    }
}
