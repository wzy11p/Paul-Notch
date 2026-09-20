import AppKit
import Foundation

struct SavedLink: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var url: String
    var title: String
    var faviconData: Data?
    var createdAt: Date

    init(id: UUID = UUID(), url: String, title: String, faviconData: Data? = nil, createdAt: Date = .now) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconData = faviconData
        self.createdAt = createdAt
    }
}

struct LinkGroup: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var links: [SavedLink]

    init(id: UUID = UUID(), name: String, links: [SavedLink] = []) {
        self.id = id
        self.name = name
        self.links = links
    }
}

/// Ported from TO-DO-Panel renderer/domain.js CATEGORY_RULES.
enum LinkClassifier {
    private static let rules: [(String, NSRegularExpression)] = {
        let raw: [(String, String)] = [
            ("开发", #"github|gitlab|gitee|stackoverflow|developer|docs\.|npmjs|vercel|cloudflare|code|openai|anthropic"#),
            ("工作", #"feishu|larksuite|notion|slack|trello|asana|figma|miro|office|docs\.google"#),
            ("学习", #"wikipedia|coursera|udemy|edx|medium|juejin|zhihu|yuque|book|learn"#),
            ("影音", #"bilibili|youtube|youku|iqiyi|netflix|spotify|music|video"#),
            ("社交", #"weibo|twitter|x\.com|facebook|instagram|reddit|discord|wechat"#),
            ("购物", #"taobao|tmall|jd\.com|amazon|shop|mall"#),
        ]
        return raw.compactMap { name, pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { (name, $0) }
        }
    }()

    static func classify(url: String, title: String) -> String {
        let haystack = "\(url) \(title)"
        let range = NSRange(haystack.startIndex..., in: haystack)
        for (name, regex) in rules where regex.firstMatch(in: haystack, range: range) != nil {
            return name
        }
        return "其他"
    }
}

/// SSRF guard ported from TO-DO-Panel main-services.js isPrivateAddress.
enum LinkSafety {
    static func isPrivateHost(_ host: String) -> Bool {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if value.isEmpty || value == "localhost" || value.hasSuffix(".localhost") || value.hasSuffix(".local") {
            return true
        }
        if value == "::1" || value.hasPrefix("fe80") || value.hasPrefix("fc") || value.hasPrefix("fd") { return true }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        if parts[0] == 0 || parts[0] == 10 || parts[0] == 127 || parts[0] >= 224 { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        return false
    }

    /// Accepts bare domains and full URLs; rejects non-http(s) and private hosts.
    static func normalizeHttpURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.range(of: #"^[a-z][a-z\d+.-]*:"#, options: .regularExpression) != nil
            ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !isPrivateHost(host) else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }
}

@MainActor
final class LinksStore: ObservableObject {
    @Published private(set) var groups: [LinkGroup] = []
    @Published var errorMessage: String?

    private let fileURL: URL

    init() {
        let base = AppEnvironment.dataDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("links.json")
        load()
    }

    func add(rawURL: String) {
        guard let url = LinkSafety.normalizeHttpURL(rawURL) else {
            errorMessage = "链接无效：仅支持公网 http/https 地址"
            return
        }
        let text = url.absoluteString
        guard !groups.contains(where: { $0.links.contains(where: { $0.url == text }) }) else { return }
        let link = SavedLink(url: text, title: hostLabel(of: url))
        insert(link, category: LinkClassifier.classify(url: text, title: ""))
        persist()
    }

    func delete(_ link: SavedLink) {
        for index in groups.indices {
            groups[index].links.removeAll { $0.id == link.id }
        }
        groups.removeAll { $0.links.isEmpty }
        persist()
    }

    func renameGroup(_ group: LinkGroup, name: String) {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[index].name = cleaned
        persist()
    }

    func open(_ link: SavedLink) {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private func insert(_ link: SavedLink, category: String) {
        if let index = groups.firstIndex(where: { $0.name == category }) {
            groups[index].links.insert(link, at: 0)
        } else {
            groups.append(LinkGroup(name: category, links: [link]))
        }
    }

    private func hostLabel(of url: URL) -> String {
        url.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ?? url.absoluteString
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        groups = (try? decoder.decode([LinkGroup].self, from: data)) ?? []
    }

    private func persist() {
        let snapshot = groups
        let url = fileURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}
