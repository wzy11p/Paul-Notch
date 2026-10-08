import Foundation

/// Public packaging must not inherit the maintainer's historical workspace or
/// silently discard an independently owned website login on an ordinary launch.
@main struct PublicRuntimeValidation {
    static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            if value { print("PASS: \(name)") }
            else { print("FAIL: \(name)"); failures += 1 }
        }
        let support = URL(fileURLWithPath: "/tmp/paul-public-synthetic-support", isDirectory: true)
        let publicEnvironment = try AppDataEnvironment.resolve(arguments: [], environment: [:],
            bundleInfo: [:], bundleIdentifier: "io.github.wzy11p.PaulNotch",
            applicationSupportDirectory: support)
        check(publicEnvironment.dataDirectory.path == "/tmp/paul-public-synthetic-support/Paul Notch",
              "Public default preserves its existing Paul Notch data location")
        if AppEnvironment.isPreview {
            check(!AppEnvironment.ownedQuotaConnectionsEnabled,
                  "Disposable preview cannot open real quota connections")
            check(AppEnvironment.ownedWebsiteDefaults == nil,
                  "Disposable preview cannot persist a personal website login")
        } else if #available(macOS 14, *) {
            check(AppEnvironment.ownedQuotaConnectionsEnabled,
                  "Ordinary public launch permits its own opt-in quota connections")
            check(AppEnvironment.ownedWebsiteDefaults != nil,
                  "Ordinary public launch can restore its independently owned website profile")
        } else {
            check(AppEnvironment.ownedQuotaConnectionsEnabled,
                  "Ordinary public launch permits its own opt-in API quota connections")
            check(AppEnvironment.ownedWebsiteDefaults == nil,
                  "Unsupported systems do not fall back to a shared WebKit store")
        }
        if failures > 0 { exit(1) }
    }
}
