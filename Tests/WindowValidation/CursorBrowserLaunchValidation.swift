import AppKit
@testable import PaulNotchCore

@MainActor private final class LaunchGate {
    var requests: [URL] = []
    var continuation: CheckedContinuation<Void, Error>?
    func open(_ url: URL) async throws {
        requests.append(url)
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ error: Error? = nil) {
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
        continuation = nil
    }
}

@main struct CursorBrowserLaunchValidation {
    @MainActor static func main() async throws {
        var failures = 0
        func check(_ condition: Bool, _ reason: String) {
            if !condition { failures += 1; print("FAIL: \(reason)") }
        }
        let url = CursorQuotaLoginAttempt(at: .now).loginURL
        let gate = LaunchGate()
        let launcher = CursorQuotaBrowserLauncher(allowsOpening: true, opener: { try await gate.open($0) })
        launcher.open(url)
        await settle()
        check(launcher.phase == .opening && gate.requests == [url],
              "A deliberate action must submit the current owned PKCE URL to the browser opener; it is not yet opened")
        launcher.open(url)
        await settle()
        check(gate.requests.count == 1, "Repeated clicks must not open several login tabs while opening is in progress")
        gate.finish(LaunchFailure.test)
        await settle()
        if case .failed = launcher.phase {} else { check(false, "OS/browser rejection must show a failure, not pretend Chrome opened") }
        launcher.open(url)
        await settle()
        gate.finish()
        await settle()
        check(launcher.phase == .opened && gate.requests.count == 2,
              "Retry becomes opened only after the opener confirms success; this is not account authentication")
        launcher.cancel()
        launcher.open(url)
        await settle()
        launcher.cancel()
        gate.finish()
        await settle()
        check(launcher.phase == .idle, "A late open completion cannot restore a canceled login state")

        let denied = CursorQuotaBrowserLauncher(allowsOpening: false, opener: { try await gate.open($0) })
        denied.open(url)
        await settle()
        check(gate.requests.count == 3, "Preview denial happens before any OS/browser invocation")
        for bad in ["https://cursor.com.evil.invalid/loginDeepControl", "file:///tmp/login", "https://cursor.com/api/auth/callback",
                    "https://cursor.com/loginDeepControl?challenge=short&uuid=bad&mode=login&redirectTarget=cli"] {
            launcher.open(URL(string: bad)!)
            await settle()
            check(gate.requests.count == 3, "Reject unrelated/malformed login URLs before browser invocation")
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        check(launcher.copyLink(url, to: board) && board.string(forType: .string) == url.absoluteString,
              "An explicit copy action provides the same owned login link without exporting credentials")
        check(!denied.copyLink(url, to: board), "Preview cannot copy a live login link")
        if failures > 0 { exit(1) }
        print("PASS: owned Chrome launch, actual-completion states, retry/coalescing, cancellation, exact login scope and explicit private-pasteboard fallback")
    }
    @MainActor private static func settle() async { try? await Task.sleep(for: .milliseconds(20)) }
    enum LaunchFailure: Error { case test }
}
