import SwiftUI

/// The two source identities use the same reading component as other services.
struct DoubaoAmbientQuotaView: View {
    enum Placement { case notchValues, notchResets, orb }
    let lines: [AmbientQuotaLine]
    let placement: Placement
    var isFullScreen = false

    private var pair: [AmbientQuotaLine] {
        DoubaoQuotaWindow.allCases.map { window in
            lines.first { $0.id == window.rawValue } ?? window.unavailableLine
        }
    }
    var body: some View {
        switch placement {
        case .notchValues:
            QuotaGlanceRows(lines: pair, placement: .notchValues, isFullScreen: isFullScreen)
        case .notchResets:
            QuotaGlanceRows(lines: pair, placement: .notchResets, isFullScreen: isFullScreen)
        case .orb:
            QuotaOrbReadout(service: .doubao, lines: pair)
        }
    }
}
