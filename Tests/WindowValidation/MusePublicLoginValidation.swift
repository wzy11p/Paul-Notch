import AppKit
import WebKit
@testable import PaulNotchCore

/// Deliberate anonymous smoke test, not part of the offline regression suite.
/// Never uses an existing profile, enters credentials or accepts an agreement.
@main struct MusePublicLoginValidation {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let browser = WebsiteQuotaBrowser(provider: .muse, allowsConnections: true)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 568, height: 310),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0
        window.contentView = browser.webView; window.orderBack(nil)
        defer { browser.stop(); window.orderOut(nil); window.close() }
        for _ in 0..<450 {
            if !browser.webView.isLoading, browser.webView.url != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard browser.error == nil, !browser.webView.isLoading, let url = browser.webView.url,
              WebsiteQuotaProvider.muse.permitsOrigin(url) else {
            print("FAIL: anonymous official Muse login did not finish its permitted navigation")
            if let error = browser.error { print(error) }
            fflush(nil); exit(1)
        }
        print("Anonymous official page: \(url.scheme ?? "")://\(url.host ?? "")\(url.path)")
        // New anonymous profile: only public sign-in labels/counts are observed.
        let controls = try await browser.webView.evaluateJavaScript(#"""
            JSON.stringify([...document.querySelectorAll('button,a,input')].slice(0,120).map(e => {
              const text = (e.innerText || e.getAttribute('aria-label') || e.getAttribute('placeholder') || '').trim();
              return /log in|sign in|登录|continue|继续|email|邮箱|phone|手机|get started|开始/i.test(text) ? text.slice(0,80) : null;
            }).filter(Boolean));
            """#) as? String
        print("Anonymous sign-in controls: \(controls ?? "none")")
        try await Task.sleep(for: .milliseconds(1200))
        let snapshot = try await browser.webView.takeSnapshot(configuration: nil)
        if let data = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        }
        guard let controls, controls != "[]", !NSApp.isActive else {
            print("FAIL: no visible first-login controls, or background test activated the app")
            fflush(nil); exit(1)
        }
        print("PASS: anonymous official login renders in an independent WebKit session; no personal account acceptance claimed")
    }
}
