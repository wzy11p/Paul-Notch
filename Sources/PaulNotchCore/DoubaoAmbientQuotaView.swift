import SwiftUI

/// A fixed pair: five-hour allowance and seven-day total are never rotated,
/// summed or substituted. This only lays out the existing source observation.
struct DoubaoAmbientQuotaView: View {
    enum Placement { case notchValues, notchResets, orb }
    let lines: [AmbientQuotaLine]
    let placement: Placement
    var isFullScreen = false

    private func line(_ window: DoubaoQuotaWindow) -> AmbientQuotaLine {
        lines.first { $0.id == window.rawValue } ?? window.unavailableLine
    }

    var body: some View {
        switch placement {
        case .notchValues:
            VStack(spacing: 0) {
                ForEach(DoubaoQuotaWindow.allCases, id: \.rawValue) { window in
                    let quota = line(window)
                    HStack(alignment: .firstTextBaseline, spacing: isFullScreen ? 1 : 2) {
                        Text(window.marker)
                            .font(.system(size: isFullScreen ? 7 : 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.76))
                            .frame(width: isFullScreen ? 13 : 15, alignment: .leading)
                        value(quota, size: isFullScreen ? 9 : 10, tinted: true)
                            .frame(width: isFullScreen ? 24 : 26, alignment: .trailing)
                    }
                }
            }
        case .notchResets:
            VStack(spacing: 0) {
                ForEach(DoubaoQuotaWindow.allCases, id: \.rawValue) { window in
                    reset(line(window), fontSize: isFullScreen ? 7 : 8)
                        .frame(width: isFullScreen ? 26 : 29)
                        .frame(height: isFullScreen ? 11 : 12)
                }
            }
        case .orb:
            VStack(spacing: 3) {
                AmbientProviderMark(service: .doubao, size: 16, attentive: false, pressed: false,
                    quiet: true, working: false, pointer: .zero)
                    .frame(width: 16, height: 16)
                HStack(alignment: .top, spacing: 4) {
                    ForEach(DoubaoQuotaWindow.allCases, id: \.rawValue) { window in
                        let quota = line(window)
                        VStack(spacing: 1) {
                            Text(window == .short ? "5 小时" : "7天总额")
                                .font(.system(size: 7.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.88))
                            value(quota, size: 12, tinted: false)
                            reset(quota, fontSize: 7)
                        }.frame(width: 32)
                    }
                }
            }.offset(y: -2)
        }
    }

    private func value(_ quota: AmbientQuotaLine, size: CGFloat, tinted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            switch quota.value {
            case .percent(let amount):
                Text("\(amount)")
                Text("%").font(.system(size: size * 0.6, weight: .semibold))
            case .percentBound(let lower, _):
                Text(">\(lower)")
                Text("%").font(.system(size: size * 0.6, weight: .semibold))
            case .unlimited: Text("不限")
            default: Text("—")
            }
        }
        .font(.system(size: size, weight: .semibold)).monospacedDigit()
        .foregroundStyle(tinted ? color(quota.value) : .white)
        .lineLimit(1).fixedSize()
    }

    private func reset(_ quota: AmbientQuotaLine, fontSize: CGFloat) -> some View {
        HStack(spacing: 1) {
            if quota.period != "待刷新" {
                Image(systemName: quota.resetCalendarCaption == nil ? "arrow.clockwise" : "calendar")
                    .font(.system(size: quota.resetCalendarCaption == nil ? 6 : 5, weight: .medium))
            }
            Text(quota.resetCalendarCaption ?? quota.countdownOnly)
                .font(.system(size: quota.resetCalendarCaption != nil || quota.countdownOnly.count > 3 ? 6 : fontSize,
                              weight: .medium)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.82))
        .lineLimit(1).fixedSize()
    }

    private func color(_ value: QuotaOverviewValue) -> Color {
        let remaining: Int
        switch value {
        case .percent(let amount): remaining = amount
        case .percentBound(let amount, _): remaining = amount
        default: return .white.opacity(0.82)
        }
        return Color(hue: 0.34 * Double(min(100, max(0, remaining))) / 100, saturation: 0.78, brightness: 1)
    }
}
