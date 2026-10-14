import SwiftUI

enum QuotaOrbInk {
    static let primary = Color(white: 0.10)
    static let secondary = Color(white: 0.14)
}

/// Stable roles and type scale across compact services, without another reader.
struct QuotaGlanceRows: View {
    enum Placement { case notchValues, notchResets, orb }
    let lines: [AmbientQuotaLine]
    let placement: Placement
    var isFullScreen = false
    var highlightedID: String? = nil

    var body: some View {
        VStack(spacing: placement == .orb ? 2 : 0) {
            ForEach(lines) { line in
                if placement == .notchResets {
                    Text(Self.notchResetText(line))
                        .font(.system(size: isFullScreen ? 8 : 9, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: isFullScreen ? 22 : 24, height: isFullScreen ? 11 : 12)
                } else {
                    VStack(spacing: 0) {
                        HStack(alignment: .firstTextBaseline, spacing: placement == .orb ? 3 : 1) {
                            if placement == .notchValues && lines.count == 1 {
                                Text(Self.notchResetText(line))
                                    .font(.system(size: isFullScreen ? 8 : 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.82)).monospacedDigit()
                                    .lineLimit(1).fixedSize().padding(.trailing, 3)
                            } else if line.poolLabel != nil {
                                Text(line.compactLabel)
                                    .font(.system(size: placement == .orb ? 9 : (isFullScreen ? 8 : 9), weight: .medium))
                                    .foregroundStyle(placement == .orb ?
                                        (highlightedID == line.id ? QuotaOrbInk.primary : QuotaOrbInk.secondary) :
                                        .white.opacity(highlightedID == line.id ? 1 : 0.82))
                                    .lineLimit(1).fixedSize()
                                    .frame(width: placement == .orb ? 11 : 9, alignment: .leading)
                                    .underline(highlightedID == line.id)
                            }
                            amount(line.value)
                        }
                        .frame(height: placement == .orb ? 18 : (isFullScreen ? 11 : 12))
                        if placement == .orb {
                            Text(line.compactResetText).font(.system(size: 9, weight: .medium)).monospacedDigit()
                                .foregroundStyle(QuotaOrbInk.secondary).lineLimit(1)
                                .frame(height: 9)
                        }
                    }
                    .help(line.readingExplanation)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(line.readingExplanation)
                }
            }
        }
    }

    /// Preserve the owner's compact D/H/M clocks and literal pending states.
    static func notchResetText(_ line: AmbientQuotaLine) -> String {
        switch line.compactResetText {
        case "P": return "待用"
        case "…": return "待更新"
        default: return line.compactResetText
        }
    }

    private func amount(_ value: QuotaOverviewValue) -> some View {
        let size: CGFloat = placement == .orb ? 16 : (isFullScreen ? 9 : 10)
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            switch value {
            case .percent(let amount):
                Text("\(amount)")
                Text("%").font(.system(size: size * 0.65, weight: .semibold))
            case .percentBound(let amount, _):
                Text(">\(amount)")
                Text("%").font(.system(size: size * 0.65, weight: .semibold))
            case .unlimited: Text("∞")
            default: Text("—")
            }
        }
        .font(.system(size: size, weight: .semibold)).monospacedDigit()
        .foregroundStyle(placement == .orb ? QuotaOrbInk.primary : quotaColor(value))
        .lineLimit(1).fixedSize()
        .frame(minWidth: placement == .orb ? nil : (isFullScreen ? 18 : 22), alignment: .trailing)
    }

    private func quotaColor(_ value: QuotaOverviewValue) -> Color {
        let amount: Int
        switch value {
        case .percent(let n), .percentBound(let n, _): amount = n
        default: return .white.opacity(0.82)
        }
        return Color(hue: 0.34 * Double(min(100, max(0, amount))) / 100, saturation: 0.78, brightness: 1)
    }
}

