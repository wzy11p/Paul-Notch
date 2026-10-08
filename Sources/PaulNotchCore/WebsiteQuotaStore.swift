import Foundation
import Combine

@MainActor protocol WebsiteQuotaSession: AnyObject {
    func read(reloading: Bool) async throws -> WebsiteQuotaSnapshot
    func stop()
}

/// One owned session per membership. Only nonsecret, versioned profile IDs are
/// stored here; WebKit owns the login data in its private application profiles.
@MainActor final class WebsiteQuotaStore: ObservableObject {
    @Published private(set) var provider: WebsiteQuotaProvider
    @Published private(set) var snapshot: WebsiteQuotaSnapshot?
    @Published private(set) var enabled = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isPresentingLogin = false
    @Published private(set) var needsLogin = false
    @Published private(set) var error: String?
    @Published private(set) var loginError: String?
    @Published private(set) var candidateBrowser: WebsiteQuotaBrowser?
    /// Viewing the established source must not allocate a replacement login.
    var connectedBrowser: WebsiteQuotaBrowser? { enabled && !needsLogin ? session as? WebsiteQuotaBrowser : nil }
    let allowsConnections: Bool
    let remembersLogin: Bool
    private let factory: (WebsiteQuotaProvider) -> any WebsiteQuotaSession
    private let persistentFactory: ((WebsiteQuotaProvider, UUID) -> any WebsiteQuotaSession)?
    private let defaults: UserDefaults?
    private let removeProfile: (UUID) async -> Bool
    private let persistenceKey: String
    private var loginState = WebsiteQuotaLoginState()
    private var profileID: UUID?
    private var candidateID: UUID?
    private var cleanupTask: Task<Void, Never>?
    private var cleanupRevision = 0
    private let clock: () -> Date
    private var session: (any WebsiteQuotaSession)?
    private var candidate: (any WebsiteQuotaSession)?
    private var candidateProvider: WebsiteQuotaProvider?
    private var loginDeadline: Date?
    private var task: Task<Void, Never>?
    private var revision = 0
    private var nextAttempt = Date.distantPast
    private var failures = 0

