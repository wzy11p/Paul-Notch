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
    private var loadFailure: String?
    private var pendingWrite: Task<Bool, Never>?
    private var writeGeneration = 0
    private let writer: LinkFileWriter

    private let fileURL: URL

    init() {
        let base = AppEnvironment.dataDirectory
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("links.json")
        writer = LinkFileWriter(fileURL: fileURL)
        load()
    }

    @discardableResult
    func add(rawURL: String) async -> Bool {
        guard loadFailure == nil else { errorMessage = loadFailure; return false }
        guard let url = LinkSafety.normalizeHttpURL(rawURL) else {
            errorMessage = "链接无效：仅支持公网 http/https 地址"
            return false
        }
        let text = url.absoluteString
        if groups.contains(where: { $0.links.contains(where: { $0.url == text }) }) { return true }
        let link = SavedLink(url: text, title: hostLabel(of: url))
        let saved = await commit { groups in
            guard !groups.contains(where: { $0.links.contains(where: { $0.url == text }) }) else { return }
            Self.insert(link, category: LinkClassifier.classify(url: text, title: ""), into: &groups)
        }
        guard saved else { return false }
        return true
    }

    func delete(_ link: SavedLink) async {
        _ = await commit { groups in
            for index in groups.indices {
                groups[index].links.removeAll { $0.id == link.id }
            }
            groups.removeAll { $0.links.isEmpty }
        }
    }

    func renameGroup(_ group: LinkGroup, name: String) async {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        _ = await commit { groups in
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            groups[index].name = cleaned
        }
    }

    func open(_ link: SavedLink) {
        guard let url = URL(string: link.url) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func insert(_ link: SavedLink, category: String, into groups: inout [LinkGroup]) {
        if let index = groups.firstIndex(where: { $0.name == category }) {
            groups[index].links.insert(link, at: 0)
        } else {
            groups.append(LinkGroup(name: category, links: [link]))
        }
    }

    private func hostLabel(of url: URL) -> String {
        url.host?.replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression) ?? url.absoluteString
    }

    // Pure parsing helpers remain available to isolated fixtures. The public
    // distribution deliberately performs no link-metadata network requests.
    static func extractPageTitle(html: String) -> String? {
        if let og = metaContent(html: html, key: "og:title"), !og.isEmpty { return cleanTitle(og) }
        guard let regex = try? NSRegularExpression(pattern: #"<title\b[^>]*>([\s\S]*?)</title>"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let title = cleanTitle(String(html[range]))
        return title.isEmpty ? nil : title
    }

    private static func metaContent(html: String, key: String) -> String? {
        guard let tagRegex = try? NSRegularExpression(pattern: #"<meta\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        let fullRange = NSRange(html.startIndex..., in: html)
        for match in tagRegex.matches(in: html, range: fullRange) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let propRegex = try? NSRegularExpression(pattern: #"(?:property|name)\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]),
                  let propMatch = propRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let propRange = Range(propMatch.range(at: 1), in: tag),
                  tag[propRange].lowercased() == key.lowercased(),
                  let contentRegex = try? NSRegularExpression(pattern: #"content\s*=\s*["']([^"']*)["']"#, options: [.caseInsensitive]),
                  let contentMatch = contentRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let contentRange = Range(contentMatch.range(at: 1), in: tag) else { continue }
            return String(tag[contentRange])
        }
        return nil
    }

    static func extractFaviconHref(html: String, pageURL: URL) -> URL? {
        guard let tagRegex = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        let fullRange = NSRange(html.startIndex..., in: html)
        for match in tagRegex.matches(in: html, range: fullRange) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let relRegex = try? NSRegularExpression(pattern: #"rel\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]),
                  let relMatch = relRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let relRange = Range(relMatch.range(at: 1), in: tag),
                  tag[relRange].range(of: #"(?:^|\s)(?:shortcut\s+)?icon(?:\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let hrefRegex = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: [.caseInsensitive]),
                  let hrefMatch = hrefRegex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
                  let hrefRange = Range(hrefMatch.range(at: 1), in: tag) else { continue }
            let href = String(tag[hrefRange]).replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: href, relativeTo: pageURL)?.absoluteURL,
               url.scheme == "http" || url.scheme == "https" { return url }
        }
        // Fallback: /favicon.ico at the site root.
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        components?.path = "/favicon.ico"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private static func cleanTitle(_ value: String) -> String {
        let withoutTags = value.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        let entities = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        let squashed = entities.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(squashed.prefix(160))
    }

    // MARK: - Persistence

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            groups = try decoder.decode([LinkGroup].self, from: Data(contentsOf: fileURL))
        } catch CocoaError.fileReadNoSuchFile {
            return
        } catch {
            loadFailure = "链接读取失败，原文件已保留；请恢复文件后重新打开应用。"
            errorMessage = loadFailure
        }
    }

    private func commit(_ mutate: @escaping @MainActor (inout [LinkGroup]) -> Void) async -> Bool {
        guard loadFailure == nil else { errorMessage = loadFailure; return false }
        let previous = pendingWrite
        writeGeneration += 1
        let write = Task { @MainActor in
            _ = await previous?.value
            // Apply each intent to the last successful state, not an obsolete snapshot.
            var candidate = self.groups
            mutate(&candidate)
            do {
                if candidate != self.groups { try await self.writer.save(candidate) }
                self.groups = candidate
                self.errorMessage = nil
                return true
            } catch {
                self.errorMessage = "链接未能保存，请检查磁盘空间和访问权限；输入内容已保留，可重试。"
                return false
            }
        }
        pendingWrite = write
        return await write.value
    }

    func flushPendingWrites() async -> Bool {
        while true {
            let generation = writeGeneration
            let result = await pendingWrite?.value ?? true
            if generation == writeGeneration { return result }
        }
    }
}

/// Encoding legacy favicon data can be expensive. Keep it off the UI actor.
private actor LinkFileWriter {
    let fileURL: URL
    init(fileURL: URL) { self.fileURL = fileURL }
    func save(_ groups: [LinkGroup]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(groups).write(to: fileURL, options: .atomic)
    }
}
