import Foundation

@MainActor
final class CodexStatusStore: ObservableObject {
    private struct Cache: Codable {
        let quota: CodexQuotaSnapshot?
        let tasks: [CodexTaskSummary]
    }

    @Published private(set) var quota: CodexQuotaSnapshot?
    @Published private(set) var tasks: [CodexTaskSummary] = []
    @Published private(set) var quotaError: String?
    @Published private(set) var taskError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRefreshingTasks = false
    @Published private(set) var tasksUpdatedAt: Date?
    private var isRefreshingQuota = false

    private static let cacheKey = "paul-notch-codex-status-cache-v1"
    private let client: IslandCodexAppServerClient
    private let runtimeIndex: IslandCodexTaskRuntimeIndex
    private let rolloutActivityIndex: IslandCodexRolloutActivityIndex
    private var quotaLoop: Task<Void, Never>?
    private var taskLoop: Task<Void, Never>?
    private var eventRefreshTask: Task<Void, Never>?
    private var isStarted = false

    init(
        client: IslandCodexAppServerClient = IslandCodexAppServerClient(),
        runtimeIndex: IslandCodexTaskRuntimeIndex = IslandCodexTaskRuntimeIndex(),
        rolloutActivityIndex: IslandCodexRolloutActivityIndex = IslandCodexRolloutActivityIndex()
    ) {
        self.client = client
        self.runtimeIndex = runtimeIndex
        self.rolloutActivityIndex = rolloutActivityIndex
        restoreCache()
    }

    var preferredQuota: CodexQuotaWindow? { quota?.preferredWindow }

    var displayQuotaWindows: [CodexQuotaWindow] {
        Array((quota?.visibleWindows ?? []).prefix(2))
    }

    var workingTasks: [CodexTaskSummary] {
        tasksAreFresh ? tasks.filter { $0.state == .working } : []
    }

    var tasksAreFresh: Bool {
        guard taskError == nil, let tasksUpdatedAt else { return false }
        return Date().timeIntervalSince(tasksUpdatedAt) < 12
    }

    var taskSyncDescription: String {
        if let taskError { return "任务同步失败：\(taskError)" }
        guard tasksAreFresh else { return "任务状态尚未同步，不能判断是否空闲" }
        return "本地任务状态 · 约每 2 秒更新 · 不含子代理"
    }

    var isConnected: Bool {
        quota != nil && quotaError == nil
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        Task { [weak self] in
            guard let self else { return }
            await client.setRateLimitUpdatedHandler { [weak self] in
                Task { @MainActor in self?.scheduleEventRefresh() }
            }
            await refreshAll()
            guard isStarted else { return }
            startLoops()
        }
    }

    func stop() {
        isStarted = false
        tasksUpdatedAt = nil
        quotaLoop?.cancel()
        taskLoop?.cancel()
        eventRefreshTask?.cancel()
        quotaLoop = nil
        taskLoop = nil
        eventRefreshTask = nil
        let client = client
        Task {
            await client.setRateLimitUpdatedHandler(nil)
            await client.stop()
        }
    }

    func refreshNow() {
        Task { [weak self] in await self?.refreshAll() }
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        // Preserve the established account-then-catalog startup order.
        // Per-domain guards prevent duplicate work from periodic/manual refresh.
        await refreshQuota()
        await refreshTasks()
    }

    private func refreshQuota() async {
        guard !isRefreshingQuota else { return }
        isRefreshingQuota = true
        defer { isRefreshingQuota = false }
        do {
            quota = try await client.readQuota()
            quotaError = nil
            persistCache()
        } catch {
            quotaError = error.localizedDescription
            if var cached = quota {
                cached.freshness = .stale
                quota = cached
            }
        }
    }

    private func refreshTasks() async {
        guard !isRefreshingTasks else { return }
        isRefreshingTasks = true
        defer { isRefreshingTasks = false }
        do {
            let fetched = try await client.readRecentTasks(limit: 100)
            let databaseStates = (try? await runtimeIndex.latestStates(for: fetched.map(\.id))) ?? [:]
            let rolloutStates = await rolloutActivityIndex.latestStates(for: fetched)
            tasks = fetched.map { task in
                let candidates = [databaseStates[task.id], rolloutStates[task.id]].compactMap { $0 }
                guard let runtime = candidates.max(by: { lhs, rhs in
                    (lhs.observedAt ?? .distantPast) < (rhs.observedAt ?? .distantPast)
                }) else { return task }
                return task.withState(runtime.taskState())
            }
            taskError = nil
            tasksUpdatedAt = .now
            persistCache()
        } catch {
            taskError = error.localizedDescription
        }
    }

    private func startLoops() {
        quotaLoop?.cancel()
        taskLoop?.cancel()

        quotaLoop = Task { [weak self] in
            while let self, self.isStarted, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard self.isStarted, !Task.isCancelled else { break }
                await self.refreshQuota()
            }
        }

        taskLoop = Task { [weak self] in
            while let self, self.isStarted, !Task.isCancelled {
                let interval: UInt64 = self.taskError == nil ? 2 : 5
                try? await Task.sleep(nanoseconds: interval * 1_000_000_000)
                guard self.isStarted, !Task.isCancelled else { break }
                await self.refreshTasks()
            }
        }
    }

    private func scheduleEventRefresh() {
        eventRefreshTask?.cancel()
        eventRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.refreshQuota()
        }
    }

    private func restoreCache() {
        guard let data = AppEnvironment.defaults.data(forKey: Self.cacheKey),
              let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            return
        }
        if var cachedQuota = cache.quota {
            cachedQuota.freshness = .stale
            quota = cachedQuota
        }
        tasks = cache.tasks
    }

    private func persistCache() {
        let cache = Cache(quota: quota, tasks: tasks)
        if let data = try? JSONEncoder().encode(cache) {
            AppEnvironment.defaults.set(data, forKey: Self.cacheKey)
        }
    }
}
