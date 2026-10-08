import Foundation
import Combine

@MainActor protocol QuotaCredentialStoring {
    func read() throws -> String?
    func readForAuthorization() throws -> String?
    func save(_ value: String) throws
    func saveForRefresh(_ value: String) throws
    func delete() throws
}

extension QuotaCredentialStoring {
    func readForAuthorization() throws -> String? { try read() }
    func saveForRefresh(_ value: String) throws { try save(value) }
}

@MainActor final class QuotaConnectionsStore: ObservableObject {
    @Published private(set) var deepSeekEnabled = false
    @Published private(set) var feedEnabled = false
    @Published private(set) var deepSeekSnapshot: DeepSeekBalance?
    @Published private(set) var deepSeekError: String?
    @Published private(set) var deepSeekNeedsAuthorization = false
    @Published private(set) var deepSeekKeychainBlocked = false
    @Published private(set) var isDeepSeekRefreshing = false
    @Published private(set) var feedSnapshot: QuotaResetFeed?
    @Published private(set) var feedError: String?
    @Published private(set) var feedRetrievedAt: Date?
    @Published private(set) var isFeedRefreshing = false
    @Published private(set) var hasUnreadFeed = false
    let allowsConnections: Bool
    let miniMax: MiniMaxWalletStore?
    let desktop: DesktopQuotaStore?
    let cursorAccount: CursorQuotaAccountStore?
    let websiteMemberships: [String: WebsiteQuotaStore]
    private var miniMaxChanges: AnyCancellable?
    private var desktopChanges: AnyCancellable?
    private var cursorChanges: AnyCancellable?
    private var websiteChanges: [AnyCancellable] = []
    private let defaults: UserDefaults
    private let vault: any QuotaCredentialStoring
    private let transport: @Sendable (URLRequest) async throws -> QuotaHTTPResponse
    private let clock: () -> Date
    private var deepSeekTask: Task<Void, Never>?
    private var deepSeekSessionKey: String?
    private var feedTask: Task<Void, Never>?
    private var timer: Timer?
    private var deepSeekGeneration = 0
    private var feedGeneration = 0
    private var deepSeekNextAttempt = Date.distantPast
    private var feedNextAttempt = Date.distantPast
    private var deepSeekFailures = 0
    private var feedFailures = 0
    private var deepSeekRateLimitedUntil = Date.distantPast
    private var feedRateLimitedUntil = Date.distantPast
    private var feedETag: String?

