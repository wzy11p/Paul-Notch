import AppKit
@testable import PaulNotchCore
#if canImport(XCTest)
import XCTest
#else
// The owner's Command Line Tools omit XCTest. Same test bodies can run standalone;
// full Xcode/CI uses the real SwiftPM XCTest target above.
class XCTestCase {}
struct XCTSkip: Error { init(_ message: String) { fatalError(message) } }
func XCTAssertTrue(_ value: @autoclosure () -> Bool) { precondition(value()) }
func XCTAssertFalse(_ value: @autoclosure () -> Bool) { precondition(!value()) }
func XCTAssertNil<T>(_ value: T?, _ message: String = "") { precondition(value == nil, message) }
func XCTAssertNotNil<T>(_ value: T?) { precondition(value != nil) }
func XCTAssertEqual<T: Equatable>(_ left: T, _ right: T) { precondition(left == right) }
func XCTAssertNotEqual<T: Equatable>(_ left: T, _ right: T) { precondition(left != right) }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T) {
    do { _ = try value(); preconditionFailure("Expected an error") } catch {}
}

#if !SWIFT_PACKAGE_TESTS
@main struct SafetyTestRunner {
    static func main() async throws {
        let tests = SafetyTests()
        try tests.testPreviewRejectsBroadAndLivePaths()
        try tests.testPreviewStableAndDistinctNamespaces()
        try tests.testPreviewRejectsSymlinkToLiveData()
        tests.testTranscriptionHostCannotBeChangedByWorkspaceID()
        tests.testHTTPRejectsUnsafeLengths()
        try await tests.testClipboardOptInAndSensitiveExclusion()
        await tests.testPasswordExpiryDoesNotEraseNewCopy()
        try await tests.testCorruptClipboardIsNeverOverwritten()
        try await tests.testClipboardInitializerDoesNotRewriteOrTrim()
        try await tests.testAllStoresUsePreviewEnvironment()
        try tests.testPreviewPreferencePersistence()
        print("PASS: 11 safety regression groups (standalone; XCTest unavailable)")
    }
}
#endif
#endif

final class SafetyTests: XCTestCase, @unchecked Sendable {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("paul-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testPreviewRejectsBroadAndLivePaths() throws {
        let production = URL(fileURLWithPath: "/Users/synthetic/Library/Application Support/IslandMemo")
        for path in ["/", "/tmp", "relative", "", "/Users/synthetic", production.path] {
            XCTAssertThrowsError(try AppDataEnvironment(previewDirectory: path, productionDirectory: production))
        }
    }

    func testPreviewStableAndDistinctNamespaces() throws {
        let production = URL(fileURLWithPath: "/Users/synthetic/Library/Application Support/IslandMemo")
        let root = try folder()
        let first = try AppDataEnvironment(previewDirectory: root.path, productionDirectory: production)
        let restarted = try AppDataEnvironment(previewDirectory: root.path, productionDirectory: production)
        let second = try AppDataEnvironment(previewDirectory: try folder().path, productionDirectory: production)
        XCTAssertEqual(first.preferencesSuite, restarted.preferencesSuite)
        XCTAssertNotEqual(first.preferencesSuite, second.preferencesSuite)
        XCTAssertTrue(first.isPreview)
        XCTAssertEqual(try AppDataEnvironment(previewDirectory: nil, productionDirectory: production).dataDirectory, production)
    }

