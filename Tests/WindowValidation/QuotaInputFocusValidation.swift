import AppKit
import SwiftUI
import WebKit
@testable import PaulNotchCore

/// Actual panel/WebKit input routing with an entirely synthetic document.
/// No owner page, credential, keyboard monitor or system-generated event is used.
@main struct QuotaInputFocusValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let editingCommands = CommandLine.arguments.contains("--edit-commands")
        let crossApp = CommandLine.arguments.contains("--cross-app") || editingCommands
        NSApp.setActivationPolicy(crossApp ? .accessory : .prohibited)
        NSApp.finishLaunching()
        if crossApp {
            try await validateInactiveMuseClick(validateEditing: editingCommands)
            return
        }
        let browser = QuotaSetupBrowser(provider: .miniMax)
        let host = NSHostingView(rootView: QuotaOfficialWebView(browser: browser))
        host.sizingOptions = []
        let panel = IslandPanel(contentRect: NSRect(x: -10000, y: -10000, width: 568, height: 280),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        panel.contentView = host
        panel.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        defer { browser.stop(); panel.orderOut(nil); panel.close() }
        let companion = IslandPanel(contentRect: NSRect(x: -10000, y: -10000, width: 200, height: 80),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        companion.isReleasedWhenClosed = false
        companion.alphaValue = 0
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        companion.contentView = editor
        defer { companion.orderOut(nil); companion.close() }
        browser.webView.loadSimulatedRequest(URLRequest(url: URL(string: "https://account.minimax.cn/unified-login")!),
            responseHTML: """
            <html><body><input id="phone" style="position:absolute;left:20px;top:30px;width:240px;height:40px"
            aria-label="Synthetic phone input"><input id="code" style="position:absolute;left:20px;top:100px;width:240px;height:40px"
            aria-label="Synthetic verification input"></body></html>
            """)
        for _ in 0..<200 {
            if (try? await browser.webView.evaluateJavaScript("document.getElementById('phone') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard (try? await browser.webView.evaluateJavaScript("document.getElementById('phone') !== null")) as? Bool == true else {
            print("BLOCKED: synthetic input document did not load"); exit(2)
        }
        companion.makeKeyAndOrderFront(nil)
        companion.makeFirstResponder(editor)
        guard companion.isKeyWindow, NSApp.keyWindow === companion else {
            print("BLOCKED: isolated native fixture cannot establish the prior keyboard window"); exit(2)
        }
        let local = NSPoint(x: 70, y: browser.webView.isFlipped ? 50 : browser.webView.bounds.height - 50)
        let point = browser.webView.convert(local, to: nil)
        click(panel, at: point)
        try await Task.sleep(for: .milliseconds(100))
        guard panel.isKeyWindow, NSApp.keyWindow === panel else {
            print("FAIL: one click on the embedded login input must move keyboard ownership from the prior editor to the notch panel"); exit(1)
        }
        type("focus-ok", in: panel)
        for _ in 0..<100 {
            if (try? await browser.webView.evaluateJavaScript("document.getElementById('phone').value")) as? String == "focus-ok" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let entered = (try? await browser.webView.evaluateJavaScript("document.getElementById('phone').value")) as? String
        guard entered == "focus-ok", editor.string.isEmpty else {
            print("FAIL: typed synthetic text must reach only the clicked WebKit input, not the previous native editor"); exit(1)
        }
        companion.makeKeyAndOrderFront(nil)
        companion.makeFirstResponder(editor)
        let codePoint = browser.webView.convert(NSPoint(x: 70,
            y: browser.webView.isFlipped ? 120 : browser.webView.bounds.height - 120), to: nil)
        click(panel, at: codePoint)
        try await Task.sleep(for: .milliseconds(100))
        guard NSApp.keyWindow === panel else { print("FAIL: login input must reacquire keyboard ownership after app switching"); exit(1) }
        type("987654", in: panel)
        try await Task.sleep(for: .milliseconds(100))
        let code = (try? await browser.webView.evaluateJavaScript("document.getElementById('code').value")) as? String
        let retained = (try? await browser.webView.evaluateJavaScript("document.getElementById('phone').value")) as? String
        guard code == "987654", retained == "focus-ok", editor.string.isEmpty else {
            print("FAIL: one-click reacquisition must target the new field without corrupting the prior draft or editor"); exit(1)
        }
        companion.makeKeyAndOrderFront(nil)
        companion.makeFirstResponder(editor)
        editor.string = "native-edit-sample"
        let nativeSelectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: companion.windowNumber,
            context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        guard !QuotaInteractiveWebView.performEditingKeyEquivalent(nativeSelectAll, in: companion),
              companion.performKeyEquivalent(with: nativeSelectAll), editor.selectedRange().length == 18 else {
            print("FAIL: owned WebKit editing must leave the existing native editor command route intact"); exit(1)
        }
        type("native-edit-ok", in: companion)
        guard editor.string == "native-edit-ok",
              (try? await browser.webView.evaluateJavaScript("document.getElementById('phone').value")) as? String == "focus-ok" else {
            print("FAIL: native editing must not modify the owned website draft"); exit(1)
        }

        // Parent and owned login popup must use the same first-click policy,
        // but merely creating/loading an offscreen reader may not steal focus.
        companion.makeKeyAndOrderFront(nil)
        companion.makeFirstResponder(editor)
        let owned = WebsiteQuotaBrowser(provider: .miniMaxCN, allowsConnections: true, loadImmediately: false)
        defer { owned.stop() }
        owned.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true // fixture-only user-popup stand-in
        owned.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.miniMaxCN.quotaURL),
            responseHTML: "<html><body id='owned-fixture'>Synthetic owned parent</body></html>")
        for _ in 0..<200 {
            if (try? await owned.webView.evaluateJavaScript("document.getElementById('owned-fixture') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard NSApp.keyWindow === companion else { print("FAIL: background page creation/navigation must not take keyboard ownership"); exit(1) }
        _ = try await owned.webView.evaluateJavaScript("window.fixtureChild=window.open('about:blank');null")
        for _ in 0..<100 where owned.loginPopup == nil { try await Task.sleep(for: .milliseconds(10)) }
        guard let child = owned.loginPopup else { print("BLOCKED: synthetic owned popup did not open"); exit(2) }
        guard owned.webView.acceptsFirstMouse(for: nil), child.acceptsFirstMouse(for: nil),
              NSApp.keyWindow === companion else {
            print("FAIL: owned parent/popup must accept a user's first click without taking focus on creation"); exit(1)
        }
        print("PASS: one-click embedded login key ownership and real WebKit text routing; no live account or system keyboard injection")
    }

    /// The original check exercised two windows in the same inactive program.
    /// This catches WebKit receiving a deliberate input click while its
    /// nonactivating host still lacks system keyboard ownership. The ordinary
    /// direct-window fixture hides that missing WebKit-to-window handoff.
    @MainActor static func validateInactiveMuseClick(validateEditing: Bool = false) async throws {
        let browser = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false)
        let store = WebsiteQuotaStore(provider: .muse, allowsConnections: true, factory: { _ in browser })
        store.beginLogin()
        let host = NSHostingView(rootView: WebsiteQuotaConnectionView(store: store))
        host.sizingOptions = []
        let panel = IslandPanel(contentRect: NSRect(x: -10000, y: -10000, width: 568, height: 450),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 1 // Still offscreen; exercise the visible-panel policy.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        defer { store.stop(); panel.orderOut(nil); panel.close() }
        browser.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.muse.quotaURL),
            responseHTML: """
            <html><body><input id="account" aria-label="Synthetic Muse account"
              style="position:absolute;left:20px;top:30px;width:240px;height:40px"></body></html>
            """)
        for _ in 0..<200 {
            if (try? await browser.webView.evaluateJavaScript("document.getElementById('account') !== null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard (try? await browser.webView.evaluateJavaScript("document.getElementById('account') !== null")) as? Bool == true,
              browser.webView.window === panel else {
            print("BLOCKED: isolated Muse connection input was not attached and loaded"); exit(2)
        }
        guard !NSApp.isActive, !panel.isKeyWindow else {
            print("FAIL: opening or loading a Muse login must not activate Paul before a user click"); exit(1)
        }
        // A page may focus a DOM field without permission to claim the native
        // keyboard. Native/AX focus acquisition must not be confused with that.
        _ = try await browser.webView.evaluateJavaScript("document.getElementById('account').focus()")
        try await Task.sleep(for: .milliseconds(100))
        guard !panel.isKeyWindow else {
            print("FAIL: page-script focus alone may not claim another application's keyboard"); exit(1)
        }
        let local = NSPoint(x: 70, y: browser.webView.isFlipped ? 50 : browser.webView.bounds.height - 50)
        let point = browser.webView.convert(local, to: nil)
        for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: eventType, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if eventType == .leftMouseDown { browser.webView.mouseDown(with: event) }
            else { browser.webView.mouseUp(with: event) }
        }
        for _ in 0..<100 where !NSApp.isActive { try await Task.sleep(for: .milliseconds(10)) }
        guard NSApp.isActive, panel.isKeyWindow, NSApp.keyWindow === panel else {
            print("FAIL: deliberate Muse input mouse-down must claim both the native key panel and application keyboard ownership"); exit(1)
        }
        type("muse-focus-ok", in: panel)
        for _ in 0..<100 {
            if (try? await browser.webView.evaluateJavaScript("document.getElementById('account').value")) as? String == "muse-focus-ok" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard (try? await browser.webView.evaluateJavaScript("document.getElementById('account').value")) as? String == "muse-focus-ok" else {
            print("FAIL: the first Muse click must both activate the app and focus the intended WebKit field"); exit(1)
        }
        if validateEditing {
            // Exercise actual WebKit selection without reading or changing the
            // owner's general pasteboard. A no-menu accessory panel must route
            // standard editing commands beyond native NSTextView responders.
            let selectAll = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            print("Editing responder: \(panel.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none")")
            guard panel.performKeyEquivalent(with: selectAll) else {
                let responder = panel.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none"
                print("FAIL: the owned WebKit login must receive standard editing shortcuts; current responder: \(responder)"); exit(1)
            }
            for _ in 0..<100 {
                if (try? await browser.webView.evaluateJavaScript("document.getElementById('account').selectionStart === 0 && document.getElementById('account').selectionEnd === 13")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            type("replaced-ok", in: panel)
            for _ in 0..<100 {
                if (try? await browser.webView.evaluateJavaScript("document.getElementById('account').value")) as? String == "replaced-ok" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard (try? await browser.webView.evaluateJavaScript("document.getElementById('account').value")) as? String == "replaced-ok" else {
                print("FAIL: Command-A must select the actual WebKit field, not merely report handling the shortcut"); exit(1)
            }
            let unrelatedShortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .option],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
            guard !QuotaInteractiveWebView.performEditingKeyEquivalent(unrelatedShortcut, in: panel) else {
                print("FAIL: modified unrelated shortcuts may not become website edit actions"); exit(1)
            }
            panel.orderOut(nil)
            guard !QuotaInteractiveWebView.performEditingKeyEquivalent(selectAll, in: panel) else {
                print("FAIL: a hidden owned reader cannot receive an editing action"); exit(1)
            }
            print("PASS: owned WebKit standard editing shortcut selects and replaces actual synthetic input; no pasteboard access")
        }
        print("PASS: inactive accessory Muse user input click claims keyboard ownership and routes synthetic text; page-script focus does not; no live account input")
    }

    @MainActor static func type(_ text: String, in window: NSWindow) {
        for character in text {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                isARepeat: false, keyCode: 0) else { fatalError("Missing synthetic key event") }
            NSApp.keyWindow?.sendEvent(event)
        }
    }

    @MainActor static func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { fatalError("Missing synthetic mouse event") }
            window.sendEvent(event)
        }
    }
}