    init(provider: WebsiteQuotaProvider, allowsConnections: Bool,
         factory: @escaping (WebsiteQuotaProvider) -> any WebsiteQuotaSession,
         defaults: UserDefaults? = nil,
         persistentFactory: ((WebsiteQuotaProvider, UUID) -> any WebsiteQuotaSession)? = nil,
         removeProfile: @escaping (UUID) async -> Bool = { _ in true },
         clock: @escaping () -> Date = Date.init) {
        self.provider = provider; self.allowsConnections = allowsConnections
        self.factory = factory; self.clock = clock
        self.defaults = defaults; self.persistentFactory = persistentFactory; self.removeProfile = removeProfile
        persistenceKey = "quota.website.\(provider.accountID).login.v1"
        remembersLogin = allowsConnections && defaults != nil && persistentFactory != nil
        guard remembersLogin, let data = defaults?.data(forKey: persistenceKey) else { return }
        guard data.count <= 2048, let saved = try? JSONDecoder().decode(WebsiteQuotaLoginState.self, from: data),
              saved.isValid(for: provider.accountID) else {
            error = "本机连接记录无法读取，请重新连接；没有读取其他应用的登录。"
            return
        }
        loginState = saved
        if let active = saved.active {
            self.provider = active.provider; profileID = active.identifier; enabled = true
        }
    }
    func beginLogin(provider selected: WebsiteQuotaProvider? = nil) {
        guard allowsConnections, !isRefreshing, !isPresentingLogin else { return }
        let selected = selected ?? provider
        guard selected.accountID == provider.accountID else { return }
        if remembersLogin {
            cleanupProfiles()
            guard loginState.discarded.count < 8 else {
                loginError = "旧登录缓存暂未清理完成，请稍后重试；已有连接保留。"; return
            }
            let id = loginState.pending?.identifier ?? UUID()
            // Journal before creating the owned container. A crash during a
            // candidate login cleans that container on the next start.
            if loginState.pending == nil { loginState.discarded.append(id) }
            persistLoginState(); candidateID = id
            candidate = persistentFactory?(selected, id)
        } else { candidate = factory(selected) }
        candidateProvider = selected
        candidateBrowser = candidate as? WebsiteQuotaBrowser
        loginDeadline = loginState.pending == nil ? clock().addingTimeInterval(600) : nil
        loginError = nil; isPresentingLogin = true
    }
    func finishLogin() {
        guard allowsConnections, isPresentingLogin, !isRefreshing,
              let candidate, let candidateProvider else { return }
        if remembersLogin, candidateProvider == .muse, !enabled, let candidateID {
            // The owner deliberately says authentication is finished. Keep
            // this owned profile through quota-format/network errors and an
            // ordinary app update, without claiming a verified connection.
            loginState.discarded.removeAll { $0 == candidateID }
            loginState.pending = .init(provider: candidateProvider, identifier: candidateID)
            loginDeadline = nil; persistLoginState()
        }
        readCandidate(candidate, provider: candidateProvider)
    }
    private func readCandidate(_ candidate: any WebsiteQuotaSession, provider candidateProvider: WebsiteQuotaProvider) {
        let capturedRevision = revision
        isRefreshing = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if capturedRevision == revision { task = nil; isRefreshing = false } }
            do {
                let value = try await candidate.read(reloading: false)
                guard !Task.isCancelled, capturedRevision == revision else { return }
                session?.stop(); session = candidate
                if let candidateID {
                    if let profileID { loginState.discarded.append(profileID) }
                    loginState.discarded.removeAll { $0 == candidateID }
                    loginState.active = .init(provider: candidateProvider, identifier: candidateID)
                    loginState.pending = nil
                    profileID = candidateID; self.candidateID = nil
                    persistLoginState()
                }
                self.candidate = nil; candidateBrowser = nil; self.candidateProvider = nil
                loginDeadline = nil
                provider = candidateProvider; snapshot = value; enabled = true
                isPresentingLogin = false; needsLogin = false; error = nil; failures = 0
                loginError = nil
                nextAttempt = clock().addingTimeInterval(30)
                cleanupProfiles()
            } catch {
                guard !Task.isCancelled, capturedRevision == revision else { return }
                failures += 1
                nextAttempt = clock().addingTimeInterval(min(3600, 30 * pow(2, Double(min(failures - 1, 7)))))
                let message = candidateProvider == .muse
                    ? "Muse 额度暂未读取成功；本次登录已保留，可重试读取，无需重复输入账号。"
                    : "尚未读到个人额度。请在官方页面完成登录，确认额度页已加载后重试。旧连接不会被替换。"
                if isPresentingLogin { loginError = message }
                else { self.error = message }
                if !enabled, case QuotaConnectionError.authentication = error {
                    needsLogin = true
                    let expired = "官方页面仍要求登录或登录已失效；请完成官方登录后重试。"
                    if isPresentingLogin { loginError = expired } else { self.error = expired }
                }
            }
        }
    }
    func cancelLogin() {
        guard isPresentingLogin else { return }
        revision += 1; task?.cancel(); task = nil; isRefreshing = false
        if let pending = loginState.pending {
            loginState.discarded.append(pending.identifier); loginState.pending = nil; persistLoginState()
        }
        candidate?.stop(); candidate = nil; candidateBrowser = nil; candidateProvider = nil
        candidateID = nil; cleanupProfiles()
        loginDeadline = nil; isPresentingLogin = false
    }
    func refreshDue(force: Bool = false) {
        cleanupProfiles()
        if isPresentingLogin, let loginDeadline, clock() >= loginDeadline {
            cancelLogin()
            loginError = "本次登录已超时，请重新连接。未完成的登录页面已关闭；已有连接不受影响。"
        }
        if allowsConnections, !enabled, !needsLogin, !isRefreshing,
           force || clock() >= nextAttempt, let pending = loginState.pending {
            if candidate == nil {
                candidateID = pending.identifier; candidateProvider = pending.provider
                candidate = persistentFactory?(pending.provider, pending.identifier)
            }
            if let candidate { readCandidate(candidate, provider: pending.provider) }
            return
        }
        guard allowsConnections, enabled, !needsLogin, !isPresentingLogin, !isRefreshing,
              force || clock() >= nextAttempt else { return }
        // Cold start (or stop/start) restores the verified owned profile lazily,
        // without opening the setup UI or treating yesterday's value as current.
        let restoring = session == nil
        if restoring, let profileID { session = persistentFactory?(provider, profileID) }
        guard let session else { return }
        let capturedRevision = revision
        isRefreshing = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if capturedRevision == revision { task = nil; isRefreshing = false } }
            do {
                let value = try await session.read(reloading: !restoring)
                guard !Task.isCancelled, capturedRevision == revision else { return }
                snapshot = value; error = nil; failures = 0; nextAttempt = clock().addingTimeInterval(30)
            } catch {
                guard !Task.isCancelled, capturedRevision == revision else { return }
                self.error = (error as? QuotaConnectionError ?? .unavailable).localizedDescription
                failures += 1
                nextAttempt = clock().addingTimeInterval(min(3600, 30 * pow(2, Double(min(failures - 1, 7)))))
                if case QuotaConnectionError.authentication = error {
                    needsLogin = true; session.stop(); self.session = nil
                    self.error = "官方登录已失效；请主动重新连接。不会弹密码或自动打开窗口。"
                }
            }
        }
    }
    func stop() {
        revision += 1; task?.cancel(); task = nil; isRefreshing = false
        candidate?.stop(); session?.stop(); candidate = nil; session = nil; candidateBrowser = nil
        candidateProvider = nil; candidateID = nil; loginDeadline = nil; snapshot = nil
        enabled = loginState.active != nil; needsLogin = false; nextAttempt = .distantPast
        cleanupRevision += 1; cleanupTask?.cancel(); cleanupTask = nil
        isPresentingLogin = false; error = nil; loginError = nil
    }
    /// Disconnect is deliberately distinct from normal application shutdown.
    /// Only this action forgets the established connection and its own profile.
    func disconnect() {
        stop()
        if let profileID { loginState.discarded.append(profileID) }
        if let pending = loginState.pending { loginState.discarded.append(pending.identifier) }
        loginState.pending = nil
        profileID = nil; loginState.active = nil; enabled = false
        persistLoginState(); cleanupProfiles()
    }
    private func persistLoginState() {
        guard remembersLogin, let data = try? JSONEncoder().encode(loginState), data.count <= 2048 else { return }
        defaults?.set(data, forKey: persistenceKey)
    }
    private func cleanupProfiles() {
        guard remembersLogin, cleanupTask == nil else { return }
        let ids = loginState.discarded.filter { $0 != profileID && $0 != candidateID }
        guard !ids.isEmpty else { return }
        let capturedCleanup = cleanupRevision
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            defer { if capturedCleanup == cleanupRevision { cleanupTask = nil } }
            for id in ids {
                guard !Task.isCancelled, id != profileID, id != candidateID else { return }
                let removed = await removeProfile(id)
                guard !Task.isCancelled else { return }
                if removed {
                    loginState.discarded.removeAll { $0 == id }; persistLoginState()
                } else if !enabled {
                    loginError = "已停止同步；本机登录缓存暂未清理完成，请重试断开。"
                }
            }
        }
    }
    func account(now: Date) -> QuotaOverviewAccount {
        let expiredMuseCycle = provider == .muse && snapshot?.resetsAt.map { $0 <= now } == true
        let fresh = snapshot.map { (-60...90).contains(now.timeIntervalSince($0.observedAt)) } == true &&
            error == nil && !needsLogin && !expiredMuseCycle
        var details = snapshot?.details ?? []
        if let snapshot {
            details.append(.init(label: "最近读取", value: snapshot.observedAt.formatted(date: .abbreviated, time: .standard)))
        }
        let source: String
        let account: String
        switch provider {
        case .doubao: source = "豆包官方个人额度页"; account = "会员 · 当前时段"
        case .muse: source = "Muse 官方 General 使用情况"; account = "Meta · 桌面会员"
        default: source = "MiniMax Audio 官方声贝与订阅查询"; account = "配音会员 · 声贝"
        }
        details.append(.init(label: "数据来源", value: source))
        let unavailableReason: String?
        if fresh { unavailableReason = nil }
        else if let error { unavailableReason = error }
        else if expiredMuseCycle { unavailableReason = "等待 Muse 更新本周期额度" }
        else if needsLogin { unavailableReason = "请重新完成官方登录" }
        else { unavailableReason = enabled ? "正在恢复已保存的连接并核验额度" : "请在这里登录你的付费账户" }
        return .init(id: provider.accountID, name: provider.name,
            account: account,
            group: provider.isAudio ? .usage : .membership,
            value: snapshot?.value ?? .unknown, timing: snapshot?.timing ?? "登录后自动同步",
            status: fresh ? .current : (enabled ? .stale : .notConnected), details: details,
            explanation: "\(remembersLogin ? "连接成功后保留本机登录，退出或重启后自动恢复并查询。" : "本机系统暂不支持独立登录保存，退出后需要再次登录。")每 30 秒更新；只有官方登录失效或主动断开才需重连。不导入其他应用的 Cookie、不保存密码，也不将 API 余额当会员额度。",
            usageKind: provider.isAudio ? .audio : .membership,
            unavailableReason: unavailableReason,
            pools: snapshot?.pools ?? [])
    }
}

private struct WebsiteQuotaLoginState: Codable {
    struct Record: Codable {
        let provider: WebsiteQuotaProvider
        let identifier: UUID
    }
    var schemaVersion = 1
    var active: Record?
    /// Deliberately completed first Muse authentication awaiting a valid quota.
    /// Never displayed as a connected balance, and never another app's profile.
    var pending: Record?
    var discarded: [UUID] = []
    func isValid(for accountID: String) -> Bool {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return schemaVersion == 1 && discarded.count <= 8 && Set(discarded).count == discarded.count &&
            !discarded.contains(zero) && (active.map {
                $0.provider.accountID == accountID && $0.identifier != zero && !discarded.contains($0.identifier)
            } ?? true) && (pending.map {
                accountID == "muse" && $0.provider == .muse && active == nil &&
                $0.identifier != zero && !discarded.contains($0.identifier)
            } ?? true)
    }
}