    init(defaults: UserDefaults, vault: any QuotaCredentialStoring, allowsConnections: Bool,
         transport: @escaping @Sendable (URLRequest) async throws -> QuotaHTTPResponse,
         miniMax: MiniMaxWalletStore? = nil, desktop: DesktopQuotaStore? = nil,
         cursorAccount: CursorQuotaAccountStore? = nil,
         websiteMemberships: [String: WebsiteQuotaStore] = [:],
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.vault = vault
        self.allowsConnections = allowsConnections
        self.transport = transport
        self.clock = clock
        self.miniMax = miniMax
        self.desktop = desktop
        self.cursorAccount = cursorAccount
        self.websiteMemberships = websiteMemberships
        deepSeekEnabled = allowsConnections && defaults.bool(forKey: "quota.deepseek.enabled.v1")
        feedEnabled = allowsConnections && defaults.bool(forKey: "quota.reset-feed.enabled.v1")
        miniMaxChanges = miniMax?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        desktopChanges = desktop?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        cursorChanges = cursorAccount?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        websiteChanges = websiteMemberships.values.map { store in
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    func start() {
        guard allowsConnections, timer == nil else { return }
        refreshDeepSeek()
        refreshFeed()
        miniMax?.refresh()
        desktop?.start()
        cursorAccount?.refreshDue()
        for membership in websiteMemberships.values { membership.refreshDue() }
        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshDeepSeek(); self?.refreshFeed(); self?.miniMax?.refresh(); self?.cursorAccount?.refreshDue()
                if let self { for membership in self.websiteMemberships.values { membership.refreshDue() } }
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func refreshAll() {
        refreshDeepSeek(force: true)
        refreshFeed(force: true)
        miniMax?.refresh(force: true)
        desktop?.refreshDue(force: true)
        cursorAccount?.refreshDue(force: true)
        for membership in websiteMemberships.values { membership.refreshDue(force: true) }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        deepSeekGeneration += 1; feedGeneration += 1
        deepSeekTask?.cancel(); feedTask?.cancel()
        deepSeekTask = nil; feedTask = nil
        deepSeekSessionKey = nil
        isDeepSeekRefreshing = false; isFeedRefreshing = false
        miniMax?.stop()
        desktop?.stop()
        cursorAccount?.stop()
        for membership in websiteMemberships.values { membership.stop() }
    }

    @discardableResult func connectDeepSeek(_ key: String) -> Bool {
        guard allowsConnections else { deepSeekError = QuotaConnectionError.preview.localizedDescription; return false }
        guard !isDeepSeekRefreshing else { return false }
        do {
            _ = try QuotaReadRequest.deepSeek(key: key)
            try vault.save(key)
            deepSeekSessionKey = key
            deepSeekKeychainBlocked = false
            deepSeekGeneration += 1; deepSeekTask?.cancel(); deepSeekTask = nil
            deepSeekSnapshot = nil; deepSeekError = nil; deepSeekNeedsAuthorization = false
            deepSeekFailures = 0; deepSeekNextAttempt = .distantPast; deepSeekRateLimitedUntil = .distantPast
            deepSeekEnabled = true
            defaults.set(true, forKey: "quota.deepseek.enabled.v1")
            refreshDeepSeek(force: true)
            return true
        } catch { deepSeekError = Self.message(error); return false }
    }
    /// Not used by timers or the general refresh action. A cancellation stays paused.
    func authorizeDeepSeek() {
        guard allowsConnections, deepSeekEnabled, deepSeekTask == nil, deepSeekKeychainBlocked else { return }
        do {
            guard let key = try vault.readForAuthorization() else { throw QuotaConnectionError.authentication }
            _ = try QuotaReadRequest.deepSeek(key: key)
            deepSeekSessionKey = key
            deepSeekKeychainBlocked = false; deepSeekNeedsAuthorization = false; deepSeekError = nil
            refreshDeepSeek(force: true)
        } catch {
            deepSeekSessionKey = nil; deepSeekNeedsAuthorization = true
            deepSeekError = Self.message(error)
            if case QuotaConnectionError.authentication = error { deepSeekKeychainBlocked = false; deepSeekSnapshot = nil }
        }
    }
    func disconnectDeepSeek() {
        deepSeekGeneration += 1; deepSeekTask?.cancel(); deepSeekTask = nil
        deepSeekEnabled = false; isDeepSeekRefreshing = false
        deepSeekSnapshot = nil; deepSeekError = nil; deepSeekNeedsAuthorization = false
        deepSeekSessionKey = nil; deepSeekKeychainBlocked = false
        defaults.set(false, forKey: "quota.deepseek.enabled.v1")
        guard allowsConnections else { return }
        do { try vault.delete() } catch { deepSeekError = "已停止查询，但钥匙串中的 Key 未能移除，请重试移除。" }
    }
    func refreshDeepSeek(force: Bool = false) {
        let now = clock()
        guard allowsConnections, deepSeekEnabled, !deepSeekNeedsAuthorization, deepSeekTask == nil,
              now >= deepSeekRateLimitedUntil, force || now >= deepSeekNextAttempt else { return }
        isDeepSeekRefreshing = true
        let generation = deepSeekGeneration
        deepSeekTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == deepSeekGeneration { deepSeekTask = nil; isDeepSeekRefreshing = false } }
            do {
                guard let key = try deepSeekSessionKey ?? vault.read() else { throw QuotaConnectionError.authentication }
                deepSeekSessionKey = key
                let response = try await transport(QuotaReadRequest.deepSeek(key: key))
                guard generation == deepSeekGeneration, !Task.isCancelled else { return }
                if [429, 503].contains(response.status), let delay = response.retryAfter {
                    deepSeekRateLimitedUntil = clock().addingTimeInterval(delay)
                }
                try Self.validateStatus(response.status)
                let snapshot = try DeepSeekBalance.decode(response.data, at: clock())
                deepSeekSnapshot = snapshot; deepSeekError = nil; deepSeekFailures = 0
                deepSeekNextAttempt = clock().addingTimeInterval(30)
            } catch {
                guard generation == deepSeekGeneration, !Task.isCancelled else { return }
                deepSeekError = Self.message(error)
                deepSeekFailures += 1
                deepSeekNextAttempt = clock().addingTimeInterval(Self.backoff(deepSeekFailures, base: 30))
                if case QuotaConnectionError.authentication = error {
                    deepSeekNeedsAuthorization = true; deepSeekSnapshot = nil; deepSeekSessionKey = nil
                }
                if case QuotaConnectionError.keychain = error {
                    deepSeekNeedsAuthorization = true; deepSeekKeychainBlocked = true; deepSeekSessionKey = nil
                }
                if case QuotaConnectionError.rateLimited = error {
                    deepSeekRateLimitedUntil = max(deepSeekRateLimitedUntil, deepSeekNextAttempt)
                }
            }
        }
    }

    func setFeedEnabled(_ enabled: Bool) {
        guard allowsConnections else { return }
        feedGeneration += 1; feedTask?.cancel(); feedTask = nil
        feedEnabled = enabled; isFeedRefreshing = false; feedError = nil
        feedSnapshot = nil; feedETag = nil; feedRetrievedAt = nil; hasUnreadFeed = false
        feedFailures = 0; feedNextAttempt = .distantPast; feedRateLimitedUntil = .distantPast
        defaults.set(enabled, forKey: "quota.reset-feed.enabled.v1")
        if enabled { refreshFeed(force: true) }
    }
    func refreshFeed(force: Bool = false) {
        let now = Date()
        guard allowsConnections, feedEnabled, feedTask == nil, now >= feedRateLimitedUntil,
              force || now >= feedNextAttempt else { return }
        isFeedRefreshing = true
        let generation = feedGeneration
        feedTask = Task { [weak self] in
            guard let self else { return }
            defer { if generation == feedGeneration { feedTask = nil; isFeedRefreshing = false } }
            do {
                let response = try await transport(QuotaReadRequest.resetFeed(etag: feedETag))
                guard generation == feedGeneration, !Task.isCancelled else { return }
                if [429, 503].contains(response.status), let delay = response.retryAfter {
                    feedRateLimitedUntil = Date().addingTimeInterval(delay)
                }
                if response.status == 304 {
                    guard feedSnapshot != nil else { throw QuotaConnectionError.invalidData }
                } else {
                    try Self.validateStatus(response.status)
                    let snapshot = try QuotaResetFeed.decode(response.data)
                    // Full replacement also applies upstream corrections and withdrawals.
                    feedSnapshot = snapshot; feedETag = response.etag
                    let lastSeen = defaults.object(forKey: "quota.reset-feed.seen.v1") as? Date
                    if let lastSeen {
                        hasUnreadFeed = snapshot.events.contains { $0.updatedAt > lastSeen }
                    } else { markFeedRead() } // First sync never marks every historical event as new.
                }
                feedRetrievedAt = .now; feedError = nil; feedFailures = 0
                feedNextAttempt = Date().addingTimeInterval(300)
            } catch {
                guard generation == feedGeneration, !Task.isCancelled else { return }
                // Public feed authorization failures are not requests for the user's API key.
                if case QuotaConnectionError.authentication = error { feedError = Self.message(QuotaConnectionError.unavailable) }
                else { feedError = Self.message(error) }
                feedFailures += 1
                feedNextAttempt = Date().addingTimeInterval(Self.backoff(feedFailures))
                if case QuotaConnectionError.rateLimited = error {
                    feedRateLimitedUntil = max(feedRateLimitedUntil, feedNextAttempt)
                }
            }
        }
    }
    func markFeedRead() {
        hasUnreadFeed = false
        defaults.set(Date(), forKey: "quota.reset-feed.seen.v1")
    }
    private static func validateStatus(_ status: Int) throws {
        switch status {
        case 200: return
        case 401, 403: throw QuotaConnectionError.authentication
        case 429: throw QuotaConnectionError.rateLimited
        default: throw QuotaConnectionError.unavailable
        }
    }
    private static func backoff(_ failures: Int, base: TimeInterval = 300) -> TimeInterval {
        min(3600, base * pow(2, Double(min(failures - 1, 7))))
    }
    private static func message(_ error: Error) -> String {
        // Never publish an arbitrary URLSession/server/Keychain error containing request data.
        (error as? QuotaConnectionError ?? .unavailable).localizedDescription
    }
}
