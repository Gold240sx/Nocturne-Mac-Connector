import SwiftUI

struct NocturneLogo: View {
    var height: CGFloat = 36

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Theme.accent, Color(red: 0.16, green: 0.20, blue: 0.50)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                Circle()
                    .fill(Theme.bg)
                    .frame(width: height * 0.55, height: height * 0.55)
                    .offset(x: -height * 0.18, y: -height * 0.18)
            }
            .frame(width: height, height: height)
            Text("Nocturne")
                .font(.system(size: height * 0.5, weight: .semibold, design: .default))
                .foregroundStyle(Theme.fg)
                .tracking(-0.5)
        }
    }
}