/// Light local support below the liquid and dark ink. Placing it over the
/// liquid washes out its color, waterline and bubbles on a dark background.
/// This static coat adds no blur; the transparent rim stays uncovered.
struct QuotaOrbReadingBackdrop: View {
    var body: some View {
        RadialGradient(stops: [
            .init(color: Color.white.opacity(0.68), location: 0),
            .init(color: Color.white.opacity(0.66), location: 0.90),
            .init(color: .clear, location: 0.95),
            .init(color: .clear, location: 1)
        ], center: .center, startRadius: 0, endRadius: QuotaFloatingPlacement.orbDiameter / 2)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct QuotaOrbReadout: View {
    let service: AmbientQuotaService
    let lines: [AmbientQuotaLine]
    var highlightedID: String? = nil
    var modelLabel: String? = nil

    // Cursor's canonical adapter supplies a single billing-cycle deadline.
    // Never merge independent providers' clocks or merely similar captions.
    private var sharedReset: String? {
        guard service == .cursor, lines.count == 2,
              Set(lines.map(\.id)) == Set(["Cursor Models", "Other Models"]),
              lines[0].period == lines[1].period,
              lines[0].resetDescription == lines[1].resetDescription,
              !["—", "…", "P"].contains(lines[0].compactResetText) else { return nil }
        return lines[0].compactResetText
    }

    var body: some View {
        VStack(spacing: 2) {
            AmbientProviderMark(service: service, size: 18, attentive: false,
                pressed: false, quiet: true, working: false, pointer: .zero)
                .frame(width: 18, height: 18)
                .overlay(alignment: .trailing) {
                    if let mark = modelLabel.flatMap(QuotaGlanceText.modelMark) {
                        Text(mark).font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(QuotaOrbInk.primary).fixedSize()
                            .offset(x: mark.count > 1 ? 23 : 13)
                    }
                }
                .help(modelLabel.map { "\(service.name) · \($0)" } ?? service.name)
                .accessibilityLabel(modelLabel.map { "\(service.name) · \($0)" } ?? service.name)
            if lines.isEmpty {
                VStack(spacing: 2) {
                    Text("—").font(.system(size: 24, weight: .semibold)).frame(height: 27)
                    Text("…").font(.system(size: 9, weight: .medium))
                }.foregroundStyle(QuotaOrbInk.primary)
                    .accessibilityLabel("\(service.name)，尚未获取额度")
            } else if lines.count == 1, let line = lines.first {
                amount(line.value, size: 24).frame(height: 27)
                reset(line.compactResetText, size: 9).frame(height: 10)
            } else if let sharedReset {
                Grid(horizontalSpacing: 3, verticalSpacing: 0) {
                    ForEach(lines) { line in
                        GridRow(alignment: .firstTextBaseline) {
                            label(line)
                            amount(line.value, size: 18).gridColumnAlignment(.trailing)
                        }.frame(height: 19)
                            .accessibilityElement(children: .ignore).accessibilityLabel(line.readingExplanation)
                    }
                }
                reset(sharedReset, size: 8).frame(height: 8)
            } else {
                Grid(horizontalSpacing: 1, verticalSpacing: 1) {
                    ForEach(lines) { line in
                        GridRow(alignment: .firstTextBaseline) {
                            label(line)
                            amount(line.value, size: 14).gridColumnAlignment(.trailing)
                            reset(line.compactResetText, size: 7).gridColumnAlignment(.leading)
                        }.frame(height: 18)
                            .accessibilityElement(children: .ignore).accessibilityLabel(line.readingExplanation)
                    }
                }
            }
        }.frame(width: 68, height: 66)
            .offset(y: lines.count > 1 && sharedReset == nil ? -4 : 0)
            .help(([service.name] + lines.map(\.readingExplanation)).joined(separator: "；") + "；D＝天，H＝小时，M＝分钟，P＝尚未计时")
    }

    private func label(_ line: AmbientQuotaLine) -> some View {
        Text(line.compactLabel).font(.system(size: 8, weight: .medium))
            .foregroundStyle(QuotaOrbInk.secondary).underline(highlightedID == line.id)
            .frame(width: 7, alignment: .leading)
    }
    private func reset(_ text: String, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .medium)).monospacedDigit()
            .fontWidth(size <= 7 ? .condensed : .standard)
            .foregroundStyle(QuotaOrbInk.secondary).lineLimit(1).fixedSize()
    }
    private func amount(_ value: QuotaOverviewValue, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            switch value {
            case .percent(let amount):
                Text("\(amount)")
                Text("%").font(.system(size: size * 0.64, weight: .semibold))
            case .percentBound(let amount, _):
                Text(">\(amount)")
                Text("%").font(.system(size: size * 0.64, weight: .semibold))
            case .unlimited: Text("∞")
            default: Text("—")
            }
        }.font(.system(size: size, weight: .semibold)).monospacedDigit()
            .foregroundStyle(QuotaOrbInk.primary).fixedSize()
    }
}
