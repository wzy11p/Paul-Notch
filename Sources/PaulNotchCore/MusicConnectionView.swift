import SwiftUI

/// The same narrow diagnostic entry is available from Home and standalone music.
struct MusicConnectionView: View {
    @ObservedObject var music: MusicService
    var compact = false
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
            music.checkQQMusicConnection()
        } label: {
            Label(compact ? "连接异常 · 查看原因" : "检查连接", systemImage: compact ? "exclamationmark.triangle" : "info.circle")
                .font(compact ? .caption : .callout)
                .foregroundStyle(compact ? Color.orange : Color.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("QQ 音乐连接检查").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let issue = music.connectionIssue { Text(issue) }
                        Text("只读取状态，不播放音乐、不申请或修改权限。")
                            .foregroundStyle(.secondary)
                        if let state = music.permissionSnapshot {
                            Text("本进程辅助功能：" + (state.accessibilityTrusted ? "已认可" : "未认可"))
                            Text("系统事件自动化：" + state.automationDescription)
                            Text("QQ 音乐：" + (state.playerRunning ? "正在运行" : "未运行"))
                            if !state.accessibilityTrusted {
                                Text("若系统设置中的开关已开启，可能是授权记录仍对应旧版本。请核对下方“当前应用”路径，再重新添加该应用；不要修改其他应用权限。")
                                    .foregroundStyle(.secondary)
                            }
                            Text("当前应用：\n" + state.appPath)
                            Text("应用标识：\n" + state.bundleID)
                            Text("签名指纹：\n" + state.signingFingerprint)
                            Text("检查时间：" + state.checkedAt.formatted(date: .omitted, time: .standard))
                        }
                        if let error = music.lastQQMusicError {
                            Divider()
                            Text("上次控制原始错误").font(.subheadline.weight(.semibold))
                            Text(error)
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 290)
                Button { music.checkQQMusicConnection() } label: {
                    Text(music.isCheckingConnection ? "正在检查…" : "重新检查")
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(music.isCheckingConnection)
            }.padding(16).frame(width: 340)
        }
    }
}
