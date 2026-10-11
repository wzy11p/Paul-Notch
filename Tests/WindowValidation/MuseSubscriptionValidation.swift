import AppKit
import WebKit
@testable import PaulNotchCore

@main struct MuseSubscriptionValidation {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited); NSApp.finishLaunching()
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.loadSimulatedRequest(URLRequest(url: URL(string: "https://muse.ai/")!), responseHTML: "<html></html>")
        for _ in 0..<100 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let action = String(repeating: "a", count: 40)
        func read(_ sub: String, mode: String = "cached", cached: String? = action) async throws -> MuseSubscriptionResult {
            let fixture = #"""
            let posts = 0, gets = 0;
            const response = (text,status=200) => new Response(text,{status});
            globalThis.fetch = async (url,init={}) => {
              if (!String(url).startsWith('https://muse.ai/') || init.headers?.Cookie || init.credentials !== 'same-origin') throw Error('unsafe request');
              if (init.method === 'POST') {
                posts++;
                if (init.body !== '[{"includeAgreement":true}]' || !init.headers['Next-Action']) throw Error('not the readonly subscription action');
                if (mode === 'stale' && posts === 1) return response('Server action not found',404);
                if (mode === 'forbidden') return response('blocked',403);
                if (mode === 'expired') return response('expired',401);
                if (mode === 'oversize') return response('x'.repeat(300000));
                return response('0:{"ignored":"DO-NOT-EXPORT"}\n1:'+payload+'\n');
              }
              gets++;
              if (String(url) === 'https://muse.ai/') return response('<script src="/_next/static/chunks/app.js"></script>');
              if (String(url).endsWith('/app.js')) return response('e.A(123).then(({preloadHatchSettingsData});[123,e=>{e.v(e=>Promise.all(["static/chunks/settings.js"])');
              if (String(url).endsWith('/settings.js')) return response('createServerReference("'+action+'",a,b,"fetchSubscriptionAction")');
              throw Error('unexpected fetch');
            };
            """#
            let raw = try await view.callAsyncJavaScript(fixture + "\nconst result = await (async () => {\n" + MuseSubscriptionReader.script + "\n})();\n" + #"""
            if ((mode === 'cached' && (posts !== 1 || gets !== 0)) || posts > 2 || gets > 3) throw Error('unbounded or unnecessary requests');
            if (result.includes('DO-NOT-EXPORT')) throw Error('unrelated response escaped');
            return result;
            """#, arguments: ["payload": sub, "mode": mode, "action": action, "cachedActionID": cached ?? ""],
                in: nil, contentWorld: .defaultClient)
            guard let text = raw as? String else { throw QuotaConnectionError.invalidData }
            return try JSONDecoder().decode(MuseSubscriptionResult.self, from: Data(text.utf8))
        }
        let paid = #"{"success":true,"subscription":{"usage":{"percentUsed":29.25,"resetsAt":1791635400},"tier":{"name":"Power"},"agreement":{"currentPeriodEndTime":1794000000},"topupBalance":1230000,"topupTotal":2000000,"topupRowValueLabel":"38% used (1.2M tokens left)","password":"DO-NOT-EXPORT"}}"#
        let result = try await read(paid)
        let snapshot = try result.snapshot(at: Date(timeIntervalSince1970: 1791000000))
        try check(snapshot.value == .percent(70) && snapshot.resetsAt == Date(timeIntervalSince1970: 1791635400), "exact usage and reset must survive the lightweight read")
        try check(snapshot.pools.count == 1 && snapshot.details.contains(where: { $0.value.contains("1.2M tokens left") }), "micro-dollar topup balance must never become an invented token count")
        try check(snapshot.details.contains(where: { $0.label == "额外余额到期" && $0.value == "官方未提供到期时间" }),
                  "a topup without an explicit expiry fact cannot be reported as never expiring")
        for mode in ["discover", "stale"] {
            let value = try await read(paid, mode: mode, cached: mode == "discover" ? nil : action)
            try check(value.state == "ok" && value.actionID == action, "missing or retired deployment action must rediscover once")
        }
        for (payload, expected) in [
            (#"{"success":true,"subscription":{"usage":{"percentUsed":0}}}"#, "ok"),
            (#"{"success":true,"subscription":{"usage":{"percentUsed":100}}}"#, "ok"),
            (#"{"success":true,"subscription":{"usage":{"percentUsed":null}}}"#, "format"),
            (#"{"success":true,"subscription":{"usage":{"percentUsed":101}}}"#, "format"),
            (#"{"success":true,"subscription":{"usage":{"percentUsed":true}}}"#, "format"),
            (#"{"success":false}"#, "format")
        ] { try check(try await read(payload).state == expected, "malformed or missing usage cannot look like a real balance") }
        try check(try await read(paid, mode: "expired").state == "authentication", "401 is a failed saved login")
        try check(try await read(paid, mode: "forbidden").state == "unavailable", "403 alone must not erase a valid login")
        try check(try await read(paid, mode: "oversize").state == "format", "oversized responses must be bounded")
        view.stopLoading()
        print("PASS: lightweight Muse subscription, bounded deployment discovery, precise units, no unrelated payload or credentials")
    }
    static func check(_ valid: Bool, _ message: String) throws {
        if !valid {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            throw NSError(domain: "MuseSubscription", code: 1)
        }
    }
}
