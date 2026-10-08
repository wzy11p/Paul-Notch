import Foundation

/// Model only the installation boundary; never launch an executable or read account data.
private final class InstalledExecutables: FileManager, @unchecked Sendable {
    let executablePaths: Set<String>
    init(_ paths: [String]) { executablePaths = Set(paths); super.init() }
    override func isExecutableFile(atPath path: String) -> Bool { executablePaths.contains(path) }
}

@main struct CodexExecutableLocatorValidation {
    static func main() {
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        let paths = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "\(userApps)/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "\(userApps)/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/test-explicit-path/codex"
        ]
        var failed = false
        for path in paths {
            let found = IslandCodexExecutableLocator.locate(fileManager: InstalledExecutables([path]),
                                                            environment: ["PATH": "/test-explicit-path"])
            if found?.path != path { print("FAIL: Installed Codex entry was not found: \(path)"); failed = true }
        }
        if IslandCodexExecutableLocator.locate(fileManager: InstalledExecutables([]), environment: [:]) != nil {
            print("FAIL: No installation must remain unavailable"); failed = true
        }
        guard !failed else { exit(1) }
        print("PASS: current/legacy app locations, user Applications, CLI PATH and absent-installation handling")
    }
}
