import Foundation

@main
struct MusicPermissionValidation {
    static func main() {
        let raw = "System Events got an error: osascript is not allowed assistive access. (-1719)"
        precondition(MusicPermissionSnapshot.failureMessage(raw: raw, trusted: false).contains("当前版本"))
        precondition(MusicPermissionSnapshot.failureMessage(raw: raw, trusted: true).contains("检查已通过"))
        precondition(MusicPermissionSnapshot.failureMessage(raw: "not authorized (-1743)", trusted: true).contains("自动化"))
        precondition(MusicPermissionSnapshot.failureMessage(raw: "missing (-1728)", trusted: true).contains("播放菜单"))
        precondition(MusicPermissionSnapshot.failureMessage(raw: "timeout (-1712)", trusted: true).contains("结果未确认"))
        precondition(MusicPermissionSnapshot.failureMessage(raw: "unfamiliar", trusted: false).contains("原始错误"))
        for (status, expected) in [(Int32(0), "已允许"), (-1743, "已拒绝"), (-1744, "尚未授权"), (-600, "未运行"), (-50, "未确定")] {
            let sample = MusicPermissionSnapshot(checkedAt: .now, accessibilityTrusted: true,
                automationStatus: status, playerRunning: false, appPath: "/synthetic/Paul.app",
                bundleID: "synthetic", signingFingerprint: "synthetic")
            precondition(sample.automationDescription.contains(expected))
        }
        print("PASS: 11 music diagnostic classifications; no permission requests or playback operations")
    }
}
