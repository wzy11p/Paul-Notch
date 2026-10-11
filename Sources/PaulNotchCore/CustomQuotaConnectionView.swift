import SwiftUI
import AppKit

/// The same native notch route owns discovery, validation and saved connection.
/// It never embeds a website or stores a manually entered balance.
struct CustomQuotaConnectionView: View {
    @ObservedObject var store: CustomQuotaConnectionsStore
    let definition: CustomQuotaDefinition?
    let preset: CustomQuotaPreset?
    let onConnected: (String) -> Void
    @State private var name: String
    @State private var endpoint: String
    @State private var auth: CustomQuotaAuth
    @State private var key = ""
    @State private var inputError: String?
    @State private var editingKey = false
    @State private var confirmsDisconnect = false
    @State private var remainingPath = ""
    @State private var subtractPath = ""
    @State private var subtractsUsage = false
    @State private var resetPath = ""
    @State private var unit: CustomQuotaUnit? = nil
    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, endpoint, key }

    init(store: CustomQuotaConnectionsStore, definition: CustomQuotaDefinition? = nil,
         preset: CustomQuotaPreset? = nil, onConnected: @escaping (String) -> Void) {
        self.store = store; self.definition = definition; self.preset = preset; self.onConnected = onConnected
        _name = State(initialValue: definition?.name ?? preset?.name ?? "")
        _endpoint = State(initialValue: definition?.endpoint ?? preset?.endpoint ?? "")
        _auth = State(initialValue: definition?.auth ?? preset?.auth ?? .bearer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let definition, !editingKey { savedConnection(definition) }
            else if store.setupFields != nil { fieldSelection }
            else { connectionForm }
            if let error = inputError ?? store.setupError ?? store.registryError {
                Text(verbatim: error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("quota-custom-error")
            }
            if !store.allowsConnections {
                Text("隔离预览不会查询接口或保存 Key，请在正式版连接。")
                    .foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 12))
        .onAppear { adoptVerifiedMapping() }
        .onChange(of: store.setupFields) { _ in adoptVerifiedMapping() }
        .onDisappear { key = ""; focused = nil; store.cancelSetup() }
        .confirmationDialog("断开这个 API 连接？", isPresented: $confirmsDisconnect) {
            Button("断开并删除已保存的 Key", role: .destructive) {
                guard let definition else { return }
                if store.disconnect(definition.id) { onConnected(definition.id) }
            }
        } message: { Text("只移除这个连接，不会删除其他账户。仅想隐藏卡片，请使用首页的移除功能。") }
    }

    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(definition == nil ? "连接真实 API 额度" : "更换这个连接的 Key")
                .font(.system(size: 16, weight: .semibold))
            if definition == nil {
                TextField("服务或账户名称", text: $name).textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .name).accessibilityIdentifier("quota-custom-name")
                TextField("HTTPS 只读额度接口", text: $endpoint).textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .endpoint).accessibilityIdentifier("quota-custom-endpoint")
                Picker("认证方式", selection: $auth) {
                    ForEach(CustomQuotaAuth.allCases) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("quota-custom-auth")
            }
            if auth != .none {
                HStack(spacing: 10) {
                    SecureField("粘贴 API Key，不是登录密码", text: $key).textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .key).accessibilityIdentifier("quota-custom-key")
                        .onSubmit { verify() }
                    Button("粘贴 Key", action: pasteKey).buttonStyle(.bordered)
                        .accessibilityIdentifier("quota-custom-paste")
                }
            }
            if let preset {
                Text(preset.keyNote).foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
                Link("查看官方接口说明", destination: preset.documentation)
            }
            if let url = try? CustomQuotaEndpoint.prepare(endpoint), let host = url.host {
                Text("仅向 \(host) 发送 GET 额度查询\(auth == .none ? "。" : "和这枚 Key。")不会调用模型、不发送聊天；不跟随跳转。")
                    .foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("填写平台文档里的余额或用量接口，不是官网首页。没有额度接口的桌面会员暂不能用这种方式连接。")
                    .foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(store.isVerifying ? "正在验证…" : "验证只读接口", action: verify)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!store.allowsConnections || store.isVerifying || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || endpoint.isEmpty || (auth != .none && key.isEmpty))
                    .accessibilityIdentifier("quota-custom-verify")
                if definition != nil {
                    Button("取消更换") { editingKey = false; key = ""; store.cancelSetup() }.buttonStyle(.bordered)
                }
            }
            Text("验证成功后选择余额字段和单位，再保存。Key 只存本机独立钥匙串，退出和更新后自动恢复；官方 Key 失效才需更换。")
                .foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fieldSelection: some View {
        let numbers = (store.setupFields ?? []).filter { $0.number != nil }
        let dates = (store.setupFields ?? []).filter { $0.date != nil }
        return VStack(alignment: .leading, spacing: 12) {
            Text("确认显示什么额度").font(.system(size: 16, weight: .semibold))
            Text("以下是这次接口实际返回的数字。按平台说明选择，未保存前不会加入首页。")
                .foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Picker(subtractsUsage ? "总额度字段" : "剩余额度字段", selection: $remainingPath) {
                Text("选择字段").tag("")
                ForEach(numbers) { Text($0.summary).tag($0.path) }
            }.disabled(definition != nil).accessibilityIdentifier("quota-custom-remaining")
            if definition == nil {
                Toggle("用总额度减去已用额度", isOn: $subtractsUsage)
                    .accessibilityIdentifier("quota-custom-subtract-toggle")
            }
            if subtractsUsage {
                Picker("已用额度字段", selection: $subtractPath) {
                    Text("选择字段").tag("")
                    ForEach(numbers.filter { $0.path != remainingPath }) { Text($0.summary).tag($0.path) }
                }.disabled(definition != nil).accessibilityIdentifier("quota-custom-subtract")
            }
            Picker("显示单位", selection: $unit) {
                Text("选择单位").tag(Optional<CustomQuotaUnit>.none)
                ForEach(CustomQuotaUnit.allCases) { Text($0.title).tag(Optional($0)) }
            }.disabled(definition != nil).accessibilityIdentifier("quota-custom-unit")
            if !dates.isEmpty {
                Picker("重置时间", selection: $resetPath) {
                    Text("接口未提供 / 不显示").tag("")
                    ForEach(dates) { Text($0.label).tag($0.path) }
                }.disabled(definition != nil).accessibilityIdentifier("quota-custom-reset")
            }
            if let mapping, let snapshot = store.preview(mapping: mapping) {
                HStack(alignment: .firstTextBaseline) {
                    Text(CustomQuotaConnectionsStore.value(snapshot).text)
                        .font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    Text("真实查询预览 · 尚未保存").foregroundStyle(QuotaOverviewPalette.secondary)
                }.accessibilityIdentifier("quota-custom-live-preview")
                Text(snapshot.resetsAt.map { "重置时间：\($0.formatted(date: .abbreviated, time: .shortened))" }
                     ?? "接口未提供重置时间，首页不会猜测。")
                    .foregroundStyle(QuotaOverviewPalette.secondary)
            } else {
                Text("选择有效的余额字段和单位后，这里显示真实预览。")
                    .foregroundStyle(QuotaOverviewPalette.secondary)
            }
            HStack {
                Button("保存并开始自动更新") {
                    guard let mapping, let id = store.commit(mapping: mapping) else { return }
                    key = ""; onConnected(id)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(mapping.flatMap { store.preview(mapping: $0) } == nil)
                .accessibilityIdentifier("quota-custom-save")
                Button("重新读取", action: verify).buttonStyle(.bordered).disabled(store.isVerifying)
            }
        }
    }

    private var mapping: CustomQuotaMapping? {
        guard let unit, !remainingPath.isEmpty, !subtractsUsage || !subtractPath.isEmpty else { return nil }
        return .init(remainingPath: remainingPath, subtractPath: subtractsUsage ? subtractPath : nil,
                     resetPath: resetPath.isEmpty ? nil : resetPath, unit: unit)
    }

    private func adoptVerifiedMapping() {
        guard let fields = store.setupFields, let mapping = definition?.mapping ?? preset?.mapping,
              fields.contains(where: { $0.path == mapping.remainingPath && $0.number != nil }),
              mapping.subtractPath == nil || fields.contains(where: { $0.path == mapping.subtractPath && $0.number != nil }) else { return }
        remainingPath = mapping.remainingPath; subtractPath = mapping.subtractPath ?? ""
        subtractsUsage = mapping.subtractPath != nil; resetPath = mapping.resetPath ?? ""; unit = mapping.unit
    }

    private func savedConnection(_ definition: CustomQuotaDefinition) -> some View {
        let account = store.accounts(now: .now).first { $0.id == definition.id }
        return VStack(alignment: .leading, spacing: 12) {
            Text(account?.displayValue ?? "—").font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text(account?.timing ?? "未提供重置时间").foregroundStyle(QuotaOverviewPalette.secondary)
            if let reason = account?.unavailableReason { Text(reason).foregroundStyle(.orange) }
            LabeledContent("来源", value: URL(string: definition.endpoint)?.host ?? definition.endpoint)
            Text("每 30 秒自动读取；退出、重启和普通更新保留连接。不调用模型，不发送聊天。")
                .foregroundStyle(QuotaOverviewPalette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("刷新额度") { store.refreshDue(force: true) }.disabled(store.isRefreshing)
                if definition.auth != .none {
                    Button("更换 Key") { store.cancelSetup(); editingKey = true; focused = .key }
                }
                Button("断开连接", role: .destructive) { confirmsDisconnect = true }
            }.buttonStyle(.bordered).controlSize(.large)
        }
    }
    private func verify() {
        inputError = nil
        store.verify(name: name, endpoint: endpoint, auth: auth,
                     key: auth == .none ? nil : key.trimmingCharacters(in: .whitespacesAndNewlines), replacingID: definition?.id)
    }
    private func pasteKey() {
        let pasted = (NSPasteboard.general.string(forType: .string) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pasted.isEmpty, pasted.utf8.count <= 8192,
              pasted.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            inputError = "剪贴板里没有有效的 API Key。请先复制平台生成的完整 Key。"; return
        }
        key = pasted; inputError = nil; focused = .key
    }
}
