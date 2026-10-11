import AppKit
import SwiftUI

@MainActor
final class AmbientNotchPresentation: ObservableObject {
    @Published var isFrontmostAppFullScreen = false
    @Published var centerGapWidth: CGFloat = 96
    @Published var isFloating = false
    @Published private(set) var service: AmbientQuotaService = .codex
    private var selection = AmbientServiceSelection()

    func observeForeground(bundleIdentifier: String?) {
        selection.observe(bundleIdentifier: bundleIdentifier)
        if service != selection.service { service = selection.service }
    }
}

/// The always-visible, glanceable state of the top panel.
///
/// Home and the shelf share their connected sources. Foreground changes choose
/// a presentation, never another quota client or login.
@MainActor
struct AmbientNotchView: View {
    @ObservedObject var codexStatus: CodexStatusStore
    @ObservedObject var connections: QuotaConnectionsStore
    @ObservedObject var presentation: AmbientNotchPresentation
    let onOpen: () -> Void
    var onMove: (NSRect, NSScreen) -> Void = { _, _ in }
    var onDock: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var companionPointer: CGPoint = .zero
    @State private var companionPressed = false
    @State private var releaseTask: Task<Void, Never>?
    @State private var orbMotion = QuotaOrbMotionRelay()

    var body: some View {
        if presentation.isFloating { floatingBubble } else { shelf }
    }

