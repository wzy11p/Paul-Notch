import SwiftUI

/// Genuine artwork in one fixed slot. Its subtle top-to-bottom highlight is
/// driven only by a confirmed running task, not focus or a quota refresh.
@MainActor struct AmbientProviderMark: View {
    let service: AmbientQuotaService
    let size: CGFloat
    let attentive: Bool
    let pressed: Bool
    let quiet: Bool
    let working: Bool
    let pointer: CGPoint

    private var direction: CGPoint { quiet || !attentive ? .zero : pointer }
    var body: some View {
        ZStack {
            artwork
            if working && !quiet {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    LinearGradient(colors: [.clear, .white.opacity(0.48), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: size * 0.65)
                        .position(x: size / 2, y: size * (-0.35 + phase * 1.7))
                }.mask(artwork)
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(!quiet && pressed ? 0.93 : 1)
        .rotation3DEffect(.degrees(-direction.y * 6), axis: (x: 1, y: 0, z: 0))
        .rotation3DEffect(.degrees(direction.x * 6), axis: (x: 0, y: 1, z: 0))
        .animation(quiet ? nil : .easeOut(duration: 0.16), value: direction)
        .accessibilityHidden(true)
    }
    @ViewBuilder private var artwork: some View {
        if let image = ProviderBrandAssets.image(for: service.rawValue) {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        } else {
            // No invented vendor symbol when official artwork is unavailable.
            Text(String(service.name.prefix(1))).font(.system(size: size * 0.8, weight: .semibold))
                .foregroundStyle(.white).frame(width: size, height: size)
        }
    }
}
