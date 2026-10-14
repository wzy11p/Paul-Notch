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
                QuotaOrbReadingBackdrop()
                QuotaLiquidOrb(value: state.liquidValue, reduceMotion: reduceMotion, motion: orbMotion)
                    .frame(width: QuotaFloatingPlacement.orbDiameter, height: QuotaFloatingPlacement.orbDiameter)
                QuotaOrbReadout(service: state.service, lines: state.lines,
                                highlightedID: state.cursorModel?.pool?.rawValue,
                                modelLabel: state.cursorModel?.pool == nil ? nil : state.cursorModel?.shortLabel)
                if case .running(let count) = state.activity {
                    Text(count > 9 ? "9+" : "\(count)")
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
                        .padding(.horizontal, 3).padding(.vertical, 2)
                        .background(Color(white: 0.16), in: Circle())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(.top, 6).padding(.trailing, 17)
                }
            }
            .frame(width: QuotaFloatingPlacement.orbDiameter, height: QuotaFloatingPlacement.orbDiameter)
            .clipShape(Circle()).padding(7)
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
                    let inset: CGFloat = presentation.isFrontmostAppFullScreen ? 2 : 3
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
            .accessibilityHint("鼠标进入菜单栏时自动收缩让位，离开立即恢复；单击原生刘海中间或从菜单栏 P 图标打开面板")
            .accessibilityAction(.default, onOpen)
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func quotaStrip(_ state: AmbientQuotaPresentation) -> some View {
        if state.lines.isEmpty {
            Text("—").font(.system(size: 10, weight: .semibold)).foregroundStyle(IslandTheme.text2)
        } else {
            QuotaGlanceRows(lines: state.lines, placement: .notchValues,
                isFullScreen: presentation.isFrontmostAppFullScreen,
                highlightedID: state.cursorModel?.pool?.rawValue)
        }
    }

    private func activityStatus(_ state: AmbientQuotaPresentation) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                AmbientProviderMark(service: state.service, size: presentation.isFrontmostAppFullScreen ? 10 : 13,
                    attentive: isHovered, pressed: companionPressed,
                    quiet: reduceMotion || presentation.isFrontmostAppFullScreen,
                    working: state.activity.isWorking, pointer: companionPointer)
                    .frame(width: presentation.isFrontmostAppFullScreen ? 10 : 13,
                           height: presentation.isFrontmostAppFullScreen ? 10 : 13)
                if case .running(let count) = state.activity {
                    Text(count > 9 ? "9+" : "\(count)")
                        .font(.system(size: presentation.isFrontmostAppFullScreen ? 9 : 10, weight: .semibold))
                        .foregroundStyle(.white).monospacedDigit()
                }
            }
            if state.lines.isEmpty {
                Text("待更新").font(.system(size: 7, weight: .medium)).foregroundStyle(IslandTheme.text2)
            } else if state.lines.count > 1 {
                QuotaGlanceRows(lines: state.lines, placement: .notchResets,
                               isFullScreen: presentation.isFrontmostAppFullScreen)
            }
        }
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
