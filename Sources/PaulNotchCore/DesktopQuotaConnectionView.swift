import SwiftUI
import AppKit

struct DesktopQuotaConnectionView: View {
    @ObservedObject var store: DesktopQuotaStore
    let provider: DesktopQuotaProvider
    private var state: DesktopQuotaStore.State? { store.states[provider] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接已登录的 \(provider.name)").font(.system(size: 16, weight: .semibold))
            Text("不用 API Key。点击读取会短暂打开原应用的额度页，读取后回到这里。只取额度，不读取密码、Cookie 或对话。")
                .foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Label(store.isReading(provider) ? "正在打开额度页并读取…" :
                    (state?.snapshot == nil ? "尚未读到账户额度" : "已读取 · \(store.account(provider).value.text) 剩余"),
                  systemImage: store.isReading(provider) ? "arrow.triangle.2.circlepath" :
                    (state?.snapshot == nil ? "link" : "checkmark.circle"))
                .font(.system(size: 13, weight: .medium))
            if let error = state?.error {
                Text(error.message).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if error == .permission {
                    Button("打开辅助功能设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                    }.buttonStyle(.bordered).controlSize(.large)
                    Text("在系统列表中开启 Paul Notch；不会自动修改权限，也不会反复弹密码。")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(store.isReading(provider) ? "正在读取…" : (state?.snapshot == nil ? "连接并读取额度" : "重新读取额度")) {
                    store.read(provider)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!store.allowsReads || store.isReading(provider))
                .accessibilityIdentifier("quota-desktop-\(provider.rawValue)-read")
                if state?.error == .notRunning {
                    Button("打开 \(provider.name)") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: provider.bundleID) {
                            NSWorkspace.shared.openApplication(at: url, configuration: .init())
                        }
                    }.buttonStyle(.bordered).controlSize(.large)
                }
            }
            Text("额度页位置：\(provider.instructions)")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("页面可读取时自动更新；离开额度页可能无法更新，会标明上次读取时间。不同额度池分别显示，不猜重置日期。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let snapshot = state?.snapshot {
                ForEach(snapshot.pools, id: \.name) { pool in
                    LabeledContent("\(pool.name)剩余", value: "\(pool.remaining)%")
                }
                LabeledContent("额度重置", value: snapshot.resetLabel ?? "原页面未提供")
                if let expiry = snapshot.expiryLabel { LabeledContent("活动赠送期限", value: expiry) }
                LabeledContent("最近读取", value: snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if store.enabled.contains(provider) {
                Button("断开连接", role: .destructive) { store.disconnect(provider) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }.font(.system(size: 12))
    }
}
