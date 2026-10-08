import AppKit
#if canImport(PaulNotchCore)
@testable import PaulNotchCore
#elseif canImport(IslandMemo)
@testable import PaulNotchCore
#endif

@main struct PersistenceFailureValidation {
    @MainActor static func main() async throws {
        precondition(AppEnvironment.isPreview)
        let root = AppEnvironment.dataDirectory
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        var failures: [String] = []
        func check(_ success: Bool, _ name: String) {
            print("\(success ? "PASS" : "FAIL"): \(name)")
            if !success { failures.append(name) }
        }

        let clipboard = ClipboardStore(base: root, pasteboard: board)
        board.setString("synthetic existing clipboard", forType: .string)
        clipboard.copy(ClipboardEntry(id: UUID(), kind: .image, fingerprint: "missing", text: nil,
            imageFileName: "missing.png", copiedAt: .now, sourceApplication: nil))
        check(board.string(forType: .string) == "synthetic existing clipboard",
              "missing cached image never erases current clipboard")
        check(clipboard.errorMessage != nil, "missing image has a visible failure")
        let brokenImage = root.appendingPathComponent("ClipboardImages/broken.png")
        try Data("not a PNG".utf8).write(to: brokenImage)
        clipboard.copy(ClipboardEntry(id: UUID(), kind: .image, fingerprint: "broken", text: nil,
            imageFileName: "broken.png", copiedAt: .now, sourceApplication: nil))
        check(board.string(forType: .string) == "synthetic existing clipboard",
              "nonempty corrupt image never erases current clipboard")

        let corrupt = Data("damaged synthetic JSON, preserve exactly".utf8)
        let commandURL = root.appendingPathComponent("commands.json")
        let linkURL = root.appendingPathComponent("links.json")
        try corrupt.write(to: commandURL)
        try corrupt.write(to: linkURL)
        let commands = CommandsStore()
        let links = LinksStore()
        commands.add(text: "new command must not replace unreadable history")
        await links.add(rawURL: "https://example.org/synthetic")
        try await Task.sleep(for: .milliseconds(250))
        check(try Data(contentsOf: commandURL) == corrupt && commands.commands.isEmpty,
              "corrupt command history is preserved on add")
        check(try Data(contentsOf: linkURL) == corrupt && links.groups.isEmpty,
              "corrupt link history is preserved on add")

        // Keep failure fixtures, and use fresh valid files for ordered-write tests.
        try FileManager.default.moveItem(at: commandURL, to: root.appendingPathComponent("commands-corrupt-fixture.json"))
        try FileManager.default.moveItem(at: linkURL, to: root.appendingPathComponent("links-corrupt-fixture.json"))
        let freshCommands = CommandsStore(), freshLinks = LinksStore()
        let started = Date()
        var linkWrites: [Task<Bool, Never>] = []
        for i in 0..<80 {
            freshCommands.add(text: "\(i) 中文 👨‍👩‍👧‍👦\n" + String(repeating: "multi-line text ", count: 80))
            linkWrites.append(Task { await freshLinks.add(rawURL: "https://example.org/item-\(i)") })
        }
        for write in linkWrites { _ = await write.value }
        check(await freshLinks.flushPendingWrites(), "flush waits for queued link commits")
        print("80 paired commits: \(Int(Date().timeIntervalSince(started) * 1_000)) ms")
        try await Task.sleep(for: .milliseconds(500))
        let restoredCommands = CommandsStore().commands
        check(restoredCommands.map(\.id) == freshCommands.commands.map(\.id)
              && restoredCommands.map(\.text) == freshCommands.commands.map(\.text) && restoredCommands.count == 80,
              "80 rapid command writes survive restart exactly")
        let restoredLinks = LinksStore().groups.flatMap(\.links)
        check(restoredLinks.map(\.id) == freshLinks.groups.flatMap(\.links).map(\.id)
              && restoredLinks.map(\.url) == freshLinks.groups.flatMap(\.links).map(\.url) && restoredLinks.count == 80,
              "80 rapid link writes survive restart exactly")
        let savedCommands = freshCommands.commands, savedLinks = freshLinks.groups
        for url in [commandURL, linkURL] {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("saved"))
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        check(!freshCommands.add(text: "retry command") && freshCommands.commands == savedCommands
              && freshCommands.errorMessage != nil, "failed command write retains durable list and reports failure")
        let failedLink = await freshLinks.add(rawURL: "https://example.org/retry")
        check(!failedLink && freshLinks.groups == savedLinks
              && freshLinks.errorMessage != nil, "failed link write retains durable list and reports failure")
        freshLinks.errorMessage = nil // Dismissing the alert must not authorize data loss on quit.
        let flushedAfterFailure = await freshLinks.flushPendingWrites()
        check(AppDelegate.terminationSaveError(noteError: nil, linksSaved: flushedAfterFailure,
              linkError: freshLinks.errorMessage) != nil,
              "dismissed save error still blocks termination")
        for url in [commandURL, linkURL] {
            try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("blocked-directory"))
            try FileManager.default.moveItem(at: url.appendingPathExtension("saved"), to: url)
        }
        check(freshCommands.add(text: "retry command") && CommandsStore().commands.count == 81
              && freshCommands.errorMessage == nil, "command retry commits once and clears error")
        let retriedLink = await freshLinks.add(rawURL: "https://example.org/retry")
        check(retriedLink && LinksStore().groups.flatMap(\.links).count == 81
              && freshLinks.errorMessage == nil, "link retry commits once and clears error")
        check(AppDelegate.terminationSaveError(noteError: nil, linksSaved: await freshLinks.flushPendingWrites(),
              linkError: freshLinks.errorMessage) == nil,
              "successful retry permits termination")
        // Old workspaces may contain large embedded icons. Saving must yield the
        // main actor while encoding/writing them, not freeze pointer interaction.
        let compactFixture = try Data(contentsOf: linkURL)
        defer { try? compactFixture.write(to: linkURL) } // Do not retain huge synthetic icons after the test.
        let icon = Data(repeating: 0x5A, count: 250_000)
        let large = [LinkGroup(name: "legacy", links: (0..<40).map {
            SavedLink(url: "https://example.org/legacy-\($0)", title: "Synthetic", faviconData: icon)
        })]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(large).write(to: linkURL, options: .atomic)
        let largeStore = LinksStore()
        var finished = false
        let save = Task { @MainActor in
            let result = await largeStore.add(rawURL: "https://example.org/responsive")
            finished = true
            return result
        }
        var responsiveTicks = 0
        while !finished {
            try await Task.sleep(for: .milliseconds(2))
            if !finished { responsiveTicks += 1 }
        }
        let largeSaveSucceeded = await save.value
        check(largeSaveSucceeded, "large legacy icon fixture is saved")
        if !largeSaveSucceeded { print("Fixture save error: \(largeStore.errorMessage ?? "unknown")") }
        check(responsiveTicks > 0, "large legacy icons save without blocking the main actor")
        try compactFixture.write(to: linkURL) // exit(1) below does not run Swift defers.
        if !failures.isEmpty { exit(1) }
    }
}
