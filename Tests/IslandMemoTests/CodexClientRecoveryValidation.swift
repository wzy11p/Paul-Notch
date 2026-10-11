import Foundation

// Synthetic stdio server: exercises the real client/process lifecycle without
// opening any account, reading credentials, or making network/model requests.
@main struct CodexClientRecoveryValidation {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    static let fixtureVariable = "PAUL_CODEX_RECOVERY_FIXTURE"

    static func main() async {
        do {
            if CommandLine.arguments.dropFirst().first == "app-server" {
                try runFixtureServer()
                return
            }
            try await recoversStaleReaderOnce()
            try await persistentQuotaFailureIsBounded()
            try await taskFailureDoesNotRestartQuotaReader()
            try await cancellationDoesNotStartRecovery()
            print("PASS: stale quota recovery, bounded retry, task isolation, and cancellation")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message) }
    }

    static func fixture(_ mode: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("paul-codex-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(mode.utf8).write(to: directory.appendingPathComponent("mode"), options: .atomic)
        setenv(fixtureVariable, directory.path, 1)
        return directory
    }

    static func text(_ name: String, in directory: URL) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }

    static func launchCount(in directory: URL) throws -> Int {
        Int(try text("launches", in: directory)) ?? 0
    }

    static func client() -> IslandCodexAppServerClient {
        IslandCodexAppServerClient(executableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
    }

    static func recoversStaleReaderOnce() async throws {
        let directory = try fixture("account-change")
        let reader = client()
        do {
            let initial = try await reader.readQuota()
            try expect(initial.planType == "free", "fixture must begin with the old account")
            try Data("changed".utf8).write(to: directory.appendingPathComponent("stage"), options: .atomic)
            let recovered = try await reader.readQuota()
            try expect(recovered.planType == "pro", "recovery must read the current account, not cached FREE")
            try expect(recovered.visibleWindows.first?.remainingPercent == 100, "recovered quota must be literal 100%")
            try expect(recovered.visibleWindows.first?.windowDurationMinutes == 10080, "recovered window must be weekly")
            try expect(recovered.freshness == .fresh, "recovered data must be marked fresh")
            try expect(try launchCount(in: directory) == 2, "stale reader must be replaced exactly once")
            _ = try await reader.readQuota()
            try expect(try launchCount(in: directory) == 2, "healthy reads must reuse the recovered reader")
            await reader.stop()
        } catch {
            await reader.stop()
            throw Failure("stale quota recovery failed: \(error)")
        }
    }

    static func persistentQuotaFailureIsBounded() async throws {
        let directory = try fixture("quota-error")
        let reader = client()
        do {
            _ = try await reader.readQuota()
            await reader.stop()
            throw Failure("persistent quota failure must not return a successful snapshot")
        } catch let error as IslandCodexClientError {
            await reader.stop()
            guard case .rpc = error else { throw error }
            try expect(try launchCount(in: directory) == 2, "persistent error must stop after one recovery attempt")
        } catch {
            await reader.stop()
            throw error
        }
    }

    static func taskFailureDoesNotRestartQuotaReader() async throws {
        let directory = try fixture("task-error")
        let reader = client()
        do {
            _ = try await reader.readQuota()
            do {
                _ = try await reader.readRecentTasks(limit: 50)
                throw Failure("task fixture must return an RPC error")
            } catch let error as IslandCodexClientError {
                guard case .rpc = error else { throw error }
            }
            _ = try await reader.readQuota()
            try expect(try launchCount(in: directory) == 1, "task failure must not recycle a healthy quota reader")
            await reader.stop()
        } catch {
            await reader.stop()
            throw error
        }
    }

    static func cancellationDoesNotStartRecovery() async throws {
        let directory = try fixture("cancel-quota")
        let reader = client()
        let operation = Task { try await reader.readQuota() }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("requested").path) {
            if Date() > deadline {
                operation.cancel()
                await reader.stop()
                throw Failure("cancellation fixture did not receive quota request")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        operation.cancel()
        try Data("respond".utf8).write(to: directory.appendingPathComponent("stage"), options: .atomic)
        do {
            _ = try await operation.value
            await reader.stop()
            throw Failure("cancelled read must not return quota")
        } catch is CancellationError {
            await reader.stop()
            try expect(try launchCount(in: directory) == 1, "cancellation must not launch a replacement reader")
        } catch {
            await reader.stop()
            throw error
        }
    }

    static func runFixtureServer() throws {
        guard let path = ProcessInfo.processInfo.environment[fixtureVariable] else {
            throw Failure("missing synthetic fixture directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let mode = try text("mode", in: directory)
        let generation = ((try? launchCount(in: directory)) ?? 0) + 1
        try Data(String(generation).utf8).write(to: directory.appendingPathComponent("launches"), options: .atomic)
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"] else { continue }
            let method = request["method"] as? String
            var response: [String: Any] = ["id": id]
            if method == "initialize" {
                response["result"] = ["userAgent": "synthetic-codex-reader"]
            } else if method == "account/rateLimits/read" {
                if mode == "cancel-quota" {
                    try Data().write(to: directory.appendingPathComponent("requested"))
                    let deadline = Date().addingTimeInterval(5)
                    while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("stage").path) {
                        if Date() > deadline { throw Failure("fixture response gate timed out") }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                let stale = mode == "account-change" && generation == 1
                    && FileManager.default.fileExists(atPath: directory.appendingPathComponent("stage").path)
                if stale || mode == "quota-error" || mode == "cancel-quota" {
                    response["error"] = ["code": -32000, "message": "Synthetic cached session cannot read quota"]
                } else {
                    let oldAccount = mode == "account-change" && generation == 1
                    response["result"] = ["rateLimitsByLimitId": ["codex": [
                        "limitId": "codex", "planType": oldAccount ? "free" : "pro",
                        "primary": ["usedPercent": oldAccount ? 1 : 0,
                                    "windowDurationMins": oldAccount ? 43200 : 10080,
                                    "resetsAt": 1_800_000_000],
                    ]]]
                }
            } else {
                response["error"] = ["code": -32601, "message": "Synthetic unsupported task request"]
            }
            var output = try JSONSerialization.data(withJSONObject: response)
            output.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: output)
        }
    }
}
