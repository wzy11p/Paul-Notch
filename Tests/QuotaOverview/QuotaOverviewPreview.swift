import AppKit
import SwiftUI

@MainActor private final class QuotaPreviewState: ObservableObject {
    @Published var count = 7
}

private struct QuotaPreviewHarness: View {
    @StateObject private var state = QuotaPreviewState()
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("预览账户数量").font(.system(size: 12))
                Picker("预览账户数量", selection: $state.count) {
                    ForEach([0, 4, 7, 12, 30], id: \.self) { Text("\($0)").tag($0) }
                }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                Spacer()
                Text("不读取账户，不修改正式版").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).frame(height: 44).background(Color(white: 0.1))
            QuotaOverviewView(accounts: QuotaOverviewFixtures.accounts(count: state.count)) {
                NSApp.terminate(nil)
            }
        }.preferredColorScheme(.dark)
    }
}

@MainActor private final class QuotaPreviewDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationMenu = NSMenuItem()
        let commands = NSMenu()
        commands.addItem(withTitle: "退出交互预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenu.submenu = commands
        menu.addItem(applicationMenu)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editing = NSMenu(title: "编辑")
        editing.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editing.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editing.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editing.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editing
        menu.addItem(edit)
        NSApp.mainMenu = menu

        let host = NSHostingView(rootView: QuotaPreviewHarness())
        // AppKit owns the preview's fixed height; account text cannot expand it.
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 554),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Paul Notch · 额度交互预览（示例数据）"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 600, height: 554)
        window.contentMaxSize = NSSize(width: 1100, height: 554)
        window.contentView = host
        window.backgroundColor = .black
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main private struct QuotaOverviewPreview {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = QuotaPreviewDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
