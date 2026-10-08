import Foundation
import Combine

/// Owns only an explicitly established Cursor login and its two quota RPCs.
/// Snapshots stay in memory; the owned token pair uses a dedicated Keychain item.
@MainActor final class CursorQuotaAccountStore: ObservableObject {
    struct State {
        var snapshot: DesktopQuotaSnapshot?
        var error: String?
    }
    @Published private(set) var enabled: Bool
    @Published private(set) var states: [DesktopQuotaProvider: State] = [:]
    @Published private(set) var loginURL: URL?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var loginError: String?
    @Published private(set) var needsAuthorization = false
    @Published private(set) var keychainBlocked = false
    @Published private(set) var readingProviders: Set<DesktopQuotaProvider> = []
    var isRefreshing: Bool { !readingProviders.isEmpty }
    let allowsConnections: Bool
    private let defaults: UserDefaults
    private let vault: any QuotaCredentialStoring
    private let transport: @Sendable (URLRequest) async throws -> QuotaHTTPResponse
    private let clock: () -> Date
    private var credentials: CursorQuotaTokenPair?
    private var loginTask: Task<Void, Never>?
    private var tasks: [DesktopQuotaProvider: Task<Void, Never>] = [:]
    private var rotation: Task<CursorQuotaTokenPair, Error>?
    private var generation = 0
    private var loginGeneration = 0
    private var due: [DesktopQuotaProvider: Date] = [:]
    private var failures: [DesktopQuotaProvider: Int] = [:]
    private var retryUntil: [DesktopQuotaProvider: Date] = [:]
    private var loginRetryUntil = Date.distantPast
    private var rotationRetryUntil = Date.distantPast
    private static let enabledKey = "quota.cursor-account.enabled.v1"
    private static let providers: [DesktopQuotaProvider] = [.cursor, .grok]

    init(defaults: UserDefaults, vault: any QuotaCredentialStoring, allowsConnections: Bool,
         transport: @escaping @Sendable (URLRequest) async throws -> QuotaHTTPResponse,
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.vault = vault; self.transport = transport; self.clock = clock
        self.allowsConnections = allowsConnections
        enabled = allowsConnections && defaults.bool(forKey: Self.enabledKey)
    }

