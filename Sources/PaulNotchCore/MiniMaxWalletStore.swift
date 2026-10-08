import Foundation
import Combine

@MainActor final class MiniMaxWalletStore: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var snapshot: MiniMaxWalletBalance?
    @Published private(set) var error: String?
    @Published private(set) var needsAuthorization = false
    @Published private(set) var keychainBlocked = false
    @Published private(set) var isRefreshing = false
    let allowsConnections: Bool
    private let defaults: UserDefaults
    private let vault: any QuotaCredentialStoring
    private let transport: @Sendable (URLRequest) async throws -> QuotaHTTPResponse
    private let clock: () -> Date
    private var task: Task<Void, Never>?
    private var sessionKey: String?
    private var generation = 0
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var rateLimitedUntil = Date.distantPast
    private static let enabledKey = "quota.minimax-cn-wallet.enabled.v1"

    init(defaults: UserDefaults, vault: any QuotaCredentialStoring, allowsConnections: Bool,
         transport: @escaping @Sendable (URLRequest) async throws -> QuotaHTTPResponse,
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.vault = vault; self.transport = transport
        self.allowsConnections = allowsConnections
        self.clock = clock
        enabled = allowsConnections && defaults.bool(forKey: Self.enabledKey)
    }

    @discardableResult func connect(_ key: String) -> Bool {
        guard allowsConnections else { error = QuotaConnectionError.preview.localizedDescription; return false }
        guard !isRefreshing else { return false }
        guard clock() >= rateLimitedUntil else { error = QuotaConnectionError.rateLimited.localizedDescription; return false }
        do { _ = try QuotaReadRequest.miniMaxWallet(key: key) }
        catch {
            self.error = "请填写中国站 sk-api- 开头的普通 API Key，不支持 Token Plan Key；不要包含空格或换行。"
            return false
        }
        // A replacement is validated before touching the working key or its opt-in.
        query(candidateKey: key)
        return true
    }

    func refresh(force: Bool = false) {
        guard allowsConnections, enabled, !needsAuthorization, !isRefreshing,
              clock() >= rateLimitedUntil, force || clock() >= nextAttempt else { return }
        query(candidateKey: nil)
    }

    func stop() {
        generation += 1; task?.cancel(); task = nil; isRefreshing = false
        sessionKey = nil
    }

    /// Deliberate foreground authorization only; a rejection never schedules a retry.
    func authorizeSavedKey() {
        guard allowsConnections, enabled, !isRefreshing, keychainBlocked else { return }
        do {
            guard let key = try vault.readForAuthorization() else { throw QuotaConnectionError.authentication }
            _ = try QuotaReadRequest.miniMaxWallet(key: key)
            sessionKey = key; keychainBlocked = false; needsAuthorization = false; error = nil
            refresh(force: true)
        } catch {
            sessionKey = nil; needsAuthorization = true
            self.error = (error as? QuotaConnectionError ?? .unavailable).localizedDescription
            if case QuotaConnectionError.authentication = error { keychainBlocked = false; snapshot = nil }
        }
    }

    func disconnect() {
        stop()
        enabled = false; snapshot = nil; error = nil; needsAuthorization = false
        keychainBlocked = false
        defaults.set(false, forKey: Self.enabledKey)
        guard allowsConnections else { return }
        do { try vault.delete() }
        catch { self.error = "已停止查询，但钥匙串中的 Key 未能移除，请重试移除。" }
    }

    private func query(candidateKey: String?) {
        isRefreshing = true; error = nil
        let currentGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if currentGeneration == generation { task = nil; isRefreshing = false } }
            do {
                guard let key = try candidateKey ?? sessionKey ?? vault.read() else { throw QuotaConnectionError.authentication }
                if candidateKey == nil { sessionKey = key }
                let response = try await transport(QuotaReadRequest.miniMaxWallet(key: key))
                guard currentGeneration == generation, !Task.isCancelled else { return }
                if [429, 503].contains(response.status), let delay = response.retryAfter {
                    rateLimitedUntil = clock().addingTimeInterval(delay)
                }
                if [401, 403].contains(response.status) { throw QuotaConnectionError.authentication }
                if response.status == 429 { throw QuotaConnectionError.rateLimited }
                guard [200, 400].contains(response.status) else { throw QuotaConnectionError.unavailable }
                // MiniMax also sends business/auth errors in a JSON base_resp envelope.
                let result = try MiniMaxWalletBalance.decode(response.data, at: clock())
                guard response.status == 200 else { throw QuotaConnectionError.unavailable }
                if let candidateKey { try vault.save(candidateKey) }
                sessionKey = key; keychainBlocked = false
                snapshot = result; enabled = true; needsAuthorization = false; error = nil; failures = 0
                defaults.set(true, forKey: Self.enabledKey)
                nextAttempt = clock().addingTimeInterval(30)
            } catch {
                guard currentGeneration == generation, !Task.isCancelled else { return }
                self.error = (error as? QuotaConnectionError ?? .unavailable).localizedDescription
                failures += 1
                nextAttempt = clock().addingTimeInterval(min(3600, 30 * pow(2, Double(min(failures - 1, 7)))))
                if case QuotaConnectionError.authentication = error, candidateKey == nil {
                    needsAuthorization = true; snapshot = nil; sessionKey = nil
                }
                if case QuotaConnectionError.keychain = error, candidateKey == nil {
                    needsAuthorization = true; keychainBlocked = true; sessionKey = nil
                }
                if case QuotaConnectionError.rateLimited = error {
                    rateLimitedUntil = max(rateLimitedUntil, nextAttempt)
                }
            }
        }
    }

    func account(now: Date) -> QuotaOverviewAccount {
        guard let snapshot else {
            return QuotaOverviewAccount(id: "minimax-api", name: "MiniMax API", account: "中国站 · 人民币钱包", group: .usage,
                value: .unknown, timing: keychainBlocked ? "需要授权" : (enabled ? "等待有效余额" : "填写 Key 后查询"), status: enabled ? .unavailable : .notConnected,
                explanation: "仅连接中国站按量付费钱包；Token Plan 与 Audio 会员积分不在此连接中。",
                unavailableReason: !allowsConnections ? "隔离验证不读取账户" :
                    (keychainBlocked ? "钥匙串授权尚未完成" :
                        (error ?? (enabled ? "余额尚未返回" : "尚未连接 API Key"))))
        }
        let age = now.timeIntervalSince(snapshot.observedAt)
        let fresh = error == nil && age >= -60 && age <= 90
        let amounts: [(String, Decimal)] = [("可用额度", snapshot.available), ("现金", snapshot.cash),
            ("代金券", snapshot.voucher), ("授信", snapshot.credit), ("欠费", snapshot.owed)]
        let details = [QuotaOverviewDetail(label: "最近读取", value: snapshot.observedAt.formatted(date: .abbreviated, time: .shortened)),
            .init(label: "数据来源", value: "MiniMax 中国站 /account/query_balance")] + amounts.map {
                QuotaOverviewDetail(label: $0.0, value: QuotaOverviewValue.money($0.1, currency: "CNY").text)
            }
        return QuotaOverviewAccount(id: "minimax-api", name: "MiniMax API", account: "中国站 · 人民币钱包", group: .usage,
            value: .money(snapshot.available, currency: "CNY"), timing: "按量扣费", status: fresh ? .current : .stale,
            details: details, explanation: "显示中国站钱包返回的可用额度，不重新合计现金、券、授信和欠费。\(fresh ? "每 30 秒自动查询，厂商入账可能延迟。" : "当前为上次读取的旧数据。")按量钱包不周期重置，接口未提供券到期时间；不含 Audio 会员积分。",
            unavailableReason: fresh ? nil : (keychainBlocked ? "钥匙串授权尚未完成" :
                (error ?? "余额已过期，请刷新确认")))
    }
}
