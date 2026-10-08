import AppKit
import SwiftUI
import WebKit
@testable import PaulNotchCore

@MainActor private final class InputProbeState: ObservableObject {
    @Published var status = "Preparing synthetic Muse input"
}

private struct InputProbeView: View {
    @ObservedObject var state: InputProbeState
    @ObservedObject var store: WebsiteQuotaStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paul · synthetic input check").font(.headline)
            Text(state.status).font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
            WebsiteQuotaConnectionView(store: store)
        }.padding(16).background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark)
    }
}

/// CUA drives real pointer/keyboard input in this isolated native fixture.
/// Its exact public Muse origin is simulated; it cannot send account data.
@main struct QuotaNativeClickValidation {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await validate(); exit(0) }
            catch { print("BLOCKED: synthetic native input fixture failed to initialize"); fflush(nil); exit(2) }
        }
        // Physical input needs the normal AppKit event loop, not a partial
        // async-main/manual-poll simulation of WindowServer dispatch.
        NSApp.run()
    }

    @MainActor static func validate() async throws {
        let state = InputProbeState()
        let browser = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true, loadImmediately: false)
        let store = WebsiteQuotaStore(provider: .muse, allowsConnections: true, factory: { _ in browser })
        store.beginLogin()
        let host = NSHostingView(rootView: InputProbeView(state: state, store: store))
        host.sizingOptions = []
        let panel = IslandPanel(contentRect: NSRect(x: 170, y: 180, width: 620, height: 530),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Paul Synthetic Input Check"
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        var clicks = 0
        var hit = "none"
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            if event.window === panel {
                clicks += 1
                if let view = host.hitTest(host.convert(event.locationInWindow, from: nil)) {
                    var ancestor: NSView? = view
                    var classes: [String] = []
                    while let current = ancestor, classes.count < 5 {
                        classes.append(String(describing: type(of: current)))
                        ancestor = current.superview
                    }
                    hit = classes.joined(separator: ">")
                }
            }
            return event
        }
        defer {
            if let monitor { NSEvent.removeMonitor(monitor) }
            store.stop(); panel.orderOut(nil); panel.close()
        }
        browser.webView.loadSimulatedRequest(URLRequest(url: WebsiteQuotaProvider.muse.quotaURL),
            responseHTML: """
            <html><body style="background:#191919;color:white;font:18px -apple-system;padding:24px">
            <p>Local synthetic page — no account submission</p>
            <input id="account" aria-label="Synthetic Muse input" placeholder="Type only test text here"
              style="width:90%;height:50px;font:18px -apple-system;background:#333;color:white;border:1px solid #888;border-radius:14px">
            </body></html>
            """)
        for _ in 0..<600 {
            let focused = (try? await browser.webView.evaluateJavaScript("document.activeElement?.id || 'none'")) as? String ?? "loading"
            let matches = (try? await browser.webView.evaluateJavaScript("document.getElementById('account')?.value === 'native-focus-ok'")) as? Bool ?? false
            state.status = "active=\(NSApp.isActive), key=\(panel.isKeyWindow), clicks=\(clicks), DOM=\(focused), responder=\(panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none"), hit=\(hit)"
            if matches {
                guard panel.isKeyWindow, focused == "account", clicks > 0 else {
                    print("FAIL: synthetic text arrived without verified native keyboard ownership"); exit(1)
                }
                state.status = "PASS: native click and keyboard text reached only the local synthetic field"
                print("PASS: real native click and keyboard text reached the synthetic Muse field; no account data"); fflush(nil)
                try await Task.sleep(for: .seconds(8))
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("BLOCKED: no successful real pointer/keyboard handoff observed in synthetic fixture"); fflush(nil); exit(2)
    }
}
