import SwiftUI

struct ClipboardHistoryView: View {
    @ObservedObject var store: ClipboardStore
    @ObservedObject var settings: AppSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            captureControls
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(IslandTheme.text1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            history
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(statusTitle).font(.headline)
                    .accessibilityIdentifier("clipboard.capture.status")
                Spacer(minLength: 0)
                if store.captureState == .disabled {
                    actionButton("开启文字记录") {
                        settings.clipboardCapturePaused = false
                        settings.clipboardCaptureText = true
                    }
                } else if store.captureState != .failed {
                    actionButton(settings.clipboardCapturePaused ? "继续记录" : "暂停记录") {
                        settings.clipboardCapturePaused.toggle()
                    }
                }
            }
            Text("仅保存在本机；从开启或恢复后的下一次复制开始记录。")
                .font(.callout).foregroundStyle(IslandTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 20) {
                Toggle("记录文字", isOn: $settings.clipboardCaptureText)
                    .frame(minHeight: 44)
                Toggle("记录图片", isOn: $settings.clipboardCaptureImages)
                    .frame(minHeight: 44)
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox)
            .disabled(store.captureState == .failed)
            Text("关闭两种类型即停止记录，不删除历史。敏感标记会被跳过，但无法识别所有密码。")
                .font(.caption).foregroundStyle(IslandTheme.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusTitle: String {
        switch store.captureState {
        case .disabled: return "复制记录未开启"
        case .paused: return "复制记录已暂停"
        case .recording: return "正在记录"
        case .failed: return "采集已停止 · 存储异常"
        }
    }

    private var emptyMessage: String {
        switch store.captureState {
        case .disabled: return "开启后，可在这里找回之后复制的文字或图片"
        case .paused: return "暂停期间不会记录新内容，也不会补录"
        case .recording: return "暂无记录，试着复制一段普通文字或已开启类型的图片"
        case .failed: return "记录暂不可用，请查看上方原因；不会覆盖原文件"
        }
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).padding(.horizontal, 12).frame(minHeight: 44)
                .background(IslandTheme.surface2, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var history: some View {
        Group {
            if store.entries.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 30)).foregroundStyle(.white.opacity(0.25))
                    Text(emptyMessage)
                        .foregroundStyle(IslandTheme.text2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    HStack(alignment: .top, spacing: 10) {
                        LazyVStack(spacing: 10) {
                            ForEach(Array(store.entries.enumerated()).filter { $0.offset.isMultiple(of: 2) }, id: \.element.id) { _, entry in
                                clipboardRow(entry)
                            }
                        }
                        LazyVStack(spacing: 10) {
                            ForEach(Array(store.entries.enumerated()).filter { !$0.offset.isMultiple(of: 2) }, id: \.element.id) { _, entry in
                                clipboardRow(entry)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }

    private func clipboardRow(_ entry: ClipboardEntry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            switch entry.kind {
            case .text:
                Text(entry.text ?? "")
                    .font(.callout)
                    .lineLimit(settings.clipboardPreviewLines)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            case .image:
                if let image = store.image(for: entry) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 130, alignment: .leading)
                }
            }

            HStack(spacing: 8) {
                Text(entry.copiedAt.formatted(.dateTime.year().month().day().hour().minute().second()))
                    .font(.caption2).foregroundStyle(.white.opacity(0.42))
                if settings.clipboardShowSource,
                   let source = entry.sourceApplication, !source.isEmpty {
                    Text("· \(source)")
                        .font(.caption2).foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer()
                Button { store.copy(entry) } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(11)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }
}
