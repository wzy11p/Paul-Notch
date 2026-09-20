import AppKit
import SwiftUI

@MainActor
final class AmbientNotchPresentation: ObservableObject {
    @Published var isFrontmostAppFullScreen = false
    @Published var centerGapWidth: CGFloat = 96
}

/// The always-visible, glanceable state of the top panel.
///
/// It intentionally reuses `CodexStatusStore`: the ambient surface is another
/// presentation of the same quota/task state, not another Codex client.
@MainActor
struct AmbientNotchView: View {
    @ObservedObject var codexStatus: CodexStatusStore
    @ObservedObject var presentation: AmbientNotchPresentation
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var companionPointer: CGPoint = .zero
    @State private var companionPressed = false
    @State private var releaseTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            shelfSurface

            GeometryReader { geometry in
                let inset: CGFloat = presentation.isFrontmostAppFullScreen ? 4 : 5
                let sideWidth = max(0, (geometry.size.width - inset * 2 - presentation.centerGapWidth) / 2)
                HStack(spacing: 0) {
                    quotaStrip.frame(width: sideWidth)
                    Color.clear
                        .frame(width: presentation.centerGapWidth)
                        .accessibilityHidden(true)
                    activityStatus.frame(width: sideWidth)
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
                withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.18)) {
                    isHovered = hovering
                }
            }
        }
        .onDisappear {
            releaseTask?.cancel()
            releaseTask = nil
            companionPressed = false
            companionPointer = .zero
            isHovered = false
        }
        .help(hoverSummary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("悬浮仅 Logo 回应，单击打开，再次单击收起")
        .accessibilityAction(.default, onOpen)
        .preferredColorScheme(.dark)
    }

    private var shelfSurface: some View {
        Color.black
    }

    @ViewBuilder
    private var quotaStrip: some View {
        if visibleQuotaWindows.isEmpty {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: compactFontSize, weight: .medium))
                Text("--")
                    .font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(IslandTheme.text3)
        } else {
            HStack(spacing: 2) {
                if visibleQuotaWindows.count == 1, let quota = visibleQuotaWindows.first {
                    quotaValue(quota)
                } else {
                    VStack(spacing: 0) {
                        ForEach(visibleQuotaWindows) { quota in
                            quotaValue(quota)
                        }
                    }
                }

                if quotaIsStale {
                    Circle()
                        .stroke(Color.white.opacity(0.42), lineWidth: 1)
                        .frame(width: 3, height: 3)
                        .accessibilityLabel("Showing the last known quota")
                }
            }
        }
    }

    private func quotaValue(_ quota: CodexQuotaWindow) -> some View {
        AmbientQuotaLabel(
            period: shortLabel(for: quota), remaining: Int(quota.remainingPercent.rounded()),
            isFullScreen: presentation.isFrontmostAppFullScreen, color: quotaColor(quota.remainingPercent),
            secondaryColor: IslandTheme.text2
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.55),
            value: Int(quota.remainingPercent.rounded())
        )
    }

    @ViewBuilder
    private var activityStatus: some View {
        if !codexStatus.tasksAreFresh {
            HStack(spacing: 5) {
                companion
                Text("?").font(.system(size: valueFontSize, weight: .medium))
                    .foregroundStyle(IslandTheme.text2)
            }
            .accessibilityLabel(codexStatus.taskSyncDescription)
        } else if activeTaskCount > 0 {
            HStack(spacing: presentation.isFrontmostAppFullScreen ? 5 : 7) {
                companion
                Text(activeTaskCount > 9 ? "9+" : "\(activeTaskCount)")
                    .font(.system(size: valueFontSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(IslandTheme.text1)
            }
            .transition(.asymmetric(
                insertion: .scale(scale: 0.84).combined(with: .opacity),
                removal: .opacity
            ))
        } else {
            companion
            .transition(.opacity)
            .accessibilityLabel("Codex is idle")
        }
    }

    private var companion: some View {
        PaulCompanionMark(size: logoSize, attentive: isHovered || companionPressed,
                          pressed: companionPressed,
                          quiet: reduceMotion || presentation.isFrontmostAppFullScreen,
                          working: codexStatus.tasksAreFresh && activeTaskCount > 0,
                          pointer: companionPointer)
            .frame(width: presentation.isFrontmostAppFullScreen ? 12 : 16,
                   height: presentation.isFrontmostAppFullScreen ? 12 : 16)
    }

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

    private var visibleQuotaWindows: [CodexQuotaWindow] {
        Array(codexStatus.displayQuotaWindows.sorted { lhs, rhs in
            quotaRank(lhs) < quotaRank(rhs)
        }.prefix(2))
    }

    private var activeTaskCount: Int { codexStatus.workingTasks.count }

    private var quotaIsStale: Bool {
        codexStatus.quota?.freshness == .stale || codexStatus.quotaError != nil
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

    private func shortLabel(for quota: CodexQuotaWindow) -> String {
        switch quota.windowDurationMinutes {
        case 300: return "5H"
        case 10_080: return "7D"
        default: return "Q"
        }
    }

    private func quotaRank(_ quota: CodexQuotaWindow) -> Int {
        switch quota.windowDurationMinutes {
        case 10_080: return 0
        case 300: return 1
        default: return 2
        }
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

    private var hoverSummary: String {
        var parts = visibleQuotaWindows.map { quota in
            "\(quota.shortName)剩余 \(Int(quota.remainingPercent.rounded()))%\(resetDescription(for: quota))"
        }
        parts.append(codexStatus.tasksAreFresh
            ? (activeTaskCount > 0 ? "\(activeTaskCount) 个 Codex 任务正在运行" : "Codex 空闲")
            : codexStatus.taskSyncDescription)
        if quotaIsStale { parts.append("额度是最后一次成功读取的结果") }
        return parts.joined(separator: "，")
    }

    private var accessibilitySummary: String {
        let quotaSummary = visibleQuotaWindows.isEmpty
            ? "Codex quota is temporarily unavailable"
            : visibleQuotaWindows.map { quota in
                "\(quota.shortName) has \(Int(quota.remainingPercent.rounded())) percent remaining"
            }.joined(separator: ", ")
        let taskSummary = !codexStatus.tasksAreFresh ? codexStatus.taskSyncDescription : activeTaskCount > 0
            ? "\(activeTaskCount) Codex tasks are running"
            : "Codex is idle"
        let staleSummary = quotaIsStale ? ", showing the last known quota" : ""
        return "\(quotaSummary), \(taskSummary)\(staleSummary)"
    }

    private func resetDescription(for quota: CodexQuotaWindow) -> String {
        guard let reset = quota.resetsAt else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "，\(formatter.localizedString(for: reset, relativeTo: .now))重置"
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
