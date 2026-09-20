import AppKit
import ApplicationServices
import Carbon
import Security

/// Read-only, in-process observations. Never prompts, resets TCC, launches a target or sends a playback event.
struct MusicPermissionSnapshot: Sendable {
    let checkedAt: Date
    let accessibilityTrusted: Bool
    let automationStatus: Int32?
    let playerRunning: Bool
    let appPath: String
    let bundleID: String
    let signingFingerprint: String

    static func read() -> Self {
        let eventsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty
        let automation: Int32?
        if eventsRunning {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            automation = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
        } else {
            automation = nil
        }
        return Self(checkedAt: .now, accessibilityTrusted: AXIsProcessTrusted(),
                    automationStatus: automation,
                    playerRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tencent.QQMusicMac").isEmpty,
                    appPath: Bundle.main.bundlePath,
                    bundleID: Bundle.main.bundleIdentifier ?? "未知",
                    signingFingerprint: fingerprint())
    }

    var automationDescription: String {
        switch automationStatus {
        case 0: return "已允许"
        case -1743: return "已拒绝（-1743）"
        case -1744: return "尚未授权（-1744）"
        case -600, nil: return "系统事件未运行，未检查"
        case let code?: return "未确定（\(code)）"
        }
    }

    static func failureMessage(raw: String, trusted: Bool) -> String {
        if raw.contains("-1743") {
            return "系统事件的自动化权限被拒绝。打开「检查连接」查看状态；打开播放器不受影响。"
        }
        let isAccessibilityError = raw.localizedCaseInsensitiveContains("assistive")
            || raw.contains("辅助访问") || raw.contains("辅助功能") || raw.contains("-1719")
        if isAccessibilityError {
            return trusted
                ? "应用自身的辅助功能检查已通过，但脚本控制仍被拒绝。请查看「检查连接」中的原始错误。"
                : "系统尚未认可当前版本的辅助功能授权。若开关已开启，可能是旧版本授权记录；请查看「检查连接」。"
        }
        if raw.contains("-1728") { return "未找到 QQ 音乐的播放菜单，请先打开播放器主窗口再试。" }
        if raw.contains("-1712") { return "QQ 音乐控制超时，结果未确认，请先查看播放器状态，避免连续重试。" }
        return "QQ 音乐控制未成功，请在「检查连接」中查看原始错误。"
    }

    private static func fingerprint() -> String {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return "不可用" }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return "不可用" }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let hash = values[kSecCodeInfoUnique as String] as? Data else { return "不可用" }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
