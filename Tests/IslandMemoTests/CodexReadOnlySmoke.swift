import Foundation

/// Opt-in smoke check. Prints counts only; no titles, paths, prompts or credentials.
@main
struct CodexReadOnlySmoke {
    static func main() async {
        let client = IslandCodexAppServerClient()
        let started = Date()
        do {
            _ = try await client.readQuota()
            async let quota = client.readQuota()
            async let tasks = client.readRecentTasks(limit: 50)
            let result = try await (quota, tasks)
            print("PASS: quota windows=\(result.0.visibleWindows.count), task count=\(result.1.count), seconds=\(Date().timeIntervalSince(started))")
        } catch { print("FAIL: \(error.localizedDescription)") }
        await client.stop()
    }
}
