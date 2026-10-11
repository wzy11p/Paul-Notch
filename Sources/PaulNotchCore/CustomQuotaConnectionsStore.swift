import Foundation
import Combine

@MainActor protocol CustomQuotaRegistryStoring {
    func load() throws -> [CustomQuotaDefinition]
    func save(_ definitions: [CustomQuotaDefinition]) throws
}

@MainActor struct CustomQuotaDefaultsRegistry: CustomQuotaRegistryStoring {
    static let key = "quota.custom-api.registry.v1"
    let defaults: UserDefaults
    func load() throws -> [CustomQuotaDefinition] {
        guard let value = defaults.data(forKey: Self.key) else { return [] }
        return try CustomQuotaRegistry.decode(value)
    }
    func save(_ definitions: [CustomQuotaDefinition]) throws {
        let value = try CustomQuotaRegistry.encode(definitions)
        defaults.set(value, forKey: Self.key)
        guard defaults.data(forKey: Self.key) == value else { throw CustomQuotaIssue.storage }
    }
}

@MainActor final class CustomQuotaConnectionsStore: ObservableObject, CustomQuotaProviding {
    @Published private(set) var definitions: [CustomQuotaDefinition] = []
    @Published private(set) var setupFields: [CustomQuotaField]? = nil
    @Published private(set) var setupError: String?
    @Published private(set) var isVerifying = false
    @Published private(set) var registryError: String?
    @Published private var states: [String: State] = [:]
    let allowsConnections: Bool
    var changes: ObservableObjectPublisher { objectWillChange }
    var isRefreshing: Bool { !tasks.isEmpty }
    private struct State {
        var snapshot: CustomQuotaSnapshot?
        var error: String?
        var due = Date.distantPast
        var failures = 0
        var paused = false
    }
    private struct Candidate {
        let definition: CustomQuotaDefinition
        let key: String?
        let payload: CustomQuotaPayload
        let observedAt: Date
        let replacing: Bool
    }
    private let registry: any CustomQuotaRegistryStoring
    private let vault: (String) -> any QuotaCredentialStoring
    private let transport: @Sendable (URLRequest) async throws -> QuotaHTTPResponse
    private let clock: () -> Date
    private var candidate: Candidate?
    private var setupTask: Task<Void, Never>?
    private var setupRevision = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var revisions: [String: Int] = [:]
    private var sessionKeys: [String: String] = [:]
    private var forcedIDs: Set<String> = []
    init(registry: any CustomQuotaRegistryStoring, allowsConnections: Bool,
         vault: @escaping (String) -> any QuotaCredentialStoring,
         transport: @escaping @Sendable (URLRequest) async throws -> QuotaHTTPResponse,
         clock: @escaping () -> Date = Date.init) {
        self.allowsConnections = allowsConnections; self.registry = registry
        self.vault = vault; self.transport = transport; self.clock = clock
        do { definitions = try registry.load() }
        catch { registryError = CustomQuotaIssue.registry.localizedDescription }
    }
    func verify(name: String, endpoint: String, auth: CustomQuotaAuth, key: String?, replacingID: String? = nil) {
        guard allowsConnections else { setupError = QuotaConnectionError.preview.localizedDescription; return }
        guard !isVerifying, registryError == nil else { return }
        guard replacingID != nil || definitions.count < 32 else { setupError = CustomQuotaIssue.limit.localizedDescription; return }
        cancelSetup()
        let existing = replacingID.flatMap { id in definitions.first { $0.id == id } }
        do {
            guard replacingID == nil || existing != nil else { throw CustomQuotaIssue.registry }
            let url = try CustomQuotaEndpoint.prepare(endpoint)
            // A reconnect changes only its credential. Moving a Key to another
            // host or changing its field contract requires a new deliberate setup.
            if let existing, existing.endpoint != url.absoluteString || existing.auth != auth || existing.name != name {
                throw CustomQuotaIssue.endpoint
            }
            let definition = CustomQuotaDefinition(id: existing?.id ?? "custom-" + UUID().uuidString.lowercased(),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), endpoint: url.absoluteString,
                auth: auth, mapping: existing?.mapping ?? .init(remainingPath: "/unselected", unit: .cny))
            try definition.validate()
            let request = try CustomQuotaEndpoint.request(endpoint: definition.endpoint, auth: auth, key: key)
            let revision = setupRevision
            isVerifying = true
            setupTask = Task { [weak self] in
                guard let self else { return }
                defer { if revision == setupRevision { setupTask = nil; isVerifying = false } }
                do {
                    let response = try await transport(request)
                    guard revision == setupRevision, !Task.isCancelled else { return }
                    try Self.validateStatus(response.status)
                    let payload = try CustomQuotaPayload.decode(response.data)
                    candidate = .init(definition: definition, key: auth == .none ? nil : key, payload: payload,
                                      observedAt: clock(), replacing: existing != nil)
                    setupFields = payload.fields; setupError = nil
                } catch {
                    guard revision == setupRevision, !Task.isCancelled else { return }
                    candidate = nil; setupFields = nil; setupError = Self.message(error)
                }
            }
        } catch { setupError = Self.message(error) }
    }
    func preview(mapping: CustomQuotaMapping) -> CustomQuotaSnapshot? {
        guard let candidate else { return nil }
        return try? candidate.payload.snapshot(mapping: mapping, at: candidate.observedAt)
    }
    func commit(mapping: CustomQuotaMapping) -> String? {
        guard allowsConnections, registryError == nil, let candidate else { return nil }
        let definition = CustomQuotaDefinition(id: candidate.definition.id, name: candidate.definition.name,
            endpoint: candidate.definition.endpoint, auth: candidate.definition.auth, mapping: mapping)
        do {
            guard (-60...90).contains(clock().timeIntervalSince(candidate.observedAt)) else { throw CustomQuotaIssue.expired }
            guard !candidate.replacing || definition == candidate.definition else { throw CustomQuotaIssue.mapping }
            try definition.validate()
            let snapshot = try candidate.payload.snapshot(mapping: mapping, at: candidate.observedAt)
            if let key = candidate.key {
                let previousKey = candidate.replacing ? try vault(definition.id).read() : nil
                do { try vault(definition.id).save(key) }
                catch {
                    // A new save can have succeeded before its cold verification
                    // failed. Never leave an unregistered fresh account key.
                    if let previousKey { try? vault(definition.id).save(previousKey) }
                    else if !candidate.replacing { try? vault(definition.id).delete() }
                    throw error
                }
            }
            if !candidate.replacing {
                do { try registry.save(definitions + [definition]) }
                catch {
                    if candidate.key != nil { try? vault(definition.id).delete() }
                    throw error
                }
                definitions.append(definition)
            }
            revisions[definition.id, default: 0] += 1
            tasks.removeValue(forKey: definition.id)?.cancel()
            sessionKeys[definition.id] = candidate.key
            states[definition.id] = .init(snapshot: snapshot, due: clock().addingTimeInterval(30))
            cancelSetup()
            return definition.id
        } catch { setupError = Self.message(error); return nil }
    }
    func cancelSetup() {
        setupRevision += 1; setupTask?.cancel(); setupTask = nil
        candidate = nil; setupFields = nil; setupError = nil; isVerifying = false
    }
    func disconnect(_ id: String) -> Bool {
        guard allowsConnections, let definition = definitions.first(where: { $0.id == id }) else { return false }
        do {
            // If metadata cannot be written, retain both the connection and Key.
            try registry.save(definitions.filter { $0.id != id })
            if definition.auth != .none {
                do { try vault(id).delete() }
                catch {
                    // Retain a usable connection when a locked Keychain denies
                    // deletion. Do not make every other custom account unusable.
                    do { try registry.save(definitions) }
                    catch { registryError = CustomQuotaIssue.registry.localizedDescription }
                    throw QuotaConnectionError.keychain
                }
            }
            revisions[id, default: 0] += 1; tasks.removeValue(forKey: id)?.cancel()
            definitions.removeAll { $0.id == id }; states[id] = nil; sessionKeys[id] = nil
            forcedIDs.remove(id); setupError = nil
            return true
        } catch { setupError = Self.message(error); return false }
    }
    func refreshDue(force: Bool = false) {
        guard allowsConnections, registryError == nil else { return }
        if force { forcedIDs.formUnion(definitions.map(\.id)) }
        if let candidate, clock().timeIntervalSince(candidate.observedAt) > 600 { cancelSetup() }
        // The existing parent timer dispatches reads. At most two custom HTTP
        // reads run concurrently, irrespective of account count.
        for definition in definitions where tasks.count < 2 {
            let state = states[definition.id] ?? State()
            guard tasks[definition.id] == nil, !state.paused,
                  forcedIDs.contains(definition.id) || clock() >= state.due,
                  state.failures == 0 || clock() >= state.due else { continue }
            forcedIDs.remove(definition.id)
            query(definition)
        }
    }
    func stop() {
        cancelSetup()
        for id in tasks.keys { revisions[id, default: 0] += 1 }
        tasks.values.forEach { $0.cancel() }; tasks.removeAll(); sessionKeys.removeAll(); forcedIDs.removeAll()
    }
    private func query(_ definition: CustomQuotaDefinition) {
        let revision = revisions[definition.id, default: 0]
        objectWillChange.send()
        tasks[definition.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == revisions[definition.id, default: 0] {
                    objectWillChange.send(); tasks[definition.id] = nil
                    refreshDue()
                }
            }
            var providerBackoff: TimeInterval?
            do {
                let key: String?
                if definition.auth == .none { key = nil }
                else {
                    guard let saved = try sessionKeys[definition.id] ?? vault(definition.id).read() else { throw QuotaConnectionError.authentication }
                    key = saved; sessionKeys[definition.id] = saved
                }
                let response = try await transport(CustomQuotaEndpoint.request(endpoint: definition.endpoint, auth: definition.auth, key: key))
                guard revision == revisions[definition.id, default: 0], definitions.contains(definition), !Task.isCancelled else { return }
                providerBackoff = response.retryAfter
                try Self.validateStatus(response.status)
                let snapshot = try CustomQuotaPayload.decode(response.data).snapshot(mapping: definition.mapping, at: clock())
                states[definition.id] = .init(snapshot: snapshot, due: clock().addingTimeInterval(30))
            } catch {
                guard revision == revisions[definition.id, default: 0], definitions.contains(definition), !Task.isCancelled else { return }
                var state = states[definition.id] ?? State()
                state.error = Self.message(error); state.failures += 1
                let localBackoff = min(600, 30 * pow(2, Double(min(state.failures - 1, 5))))
                let serverBackoff = providerBackoff.flatMap { $0.isFinite && $0 > 0 ? min($0, 31_536_000) : nil } ?? 0
                state.due = clock().addingTimeInterval(max(localBackoff, serverBackoff))
                if case QuotaConnectionError.authentication = error { state.paused = true; sessionKeys[definition.id] = nil }
                if case QuotaConnectionError.keychain = error { state.paused = true; sessionKeys[definition.id] = nil }
                states[definition.id] = state
            }
        }
    }
    func accounts(now: Date) -> [QuotaOverviewAccount] {
        definitions.map { definition in
            let state = states[definition.id] ?? State()
            let snapshot = state.snapshot
            let age = snapshot.map { now.timeIntervalSince($0.observedAt) }
            let fresh = state.error == nil && age.map { $0 >= -60 && $0 <= 90 } == true
                && snapshot?.resetsAt.map { $0 > now } != false
            let reason = fresh ? nil : state.error ?? "等待接口返回当前额度"
            return .init(id: definition.id, name: definition.name, account: "自定义 API · \(URL(string: definition.endpoint)?.host ?? "")",
                group: .usage, value: snapshot.map(Self.value) ?? .unknown,
                timing: snapshot?.resetsAt.map { Self.timing($0, now: now) } ?? "未提供重置时间",
                status: fresh ? .current : snapshot == nil ? .unavailable : .stale,
                details: [.init(label: "数据来源", value: definition.endpoint),
                          .init(label: "余额字段", value: definition.mapping.remainingPath),
                          .init(label: "单位", value: definition.mapping.unit.title),
                          .init(label: "最近读取", value: snapshot?.observedAt.formatted(date: .abbreviated, time: .shortened) ?? "尚未读取")],
                explanation: "使用你确认的只读额度接口，每 30 秒自动查询。只显示选定字段的真实值，不发送聊天、不调用模型。重置时间仅使用接口提供的字段；网址或 API Key 不等于桌面会员接入。",
                unavailableReason: reason)
        }
    }
    static func value(_ snapshot: CustomQuotaSnapshot) -> QuotaOverviewValue {
        switch snapshot.unit {
        case .cny: .money(snapshot.amount, currency: "CNY")
        case .usd: .money(snapshot.amount, currency: "USD")
        case .percent, .ratio: .percent(NSDecimalNumber(decimal: snapshot.amount).intValue)
        case .credits: .credits(NSDecimalNumber(decimal: snapshot.amount).intValue, unit: "积分")
        case .tokens: .credits(NSDecimalNumber(decimal: snapshot.amount).intValue, unit: "Token")
        }
    }
    private static func timing(_ reset: Date, now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        if seconds <= 0 { return "等待确认重置" }
        if seconds >= 86400 { return "\(Int(ceil(seconds / 86400))) 天后重置" }
        if seconds >= 3600 { return "\(Int(ceil(seconds / 3600))) 小时后重置" }
        return "\(max(1, Int(ceil(seconds / 60)))) 分钟后重置"
    }
    private static func validateStatus(_ status: Int) throws {
        if [401, 403].contains(status) { throw QuotaConnectionError.authentication }
        if status == 429 { throw QuotaConnectionError.rateLimited }
        guard status == 200 else { throw QuotaConnectionError.unavailable }
    }
    private static func message(_ error: Error) -> String {
        if let error = error as? CustomQuotaIssue { return error.localizedDescription }
        return (error as? QuotaConnectionError ?? .unavailable).localizedDescription
    }
}