    private var floatingBubble: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let state = quotaPresentation(at: context.date)
            ZStack {
                QuotaLiquidOrb(value: state.liquidValue, reduceMotion: reduceMotion, motion: orbMotion)
                    .frame(width: 78, height: 78)
                if state.service == .doubao {
                    DoubaoAmbientQuotaView(lines: state.lines, placement: .orb)
                } else {
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        AmbientProviderMark(service: state.service, size: 16, attentive: false,
                            pressed: false, quiet: true, working: false, pointer: .zero)
                        if let line = state.lines.first {
                            Text(line.countdownOnly).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.86))
                        }
                    }.frame(height: 20)
                    if state.service == .cursor, state.lines.count > 1 {
                        VStack(spacing: 0) {
                            ForEach(state.lines) { line in
                                Text("\(line.poolLabel ?? "") \(line.value.text)")
                                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            }
                        }.foregroundStyle(QuotaOverviewPalette.primary).frame(height: 30)
                    } else {
                        Text(state.lines.first?.value.text ?? "—")
                            .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(QuotaOverviewPalette.primary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(height: 30)
                    }
                    if let model = state.cursorModel {
                        Text(model.shortLabel).font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.86)).lineLimit(1)
                            .frame(height: 12)
                    } else {
                        Color.clear.frame(height: 12).accessibilityHidden(true)
                    }
                }.frame(width: 62, height: 62).offset(y: -1)
                }
                if case .running(let count) = state.activity {
                    Text(count > 9 ? "9+" : "\(count)")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        .background(Color(white: 0.16), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 6).padding(.trailing, 17)
                }
            }
            .frame(width: 78, height: 78).clipShape(Circle()).padding(7)
            .overlay {
                FloatingQuotaInput(summary: state.summary, onOpen: onOpen, onMove: onMove, onDock: onDock,
                                   motion: orbMotion)
            }
            .preferredColorScheme(.dark)
        }
    }

    private var shelf: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let state = quotaPresentation(at: context.date)
            ZStack {
                Color.black
                GeometryReader { geometry in
                    let inset: CGFloat = presentation.isFrontmostAppFullScreen ? 4 : 5
                    let sideWidth = max(0, (geometry.size.width - inset * 2 - presentation.centerGapWidth) / 2)
                    HStack(spacing: 0) {
                        quotaStrip(state).frame(width: sideWidth)
                        Color.clear
                            .frame(width: presentation.centerGapWidth)
                            .accessibilityHidden(true)
                        activityStatus(state).frame(width: sideWidth)
                    }
                    .padding(.horizontal, inset)
                    .frame(height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard !reduceMotion, !presentation.isFrontmostAppFullScreen else { return }
                            companionPointer = PaulCompanionPointer.normalized(location, in: geometry.size)
                        case .ended:
                            companionPointer = .zero
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                acknowledgeClick()
                onOpen()
            }
            .onHover { hovering in
                if reduceMotion {
                    isHovered = hovering
                } else {
                    withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.18)) { isHovered = hovering }
                }
            }
            .onDisappear {
                releaseTask?.cancel()
                releaseTask = nil
                companionPressed = false
                companionPointer = .zero
                isHovered = false
            }
            .help(state.summary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.summary)
            .accessibilityHint("悬浮仅 Logo 回应，单击打开，再次单击收起")
            .accessibilityAction(.default, onOpen)
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func quotaStrip(_ state: AmbientQuotaPresentation) -> some View {
        if state.service == .doubao {
            DoubaoAmbientQuotaView(lines: state.lines, placement: .notchValues,
                                  isFullScreen: presentation.isFrontmostAppFullScreen)
        } else if state.lines.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: compactFontSize, weight: .medium))
                Text("—")
                    .font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(IslandTheme.text3)
        } else {
            if state.lines.count == 1, let quota = state.lines.first {
                quotaValue(quota)
            } else {
                VStack(spacing: 0) {
                    ForEach(state.lines) { quota in
                        quotaValue(quota)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func quotaValue(_ quota: AmbientQuotaLine) -> some View {
        switch quota.value {
        case .percent(let value):
            AmbientQuotaLabel(
                period: quota.period,
                remaining: value,
                isFullScreen: presentation.isFrontmostAppFullScreen,
                color: quotaColor(Double(value)),
                secondaryColor: IslandTheme.text2
            )
        case .percentBound(let lower, _):
            AmbientQuotaLabel(period: quota.period, remaining: lower,
                isFullScreen: presentation.isFrontmostAppFullScreen, color: quotaColor(Double(lower)),
                secondaryColor: IslandTheme.text2, comparison: ">")
        case .unlimited:
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(quota.period).font(.system(size: quota.period.count > 2 ? 6 : 7, weight: .medium))
                    .foregroundStyle(IslandTheme.text2)
                Text("不限").font(.system(size: presentation.isFrontmostAppFullScreen ? 9 : 10, weight: .semibold))
                    .foregroundStyle(IslandTheme.text1)
            }.lineLimit(1).fixedSize()
        default:
            Text("—").font(.system(size: valueFontSize)).foregroundStyle(IslandTheme.text2)
        }
    }

    private func activityStatus(_ state: AmbientQuotaPresentation) -> some View {
        if state.service == .doubao {
            return AnyView(HStack(spacing: 2) {
                AmbientProviderMark(service: state.service, size: presentation.isFrontmostAppFullScreen ? 10 : 12,
                    attentive: isHovered, pressed: companionPressed, quiet: true, working: false, pointer: companionPointer)
                    .frame(width: presentation.isFrontmostAppFullScreen ? 10 : 12)
                DoubaoAmbientQuotaView(lines: state.lines, placement: .notchResets,
                                      isFullScreen: presentation.isFrontmostAppFullScreen)
            })
        }
        if let model = state.cursorModel {
            return AnyView(VStack(spacing: 1) {
                AmbientProviderMark(service: state.service, size: logoSize, attentive: isHovered,
                    pressed: companionPressed, quiet: true, working: false, pointer: companionPointer)
                    .frame(width: logoSize, height: logoSize)
                Text(model.shortLabel)
                    .font(.system(size: presentation.isFrontmostAppFullScreen ? 7 : 8, weight: .medium))
                    .foregroundStyle(IslandTheme.text2).lineLimit(1).minimumScaleFactor(0.85)
            })
        }
        return AnyView(HStack(spacing: presentation.isFrontmostAppFullScreen ? 5 : 7) {
            AmbientProviderMark(service: state.service, size: logoSize, attentive: isHovered,
                pressed: companionPressed, quiet: reduceMotion || presentation.isFrontmostAppFullScreen,
                working: state.activity.isWorking, pointer: companionPointer)
                .frame(width: presentation.isFrontmostAppFullScreen ? 12 : 16,
                       height: presentation.isFrontmostAppFullScreen ? 12 : 16)
            if let count = state.activity.displayCount {
                Text(count)
                    .font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(state.activity.isWorking ? IslandTheme.text1 : IslandTheme.text2)
            }
        })
    }

    func quotaPresentation(at now: Date) -> AmbientQuotaPresentation {
        QuotaHomePresentation.ambient(service: presentation.service, snapshot: codexStatus.quota,
            error: codexStatus.quotaError, readsEnabled: AppEnvironment.codexStatusReadsEnabled,
            connections: connections, tasksAreFresh: codexStatus.tasksAreFresh,
            runningTaskCount: codexStatus.workingTasks.count, now: now)
    }

    var accessibilitySummary: String { quotaPresentation(at: .now).summary }

    private func acknowledgeClick() {
        guard !reduceMotion, !presentation.isFrontmostAppFullScreen else { return }
        releaseTask?.cancel()
        withAnimation(.easeOut(duration: 0.07)) { companionPressed = true }
        releaseTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(130)) } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.24, dampingFraction: 0.76)) {
                companionPressed = false
            }
            releaseTask = nil
        }
    }

    private var compactFontSize: CGFloat {
        presentation.isFrontmostAppFullScreen ? 8 : 9
    }

    private var valueFontSize: CGFloat {
        presentation.isFrontmostAppFullScreen ? 10 : 11
    }

    private var logoSize: CGFloat {
        presentation.isFrontmostAppFullScreen ? 10 : 13
    }

    private func quotaColor(_ remaining: Double) -> Color {
        // A single semantic state color: plenty remaining is green; increasing
        // usage moves continuously through yellow and orange toward red. The
        // numeric percentage remains the non-color cue.
        let normalizedRemaining = min(max(remaining, 0), 100) / 100
        return Color(
            hue: 0.34 * normalizedRemaining,
            saturation: 0.78,
            brightness: 1
        )
    }

}

private struct RunningTaskMark: View {
    let isFullScreen: Bool
    let reduceMotion: Bool

    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 1.25)
            Circle()
                .trim(from: 0.08, to: 0.66)
                .stroke(
                    IslandTheme.accentBlue,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: isFullScreen ? 10 : 13, height: isFullScreen ? 10 : 13)
        .onAppear { updateRotation() }
        .onChange(of: reduceMotion) { _ in updateRotation() }
        .accessibilityHidden(true)
    }

    private func updateRotation() {
        rotation = 0
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1.45).repeatForever(autoreverses: false)) {
            rotation = 360
        }
    }
}
