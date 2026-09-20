import SwiftUI

/// Fixed three-digit number slot keeps 9%, 99% and 100% aligned without
/// changing the shelf geometry. The unit remains visible in full screen.
struct AmbientQuotaLabel: View {
    let period: String
    let remaining: Int
    let isFullScreen: Bool
    let color: Color
    let secondaryColor: Color

    private var numberFont: Font {
        .system(size: isFullScreen ? 9 : 10, weight: .semibold, design: .rounded)
            .monospacedDigit()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(period)
                .font(.system(size: 7, weight: .medium, design: .rounded))
                .foregroundStyle(secondaryColor)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ZStack(alignment: .trailing) {
                    Text("100").hidden().accessibilityHidden(true)
                    Text("\(min(100, max(0, remaining)))")
                }
                .font(numberFont)
                Text("%")
                    .font(.system(size: 7, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(color)
        }
        .lineLimit(1)
        .fixedSize()
    }
}
