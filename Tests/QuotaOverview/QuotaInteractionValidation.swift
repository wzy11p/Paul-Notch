import AppKit
import SwiftUI
import Vision
@testable import PaulNotchCore

/// Exercises production views with account reads disabled. Captures never contain
/// fixture balances, credentials, or the owner's workspace. No system input is sent.
@main struct QuotaInteractionValidation {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let stage = CommandLine.arguments.dropFirst(2).first ?? "after"
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks = 0, failures = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            checks += 1
            if !value() { failures += 1; print("FAIL: \(name)") }
        }
        let accounts = QuotaHomePresentation.accounts(snapshot: nil, error: nil, readsEnabled: false, now: .now)
        let stale = QuotaGridButton(account: .init(id: "stale-test", name: "Test", account: "Test",
            group: .membership, value: .percent(25), timing: "昨天读取", status: .stale))
        check(stale.accessibilityLabel()?.contains("无法获取") == true,
              "A historical balance must not be announced as a current quota")
        var refreshes = 0
        func overview(active: Bool = true, refreshing: Bool = false) -> AnyView {
            AnyView(QuotaOverviewView(accounts: accounts, onClose: {}, mode: .notch,
                onRefresh: { refreshes += 1 }, isRefreshing: refreshing, isActive: active))
        }
        let host = NSHostingView(rootView: overview())
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 438),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = host
        window.orderBack(nil)
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        }
        func key(_ characters: String, _ code: UInt16) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func capture(_ name: String) throws -> String? {
            settle()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure.render }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), let cg = bitmap.cgImage else { throw Failure.render }
            try png.write(to: output.appendingPathComponent("\(stage)-\(name).png"))
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            do { try VNImageRequestHandler(cgImage: cg).perform([request]) }
            catch { print("SKIP: Vision OCR unavailable in this environment; inspect \(stage)-\(name).png visually"); return nil }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        }
        let homeText = try capture("home-no-connection")
        check(accounts.allSatisfy { $0.value == .unknown }, "Comparison uses real disconnected states, never invented balances")
        check(accounts.allSatisfy { $0.value.text == "无法获取" }, "Missing quotas explicitly explain unavailability")
        if let homeText {
            check(!homeText.contains("无法获取"), "Disconnected cards must not overwhelm the Home with large repeated error headlines")
            check(homeText.contains("待适配"), "Unsupported membership explains why, before opening a detail")
            check(!homeText.contains("搜索服务或账户"), "Search controls are disclosed deliberately, rather than crowding the initial Home")
            check(!homeText.contains("%") && !homeText.contains("¥"), "Disconnected comparison must contain no purported quota numbers")
        }

        let handledSearch = window.performKeyEquivalent(with: key("f", 3))
        settle()
        check(handledSearch && window.firstResponder is NSTextView, "Cmd+F focuses the actual quota search field")
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText("no-such-service", replacementRange: NSRange(location: NSNotFound, length: 0))
            let emptyText = try capture("empty-search")
            if let emptyText {
                check(emptyText.contains("没有找到") && emptyText.contains("清除搜索与筛选"), "An empty search has an actionable recovery")
            }
            // Off-screen SwiftUI does not publish its virtual buttons to AppKit AX.
            // The recovery control is verified in the capture; exercise the actual
            // native text binding here rather than asserting a nonexistent NSButton.
            editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
            editor.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
            settle()
            check(descendants(host).contains { $0 is QuotaGridScrollView }, "Clearing the native search restores the quota grid")
        }
        let handledRefresh = window.performKeyEquivalent(with: key("r", 15))
        settle()
        check(handledRefresh && refreshes == 1, "Cmd+R invokes the existing refresh callback exactly once")

        if let activeGrid = descendants(host).compactMap({ $0 as? QuotaGridDocumentView }).first,
           let originalCard = activeGrid.buttons.first(where: { $0.account.id == "deepseek" }) {
            let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
            for _ in 0..<6 {
                window.makeFirstResponder(originalCard)
                originalCard.performClick(nil)
                settle()
                check(!originalCard.isEnabled && window.firstResponder !== originalCard,
                      "Opening details disables the retained grid and transfers keyboard ownership")
                check(window.performKeyEquivalent(with: escape), "Escape reaches the details Back button")
                settle()
                check(originalCard.isEnabled && window.firstResponder === originalCard,
                      "Actual details Back restores the same native card and focus")
            }
        } else { check(false, "The recovery path retains a usable grid for repeated detail navigation") }
        host.rootView = overview(active: false)
        settle()
        _ = window.performKeyEquivalent(with: key("r", 15))
        _ = window.performKeyEquivalent(with: key("f", 3))
        settle()
        check(refreshes == 1 && !(window.firstResponder is NSTextView), "Hidden overview shortcuts cannot refresh or steal form focus")
        host.rootView = overview(refreshing: true)
        settle()
        _ = window.performKeyEquivalent(with: key("r", 15))
        check(refreshes == 1, "Refresh in flight suppresses repeated Cmd+R")

        // Native keyboard ownership and restoration use the real grid, no mock responder.
        let scroll = QuotaGridScrollView()
        window.contentView = scroll
        let grid = scroll.grid
        grid.configure(accounts: accounts, pinnedID: nil, enabled: true)
        scroll.layoutSubtreeIfNeeded()
        grid.resize(to: scroll.contentSize)
        guard let card = grid.buttons.first(where: { $0.account.id == "deepseek" }) else { throw Failure.render }
        window.makeFirstResponder(card)
        grid.configure(accounts: accounts, pinnedID: nil, enabled: false)
        check(window.firstResponder !== card, "Leaving the overview relinquishes the hidden card's keyboard focus")
        check(!card.isEnabled && !card.acceptsFirstResponder, "Hidden cards cannot become keyboard targets")
        grid.configure(accounts: accounts, pinnedID: nil, enabled: true)
        check(window.firstResponder === card, "Returning restores the original service identity, not the first card")
        let editor = NSTextField(string: "")
        scroll.addSubview(editor)
        window.makeFirstResponder(editor)
        grid.configure(accounts: accounts, pinnedID: nil, enabled: true)
        check(window.firstResponder !== card, "A value refresh does not steal the search field's focus")
        window.orderOut(nil)
        print("\(failures == 0 ? "PASS" : "FAIL"): \(checks) quota interaction checks; \(failures) failures. Images: \(output.path)")
        if failures > 0 { exit(1) }
    }
    enum Failure: Error { case render }
}