    /// The button explains both products, the destination and secure retention.
    /// No timer can invoke this method or open a login page.
    func beginLogin() {
        guard allowsConnections, !isLoggingIn else {
            if !allowsConnections { loginError = QuotaConnectionError.preview.localizedDescription }
            return
        }
        guard clock() >= loginRetryUntil else {
            loginError = "官网暂时限制登录请求，请 \(Int(ceil(loginRetryUntil.timeIntervalSince(clock())))) 秒后重试。现有连接不会被替换。"
            return
        }
        let attempt = CursorQuotaLoginAttempt(at: clock())
        loginGeneration += 1
        let revision = loginGeneration
        isLoggingIn = true; loginError = nil; loginURL = attempt.loginURL
        loginTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == loginGeneration { isLoggingIn = false; loginTask = nil }
            }
            do {
                var pair: CursorQuotaTokenPair?
                for _ in 0..<120 {
                    guard !Task.isCancelled, revision == loginGeneration else { return }
                    guard clock() < attempt.deadline else { throw QuotaConnectionError.authentication }
                    let response = try await transport(CursorQuotaRequest.poll(attempt))
                    guard !Task.isCancelled, revision == loginGeneration else { return }
                    if response.status == 404 {
                        try await Task.sleep(for: .seconds(5)); continue
                    }
                    if [429, 503].contains(response.status) {
                        loginRetryUntil = clock().addingTimeInterval(max(30, response.retryAfter ?? 60))
                    }
                    try validate(response)
                    pair = try CursorQuotaTokenPair.decodeLogin(response.data)
                    break
                }
                guard let pair else { throw QuotaConnectionError.authentication }
                var verified: [DesktopQuotaProvider: State] = [:]
                // Both calls are read-only. Keep a format/unavailable failure separate
                // rather than filling it with the other product's valid value.
                for provider in Self.providers {
                    do {
                        let response = try await transport(CursorQuotaRequest.usage(provider, accessToken: pair.accessToken))
                        try validate(response)
                        verified[provider] = State(snapshot: try CursorQuotaParser.parse(provider, data: response.data, at: clock()))
                    } catch {
                        if case QuotaConnectionError.authentication = error { throw error }
                        verified[provider] = State(error: Self.message(error))
                    }
                    guard !Task.isCancelled, revision == loginGeneration else { return }
                }
                guard verified.values.contains(where: { $0.snapshot != nil }) else { throw QuotaConnectionError.invalidData }
                try vault.save(pair.serialized)
                guard revision == loginGeneration, !Task.isCancelled else { return }
                cancelReads()
                credentials = pair; states = verified; enabled = true
                needsAuthorization = false; keychainBlocked = false; loginError = nil; loginURL = nil
                defaults.set(true, forKey: Self.enabledKey)
                for provider in Self.providers { due[provider] = clock().addingTimeInterval(30) }
            } catch {
                guard !Task.isCancelled, revision == loginGeneration else { return }
                loginError = Self.message(error); loginURL = nil
                // A rejected replacement never discards a previously working login.
            }
        }
    }
    func cancelLogin() {
        loginGeneration += 1; loginTask?.cancel(); loginTask = nil
        isLoggingIn = false; loginURL = nil
    }
    func refreshDue(force: Bool = false) {
        guard allowsConnections, enabled, !needsAuthorization, clock() >= rotationRetryUntil else { return }
        for provider in Self.providers where tasks[provider] == nil && clock() >= (retryUntil[provider] ?? .distantPast)
            && (force || clock() >= (due[provider] ?? .distantPast)) {
            refresh(provider)
        }
    }
    private func refresh(_ provider: DesktopQuotaProvider) {
        let revision = generation
        readingProviders.insert(provider)
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == generation { tasks[provider] = nil; readingProviders.remove(provider) }
            }
            guard revision == generation, !Task.isCancelled, !needsAuthorization else { return }
            do {
                let pair = try await credentialsForRead()
                guard revision == generation, !Task.isCancelled else { return }
                var response = try await transport(CursorQuotaRequest.usage(provider, accessToken: pair.accessToken))
                guard revision == generation, !Task.isCancelled else { return }
                if [401, 403].contains(response.status) {
                    // At most one shared owned-token rotation, then one retry.
                    let renewed = try await rotate(pair)
                    guard revision == generation, !Task.isCancelled else { return }
                    response = try await transport(CursorQuotaRequest.usage(provider, accessToken: renewed.accessToken))
                }
                guard revision == generation, !Task.isCancelled else { return }
                if [429, 503].contains(response.status), let retry = response.retryAfter {
                    retryUntil[provider] = clock().addingTimeInterval(retry)
                }
                try validate(response)
                states[provider] = State(snapshot: try CursorQuotaParser.parse(provider, data: response.data, at: clock()))
                failures[provider] = 0; due[provider] = clock().addingTimeInterval(30)
            } catch {
                guard revision == generation, !Task.isCancelled else { return }
                states[provider, default: State()].error = Self.message(error)
                failures[provider, default: 0] += 1
                let delay = min(3600, 30 * pow(2, Double(min(failures[provider, default: 1] - 1, 7))))
                due[provider] = clock().addingTimeInterval(delay)
                if case QuotaConnectionError.rateLimited = error {
                    retryUntil[provider] = max(retryUntil[provider] ?? .distantPast, due[provider]!)
                }
                if case QuotaConnectionError.authentication = error { pauseAuthorization(keychain: false) }
                if case QuotaConnectionError.keychain = error { pauseAuthorization(keychain: true) }
            }
        }
    }
    private func credentialsForRead() async throws -> CursorQuotaTokenPair {
        let pair: CursorQuotaTokenPair
        if let credentials { pair = credentials }
        else {
            guard let saved = try vault.read() else { throw QuotaConnectionError.authentication }
            pair = try CursorQuotaTokenPair.decodeLogin(Data(saved.utf8)); credentials = pair
        }
        if let expiry = pair.expiresAt, expiry <= clock().addingTimeInterval(60) { return try await rotate(pair) }
        return pair
    }
    private func rotate(_ previous: CursorQuotaTokenPair) async throws -> CursorQuotaTokenPair {
        if let current = credentials, current.accessToken != previous.accessToken { return current }
        if let rotation { return try await rotation.value }
        guard clock() >= rotationRetryUntil else { throw QuotaConnectionError.rateLimited }
        let revision = generation
        let task = Task { @MainActor [weak self] () throws -> CursorQuotaTokenPair in
            guard let self else { throw CancellationError() }
            let response = try await transport(CursorQuotaRequest.refresh(previous))
            guard revision == generation, !Task.isCancelled else { throw CancellationError() }
            if [429, 503].contains(response.status) {
                rotationRetryUntil = clock().addingTimeInterval(max(30, response.retryAfter ?? 60))
            }
            try validate(response)
            struct Refreshed: Decodable { let access_token: String?; let refresh_token: String?; let shouldLogout: Bool? }
            guard let value = try? JSONDecoder().decode(Refreshed.self, from: response.data), value.shouldLogout != true,
                  let access = value.access_token else { throw QuotaConnectionError.authentication }
            let pair = try CursorQuotaTokenPair(accessToken: access, refreshToken: value.refresh_token ?? previous.refreshToken).validated()
            // Rotation is a background action: secure save must also suppress UI.
            try vault.saveForRefresh(pair.serialized)
            credentials = pair
            return pair
        }
        rotation = task
        defer { if revision == generation { rotation = nil } }
        return try await task.value
    }
    func authorizeSavedSession() {
        guard allowsConnections, enabled, keychainBlocked, !isRefreshing else { return }
        do {
            guard let saved = try vault.readForAuthorization() else { throw QuotaConnectionError.authentication }
            credentials = try CursorQuotaTokenPair.decodeLogin(Data(saved.utf8))
            needsAuthorization = false; keychainBlocked = false; loginError = nil
            refreshDue(force: true)
        } catch { loginError = Self.message(error) }
    }
    private func pauseAuthorization(keychain: Bool) {
        cancelReads()
        needsAuthorization = true; keychainBlocked = keychain; credentials = nil
        if !keychain { for provider in Self.providers { states[provider] = State(error: "官方登录已失效，请重新连接") } }
    }
    func disconnect() {
        stop(); enabled = false; states = [:]; needsAuthorization = false; keychainBlocked = false; loginError = nil
        guard allowsConnections else { return }
        defaults.set(false, forKey: Self.enabledKey)
        do { try vault.delete() } catch { loginError = "已停止同步；本机登录凭证未能移除，请重试断开。" }
    }
    func stop() {
        cancelLogin(); cancelReads(); credentials = nil; due = [:]; retryUntil = [:]
    }
    private func cancelReads() {
        generation += 1
        for task in tasks.values { task.cancel() }; tasks = [:]; readingProviders = []
        rotation?.cancel(); rotation = nil
    }
    private func validate(_ response: QuotaHTTPResponse) throws {
        switch response.status {
        case 200: return
        case 401, 403: throw QuotaConnectionError.authentication
        case 429: throw QuotaConnectionError.rateLimited
        default: throw QuotaConnectionError.unavailable
        }
    }
    private static func message(_ error: Error) -> String {
        if case QuotaConnectionError.authentication = error { return "官方登录已失效或尚未完成，请重新登录连接" }
        return (error as? QuotaConnectionError ?? .unavailable).localizedDescription
    }
    func account(_ provider: DesktopQuotaProvider, now: Date) -> QuotaOverviewAccount {
        let state = states[provider]
        guard let snapshot = state?.snapshot, let primary = snapshot.pools.first else {
            let restoring = enabled && !keychainBlocked && !needsAuthorization && !isLoggingIn &&
                state?.error == nil && loginError == nil
            return .init(id: provider.rawValue, name: provider.name, account: "Cursor 账号 · 桌面会员", group: .membership,
                value: .unknown, timing: restoring ? "正在自动恢复" :
                    (keychainBlocked ? "需要主动授权" : (enabled ? "点击处理连接" : "登录后自动同步")),
                status: enabled ? .unavailable : .notConnected,
                explanation: "通过自己的官方登录查询，不依赖原应用额度页面。Cursor 月额度与 Grok Bot 周额度分别读取。",
                unavailableReason: !allowsConnections ? "隔离验证不读取账户" :
                    (restoring ? "正在恢复已保存的连接并核验额度" :
                        (keychainBlocked ? "本机凭证读取已暂停，不会弹密码" : (state?.error ?? loginError ?? "需要在此完成一次官方登录"))))
        }
        let age = now.timeIntervalSince(snapshot.observedAt)
        let expired = snapshot.resetsAt.map { $0 <= now } ?? false
        let fresh = state?.error == nil && !needsAuthorization && (-60...90).contains(age) && !expired
        let reset = snapshot.resetsAt.map { date -> String in
            let seconds = date.timeIntervalSince(now)
            if seconds <= 0 { return "等待重置后更新" }
            if seconds < 86_400 { return "不足 1 天后重置" }
            return "\(Int(ceil(seconds / 86_400))) 天后重置"
        } ?? "官方未提供重置时间"
        var details = [QuotaOverviewDetail(label: "数据来源", value: snapshot.sourceName ?? "Cursor 官方账号"),
            .init(label: "最近读取", value: snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))]
        details += snapshot.pools.map { .init(label: "\($0.name)剩余", value: "\($0.remaining)%") }
        details.append(.init(label: "重置时间", value: snapshot.resetsAt?.formatted(date: .abbreviated, time: .standard) ?? "官方未提供"))
        return .init(id: provider.rawValue, name: provider.name, account: "会员 · \(primary.name)", group: .membership,
            value: .percent(primary.remaining), timing: reset, status: fresh ? .current : .stale, details: details,
            explanation: "官方账号只读查询，每 30 秒更新；关闭登录页或原应用额度页后仍会查询。厂商计费更新可能延迟；月额度和周额度不混用。",
            unavailableReason: fresh ? nil : (state?.error ?? (keychainBlocked ? "凭证读取已暂停" : "数据已过期，等待新的官方查询")),
            pools: snapshot.pools.map {
                .init(label: $0.name == "Cursor Models" ? "Cursor" : $0.name == "Other Models" ? "其他模型" : $0.name,
                      value: .percent($0.remaining), timing: reset)
            })
    }
}
