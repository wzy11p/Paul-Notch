import SwiftUI

/// The official acquisition page stays inside the existing bounded notch route.
/// Provider credentials still enter only the canonical secure Key form below.
struct QuotaInlineKeyWebsite: View {
    @StateObject private var browser: QuotaSetupBrowser
    init(provider: QuotaSetupProvider) {
        _browser = StateObject(wrappedValue: QuotaSetupBrowser(provider: provider))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(browser.host) · 官方页面").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("登录官网并复制 API Key，再收起官网，粘贴到下方输入框。")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            if let error = browser.error {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange)
                Button("重新加载") { browser.openOfficialPage() }
            }
            QuotaOfficialWebView(browser: browser).frame(height: 250)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            DisclosureGroup("官网无法登录？") {
                Link("改用系统浏览器登录官网", destination: browser.provider.website)
                Text("登录限制时才使用这个入口。复制 Key 后回到刘海粘贴，不代表连接已完成。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.onAppear { browser.openOfficialPage() }.onDisappear { browser.stop() }
    }
}
