import SwiftUI

/// A small management entry for existing categories, not a custom module system.
struct MemoCategoryManager: View {
    @ObservedObject var settings: AppSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: MemoCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("管理分类").font(.headline)
                Spacer()
                Button("完成") { dismiss() }
                    .frame(minWidth: 44, minHeight: 44)
            }
            Text("在横栏中拖动排序。分类名称最多 16 个字。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(settings.memoCategories) { category in
                MemoCategoryNameRow(category: category, onSave: { name in
                    settings.updateMemoCategory(category, name: name)
                }, onDelete: { deleting = category }, canDelete: settings.memoCategories.count > 1)
            }
            HStack {
                Button {
                    settings.addMemoCategory()
                } label: {
                    Label("添加分类", systemImage: "plus")
                        .frame(minHeight: 44).contentShape(Rectangle())
                }
                .disabled(settings.memoCategories.count >= 4)
                Spacer()
                Text("\(settings.memoCategories.count) / 4").font(.caption).foregroundStyle(.secondary)
            }
            if let error = settings.settingsError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .buttonStyle(.plain)
        .padding(16)
        .frame(width: 340)
        .background(IslandTheme.background)
        .preferredColorScheme(.dark)
        .alert("删除这个分类？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除分类", role: .destructive) {
                if let deleting { settings.removeMemoCategory(deleting) }
                deleting = nil
            }
        } message: {
            Text("不会删除任务或笔记。原任务仍在“全部分类”中，不会被自动放入其他分类。")
        }
    }
}

private struct MemoCategoryNameRow: View {
    let category: MemoCategory
    let onSave: (String) -> Void
    let onDelete: () -> Void
    let canDelete: Bool
    @State private var editing = false
    @State private var name = ""

    var body: some View {
        HStack(spacing: 4) {
            if editing {
                TextField("分类名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel("分类名称")
                Button(action: save) {
                    Image(systemName: "checkmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }.help("保存分类名称").accessibilityLabel("保存分类名称")
                Button { editing = false } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
                }.help("取消改名").accessibilityLabel("取消改名")
            } else {
                Button { name = category.name; editing = true } label: {
                    HStack {
                        Text(category.name).lineLimit(1)
                        Spacer()
                        Image(systemName: "pencil").foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }.help("修改分类名称")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .disabled(!canDelete)
                .help("删除分类，不删除内容")
                .accessibilityLabel("删除\(category.name)分类")
            }
        }
    }

    private func save() {
        onSave(name)
        editing = false
    }
}
