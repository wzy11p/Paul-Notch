import Combine
import Foundation

/// One membership owner. Only explicit connection actions may open another app;
/// timer reads are passive and never request permissions or touch credentials.
@MainActor final class DesktopQuotaStore: ObservableObject {
    struct State {
        var snapshot: DesktopQuotaSnapshot?
        var error: DesktopQuotaFailure?
    }
    @Published private(set) var states: [DesktopQuotaProvider: State] = [:]
    @Published private(set) var enabled: Set<DesktopQuotaProvider> = []
    @Published private(set) var readingProviders: Set<DesktopQuotaProvider> = []
    var reading: DesktopQuotaProvider? {
        interactiveProvider ?? readingProviders.sorted { $0.rawValue < $1.rawValue }.first
    }
    let allowsReads: Bool
    private let defaults: UserDefaults
    private let reader: @Sendable (DesktopQuotaProvider, Bool) async throws -> DesktopQuotaSnapshot
    private var tasks: [DesktopQuotaProvider: Task<Void, Never>] = [:]
    private var revisions: [DesktopQuotaProvider: Int] = [:]
    private var interactiveProvider: DesktopQuotaProvider?
    private var loop: Task<Void, Never>?
    private let clock: () -> Date
    private let supportedProviders: Set<DesktopQuotaProvider>
    private var nextRead: [DesktopQuotaProvider: Date] = [:]

    init(defaults: UserDefaults, allowsReads: Bool,
         clock: @escaping () -> Date = Date.init,
         supportedProviders: Set<DesktopQuotaProvider> = Set(DesktopQuotaProvider.allCases),
         reader: @escaping @Sendable (DesktopQuotaProvider, Bool) async throws -> DesktopQuotaSnapshot) {
        self.defaults = defaults; self.allowsReads = allowsReads; self.reader = reader; self.clock = clock
        self.supportedProviders = supportedProviders
        if allowsReads {
            enabled = Set(supportedProviders.filter { defaults.bool(forKey: Self.key($0)) })
        }
    }
    private static func key(_ provider: DesktopQuotaProvider) -> String { "quota.desktop.\(provider.rawValue).enabled.v1" }

    func start() {
        guard allowsReads, loop == nil else { return }
        refreshDue()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, let self else { break }
                self.refreshDue()
            }
        }
    }

    func isReading(_ provider: DesktopQuotaProvider) -> Bool { readingProviders.contains(provider) }

    func read(_ provider: DesktopQuotaProvider, interactive: Bool = true) {
        guard allowsReads else { states[provider] = State(error: .preview); return }
        guard supportedProviders.contains(provider) else { return }
        guard tasks[provider] == nil, interactive || enabled.contains(provider),
              !interactive || interactiveProvider == nil else { return }
        readingProviders.insert(provider)
        if interactive { interactiveProvider = provider }
        let revision = revisions[provider, default: 0]
        tasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer {
                if revisions[provider, default: 0] == revision {
                    readingProviders.remove(provider); tasks[provider] = nil
                    if interactiveProvider == provider { interactiveProvider = nil }
                }
            }
            guard revisions[provider, default: 0] == revision, !Task.isCancelled else { return }
            do {
                let snapshot = try await reader(provider, interactive)
                guard revisions[provider, default: 0] == revision, !Task.isCancelled else { return }
                states[provider] = State(snapshot: snapshot)
                if enabled.insert(provider).inserted { defaults.set(true, forKey: Self.key(provider)) }
                nextRead[provider] = clock().addingTimeInterval(10)
            } catch {
                guard revisions[provider, default: 0] == revision, !Task.isCancelled else { return }
                states[provider, default: State()].error = error as? DesktopQuotaFailure ?? .pageUnavailable
                nextRead[provider] = clock().addingTimeInterval(30)
            }
        }
    }
    func refreshDue(force: Bool = false) {
        let now = clock()
        for provider in enabled where force || (nextRead[provider] ?? .distantPast) <= now {
            read(provider, interactive: false)
        }
    }
    func disconnect(_ provider: DesktopQuotaProvider) {
        cancel(provider)
        enabled.remove(provider); states[provider] = nil; nextRead[provider] = nil
        if allowsReads { defaults.removeObject(forKey: Self.key(provider)) }
    }
    func stop() {
        loop?.cancel(); loop = nil
        for provider in Array(tasks.keys) { cancel(provider) }
        nextRead.removeAll()
    }
    private func cancel(_ provider: DesktopQuotaProvider) {
        revisions[provider, default: 0] += 1
        tasks[provider]?.cancel(); tasks[provider] = nil
        readingProviders.remove(provider)
        if interactiveProvider == provider { interactiveProvider = nil }
    }

    func account(_ provider: DesktopQuotaProvider, now: Date = .now) -> QuotaOverviewAccount {
        let state = states[provider]
        let failureReason: String?
        switch state?.error {
        case .permission: failureReason = "未获辅助功能授权"
        case .notRunning: failureReason = "原应用尚未运行"
        case .pageUnavailable: failureReason = "原应用额度页不可见"
        case .invalidData: failureReason = "额度格式暂未识别"
        case .preview: failureReason = "隔离验证不读取账户"
        case nil: failureReason = nil
        }
        guard let snapshot = state?.snapshot, let first = snapshot.pools.first else {
            return .init(id: provider.rawValue, name: provider.name, account: "桌面会员", group: .membership,
                value: .unknown, timing: isReading(provider) ? "正在读取…" : (state?.error == nil ? "点击连接" : "读取未成功 · 点击处理"),
                status: enabled.contains(provider) || state?.error != nil ? .unavailable : .notConnected,
                explanation: state?.error?.message ?? "读取原应用的会员额度页，不需要 API Key。",
                unavailableReason: failureReason ?? (!allowsReads ? "隔离验证不读取账户" :
                    (isReading(provider) ? "尚未返回额度，正在读取" : "尚未连接原应用")))
        }
        let age = now.timeIntervalSince(snapshot.observedAt)
        let fresh = state?.error == nil && (-60...90).contains(age)
        var details = [QuotaOverviewDetail(label: "数据来源", value: "\(provider.name) 额度页面"),
                       .init(label: "最近读取", value: snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))]
            + snapshot.pools.map { .init(label: "\($0.name)剩余", value: "\($0.remaining)%") }
        details.append(.init(label: "额度重置", value: snapshot.resetLabel ?? "原页面未提供"))
        if let expiry = snapshot.expiryLabel { details.append(.init(label: "活动赠送期限", value: expiry)) }
        return .init(id: provider.rawValue, name: provider.name, account: "会员 · \(first.name)", group: .membership,
            value: .percent(first.remaining), timing: fresh ? (snapshot.resetLabel ?? "重置时间未提供") : "上次读取 · 点击更新",
            status: fresh ? .current : .stale, details: details,
            explanation: "由原应用“已用”换算剩余；仅在额度页可读取时更新。离开页面或读取失败后保留上次值并标记，不是后台官方 API。",
            unavailableReason: fresh ? nil : (failureReason ?? "数据已过期，请重新读取"))
    }
}
