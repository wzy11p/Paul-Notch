import Foundation

/// The application owns these login pages. No session is imported from another
/// browser/app. Website login data is managed exclusively by owned WebKit
/// profiles; passwords, Cookies and localStorage values never cross our bridge.
enum WebsiteQuotaProvider: String, CaseIterable, Codable {
    case doubao, miniMaxCN, miniMaxGlobal, muse
    var accountID: String {
        switch self { case .doubao: "doubao"; case .muse: "muse"; default: "minimax-audio" }
    }
    var name: String {
        switch self { case .doubao: "豆包工作"; case .muse: "Muse"; default: "MiniMax Audio" }
    }
    var isAudio: Bool { self == .miniMaxCN || self == .miniMaxGlobal }
    var host: String {
        switch self {
        case .doubao: "www.doubao.com"; case .miniMaxCN: "www.minimax.cn"
        case .miniMaxGlobal: "www.minimax.io"; case .muse: "muse.ai"
        }
    }
    var quotaURL: URL {
        switch self {
        case .doubao: URL(string: "https://www.doubao.com/member/quota-management?quota_tab=personal&is_work=1&locale=zh")!
        case .miniMaxCN: URL(string: "https://www.minimax.cn/audio/subscribe")!
        case .miniMaxGlobal: URL(string: "https://www.minimax.io/audio/subscribe")!
        case .muse: URL(string: "https://muse.ai/?settings_tab=general")!
        }
    }
    func permitsCapture(_ url: URL) -> Bool {
        guard permitsOrigin(url), url.host == host else { return false }
        if self == .muse {
            guard url.path == "/", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
            let items = components.queryItems ?? []
            // Muse consumes this deep link after opening General. The cleared
            // root only passes the URL gate; the rendered settings/usage gate
            // must still verify a completed personal quota before publishing.
            if items.isEmpty { return true }
            // `pane=subscriptions` is billing management, not General's usage.
            return items.count == 1 && items[0].name == "settings_tab" && items[0].value == "general"
        }
        return url.path == (self == .doubao ? "/member/quota-management" : "/audio/subscribe")
    }
    func permitsOrigin(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil, url.user == nil, url.password == nil else { return false }
        if url.host == host { return true }
        // Exact origins observed in the official first-login redirect chain.
        // Login navigation never makes these hosts quota-capture sources.
        if self == .muse {
            return ["auth.muse.ai", "auth.meta.com", "www.facebook.com", "www.instagram.com"].contains(url.host ?? "")
        }
        // The official Doubao page uses this exact Feishu SSO origin even for
        // its silent-login iframe. Navigation is not permission to capture it.
        if self == .doubao, url.host == "accounts.feishu.cn" { return true }
        return self == .miniMaxGlobal && url.host == "accounts.google.com"
    }
}

struct WebsiteQuotaRow: Equatable {
    let name: String
    let usage: String
    let timing: String
}

struct WebsiteQuotaSnapshot: Equatable {
    let value: QuotaOverviewValue
    let timing: String
    let details: [QuotaOverviewDetail]
    let observedAt: Date
    var resetsAt: Date? = nil
    var endsAt: Date? = nil
    var pools: [QuotaOverviewPool] = []
}

enum WebsiteQuotaParser {
    /// Fields come only from the owned official quota document. A rounded DOM
    /// token label stays a label; only an exact response balance becomes tokens.
    static func muse(used: Double, reset: String?, extraBalance: Int?, extraDisplay: String?,
                     extraNeverExpires: Bool, at now: Date) throws -> WebsiteQuotaSnapshot {
        guard used.isFinite, (0...100).contains(used),
              extraBalance.map({ (0...1_000_000_000_000).contains($0) }) ?? true,
              reset.map({ $0.count <= 120 }) ?? true,
              extraDisplay.map({ $0.count <= 80 }) ?? true else { throw QuotaConnectionError.invalidData }
        let value = QuotaOverviewValue.percent(Int((100 - used).rounded(.down)))
        let reset = reset?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Date-only captions do not supply an hour or timezone. Keep their
        // wording rather than inventing midnight for the ambient countdown.
        let preciseReset = reset.flatMap { text -> Date? in
            guard text.range(of: #"^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:?\d{2})$"#,
                             options: .regularExpression) != nil else { return nil }
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions.insert(.withFractionalSeconds)
            return formatter.date(from: text)
        }
        let timing = preciseReset.map { date in
            date > now ? "\(Int(ceil(date.timeIntervalSince(now) / 86_400))) 天后重置" : "等待官方更新重置额度"
        } ?? (reset.flatMap { $0.isEmpty ? nil : $0 } ?? "官方未提供重置时间")
        var details = [QuotaOverviewDetail(label: "每周剩余", value: value.text)]
        if let reset, !reset.isEmpty { details.append(.init(label: "每周重置", value: reset)) }
        var pools = [QuotaOverviewPool(label: "每周", value: value, timing: timing)]
        let extraTiming = extraNeverExpires ? "从不过期" : "官方未提供到期时间"
        if let extraBalance {
            let extra = QuotaOverviewValue.credits(extraBalance, unit: "词元")
            details.append(.init(label: "额外词元余额", value: extra.text))
            details.append(.init(label: "额外余额到期", value: extraTiming))
            pools.append(.init(label: "额外余额", value: extra, timing: extraTiming))
        } else if let extraDisplay, !extraDisplay.isEmpty {
            details.append(.init(label: "额外余额（页面显示）", value: extraDisplay))
            details.append(.init(label: "额外余额到期", value: extraTiming))
        }
        return .init(value: value, timing: timing, details: details, observedAt: now,
                     resetsAt: preciseReset, pools: pools)
    }