    func testPreviewPreferencePersistence() throws {
        guard let suite = AppEnvironment.current.preferencesSuite else { throw XCTSkip("Requires isolated test environment") }
        let key = "synthetic-restart-sentinel"
        if let previous = AppEnvironment.defaults.string(forKey: key) { XCTAssertEqual(previous, "retained") }
        AppEnvironment.defaults.set("retained", forKey: key)
        XCTAssertTrue(AppEnvironment.defaults.synchronize())
        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: key), "retained")
    }

    func testPreviewRejectsSymlinkToLiveData() throws {
        let root = try folder(), live = try folder()
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live)
        XCTAssertThrowsError(try AppDataEnvironment(previewDirectory: alias.path, productionDirectory: live))
    }

    func testTranscriptionHostCannotBeChangedByWorkspaceID() {
        for input in ["example.com/", "a@evil.example", "a.b", "a/b", "a\\b", " a", "a\n", "-a", "a-", String(repeating: "a", count: 64)] {
            XCTAssertNil(TranscriptionConfig(region: "beijing", workspaceId: input).websocketURL, input)
        }
        XCTAssertEqual(TranscriptionConfig(region: "beijing", workspaceId: "abc-123").websocketURL?.host,
                       "abc-123.cn-beijing.maas.aliyuncs.com")
        XCTAssertEqual(TranscriptionConfig(region: "singapore", workspaceId: "").websocketURL?.host,
                       "dashscope-intl.aliyuncs.com")
    }

    func testHTTPRejectsUnsafeLengths() {
        for raw in ["-1", "+1", "no", "", "999999999999999999999999", "1048577"] {
            XCTAssertNil(NotificationHTTPPolicy.contentLength(of: "POST /notify/codex HTTP/1.1\r\nContent-Length: " + raw))
        }
        XCTAssertNil(NotificationHTTPPolicy.contentLength(of: "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1"))
        XCTAssertNil(NotificationHTTPPolicy.contentLength(of: "POST / HTTP/1.1\r\nTransfer-Encoding: chunked"))
        XCTAssertEqual(NotificationHTTPPolicy.contentLength(of: "POST / HTTP/1.1\r\nContent-Length: 12"), 12)
        XCTAssertEqual(NotificationHTTPPolicy.contentLength(of: "POST / HTTP/1.1"), 0)
    }

    func testClipboardOptInAndSensitiveExclusion() async throws {
        let root = try folder()
        await MainActor.run {
            let defaults = UserDefaults(suiteName: "local.paul.test." + UUID().uuidString)!
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let store = ClipboardStore(base: root, defaults: defaults, pasteboard: board)
            board.setString("synthetic prior content", forType: .string)
            store.pollPasteboard()
            XCTAssertTrue(store.entries.isEmpty)
            defaults.set(true, forKey: "clipboard-capture-text")
            store.applyPreferences()
            store.pollPasteboard()
            XCTAssertTrue(store.entries.isEmpty)
            board.clearContents(); board.setString("synthetic opted-in content", forType: .string)
            store.pollPasteboard()
            XCTAssertEqual(store.entries.count, 1)
            SensitivePasteboard.write("synthetic credential", to: board, expires: false)
            store.pollPasteboard()
            XCTAssertEqual(store.entries.count, 1)
            for type in SensitivePasteboard.excludedTypes {
                board.clearContents(); board.setString("synthetic hidden", forType: .string)
                board.setString("", forType: type)
                store.pollPasteboard()
                XCTAssertEqual(store.entries.count, 1)
            }
        }
    }

    func testPasswordExpiryDoesNotEraseNewCopy() async {
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            SensitivePasteboard.write("synthetic secret", to: board, expires: false)
            let count = board.changeCount
            SensitivePasteboard.clearIfUnchanged(board, expectedChangeCount: count)
            XCTAssertNil(board.string(forType: .string))
            SensitivePasteboard.write("synthetic secret", to: board, expires: false)
            let previous = board.changeCount
            board.clearContents(); board.setString("new user content", forType: .string)
            SensitivePasteboard.clearIfUnchanged(board, expectedChangeCount: previous)
            XCTAssertEqual(board.string(forType: .string), "new user content")
        }
    }

    func testCorruptClipboardIsNeverOverwritten() async throws {
        let root = try folder(), bytes = Data("not valid json".utf8)
        let file = root.appendingPathComponent("clipboard-history.json")
        try bytes.write(to: file)
        await MainActor.run {
            let defaults = UserDefaults(suiteName: "local.paul.test." + UUID().uuidString)!
            defaults.set(true, forKey: "clipboard-capture-text")
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            let store = ClipboardStore(base: root, defaults: defaults, pasteboard: board)
            XCTAssertNotNil(store.errorMessage)
            store.applyPreferences()
            board.setString("synthetic new entry", forType: .string)
            store.pollPasteboard()
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testClipboardInitializerDoesNotRewriteOrTrim() async throws {
        let root = try folder(), file = root.appendingPathComponent("clipboard-history.json")
        let bytes = Data("[ ]\n".utf8)
        try bytes.write(to: file)
        await MainActor.run {
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            _ = ClipboardStore(base: root, pasteboard: board)
        }
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testAllStoresUsePreviewEnvironment() async throws {
        // Requires the documented test runner env; never instantiate live stores by accident.
        guard AppEnvironment.isPreview else { throw XCTSkip("Run scripts/test-safety.sh for isolated store integration") }
        await MainActor.run {
            let settings = AppSettingsStore()
            XCTAssertFalse(settings.clipboardCaptureText)
            XCTAssertFalse(settings.clipboardCaptureImages)
            XCTAssertFalse(settings.credentialsAllowReveal)
            _ = ClipboardStore()
            _ = LinksStore()
            _ = CommandsStore()
            _ = RecordingStore()
            _ = CredentialsStore()
            _ = AgentNotifyServer()
            XCTAssertNil(KeychainHelper.read(key: "synthetic-preview-only"))
            XCTAssertFalse(KeychainHelper.save(key: "synthetic-preview-only", value: "synthetic"))
            KeychainHelper.delete(key: "synthetic-preview-only")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppEnvironment.dataDirectory.appendingPathComponent("Recordings").path))
    }
}