    static func doubao(rows: [WebsiteQuotaRow], at now: Date) throws -> WebsiteQuotaSnapshot {
        func normalized(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        var values: [String: QuotaOverviewValue] = [:]
        var timings: [String: String] = [:]
        for row in rows {
            let name = normalized(row.name).replacingOccurrences(of: " ", with: "")
            guard ["当前时段", "近7天"].contains(name), values[name] == nil,
                  row.timing.count <= 150 else { throw QuotaConnectionError.invalidData }
            let usage = normalized(row.usage)
            switch usage {
            case "未消耗", "未使用": values[name] = .percent(100)
            case "已用完": values[name] = .percent(0)
            case "暂无限制": values[name] = .unlimited
            default:
                if usage.range(of: #"^已用\s*<1%$"#, options: .regularExpression) != nil {
                    values[name] = .percentBound(lowerExclusive: 99, upperInclusive: 100)
                } else {
                    guard let match = usage.range(of: #"^已用\s*[0-9]+(?:\.[0-9]+)?%$"#, options: .regularExpression),
                          match == usage.startIndex..<usage.endIndex,
                          let used = Double(usage.replacingOccurrences(of: "已用", with: "").replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)),
                          used.isFinite, (0...100).contains(used) else { throw QuotaConnectionError.invalidData }
                    values[name] = .percent(Int((100 - used).rounded(.down)))
                }
            }
            timings[name] = normalized(row.timing)
        }
        guard values.count == 2, let primary = values["当前时段"], let weekly = values["近7天"] else { throw QuotaConnectionError.invalidData }
        var details = [QuotaOverviewDetail(label: "当前时段剩余", value: primary.text),
                       .init(label: "近 7 天剩余", value: weekly.text)]
        for name in ["当前时段", "近7天"] {
            if let timing = timings[name], !timing.isEmpty { details.append(.init(label: "\(name)重置", value: timing)) }
        }
        return .init(value: primary, timing: timings["当前时段"].flatMap { $0.isEmpty ? nil : $0 } ?? "官方未提供重置时间",
                     details: details, observedAt: now,
                     pools: [.init(label: "当前时段", value: primary, timing: timings["当前时段"].flatMap { $0.isEmpty ? nil : $0 } ?? "未提供重置时间"),
                             .init(label: "近 7 天", value: weekly, timing: timings["近7天"].flatMap { $0.isEmpty ? nil : $0 } ?? "未提供重置时间")])
    }

    /// Called only for a successful owned-page billing response, not default UI
    /// state, a plan's advertised allocation or the unrelated API wallet.
    static func audio(amount: Double, reload: String?, ends: String?, at now: Date) throws -> WebsiteQuotaSnapshot {
        guard amount.isFinite, (0...1_000_000_000_000).contains(amount), amount.rounded(.down) == amount else {
            throw QuotaConnectionError.invalidData
        }
        let resets = parseDate(reload), expires = parseDate(ends)
        var details = [QuotaOverviewDetail(label: "配音声贝余额", value: "\(Int(amount).formatted(.number)) 声贝")]
        if let reload, !reload.isEmpty, reload.count <= 120 { details.append(.init(label: "声贝重置", value: reload)) }
        if let ends, !ends.isEmpty, ends.count <= 120 { details.append(.init(label: "当前套餐结束", value: ends)) }
        let deadline = resets ?? expires
        let timing = deadline.map { date -> String in
            let interval = date.timeIntervalSince(now)
            guard interval > 0 else { return "等待官方更新" }
            return "\(Int(ceil(interval / 86_400))) 天后\(resets == nil ? "套餐结束" : "重置")"
        } ?? "官方未提供重置 / 到期时间"
        return .init(value: .credits(Int(amount), unit: "声贝"), timing: timing,
                     details: details, observedAt: now, resetsAt: resets, endsAt: expires)
    }
    private static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty, text.count <= 120 else { return nil }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.isLenient = false
        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd"] {
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text), (2020...2100).contains(Calendar.current.component(.year, from: date)) { return date }
        }
        return nil
    }
}
