import Foundation

struct NewsCategory: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var title: String
    var icon: String
    var keywords: [String]?

    var searchTerms: [String] { (keywords ?? []).filter { !$0.isEmpty } }
    var isCustom: Bool { id.hasPrefix("custom-") }

    static func terms(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.components(separatedBy: CharacterSet(charactersIn: ",，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    func matches(_ article: Article) -> Bool {
        if searchTerms.isEmpty { return !isCustom && article.category == id }
        let text = article.title + " " + article.summary + " " + article.source
        return searchTerms.contains { term in
            if NewsText.containsChinese(term) { return text.localizedCaseInsensitiveContains(term) }
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

struct FeedSource: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let official: Bool
    let urls: [String]
    var hosts: [String]? = nil

    func owns(_ url: URL) -> Bool {
        let allowed = hosts ?? urls.compactMap { URL(string: $0)?.host }
        guard official, let host = url.host?.lowercased() else { return false }
        return allowed.contains { base in host == base || host.hasSuffix("." + base) }
    }
}

struct Catalog: Codable, Sendable {
    let categories: [NewsCategory]
    let sources: [FeedSource]

    static func load(from url: URL) throws -> Catalog {
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        let ids = Set(catalog.categories.map(\.id))
        guard ids.count == catalog.categories.count,
              Set(catalog.sources.map(\.id)).count == catalog.sources.count,
              catalog.sources.allSatisfy({ ids.contains($0.category) && !$0.urls.isEmpty && $0.urls.allSatisfy(SafeURL.isPublicFeed) }) else {
            throw NewsError.invalidCatalog
        }
        return catalog
    }
}

struct Article: Codable, Identifiable, Hashable, Sendable {
    var title: String
    var url: String
    var official: Bool
    var category: String
    var source: String
    var summary: String
    var publishedAt: Date
    var verifiedAt: Date? = nil
    var evidenceTitle: String? = nil
    var id: String { category + "|" + url }
}

struct SourceStatus: Codable, Identifiable, Sendable {
    var name: String
    var category: String
    var count: Int
    var url: String
    var official: Bool
    var checkedAt: Date
    var error: String? = nil
    var id: String { category + "|" + name }
}

// The date encoding and field names match the installed 1.1.1 application's cache.
struct NewsCache: Codable, Sendable {
    var updatedAt: Date
    var sources: [SourceStatus]
    var articles: [Article]
}

struct Preferences: Codable, Equatable {
    var days = 7
    var chinese = true
    var officialOnly = true
    var fontScale = 1.0
    var morningEnabled = false
    var hour = 8
    var minute = 0
    var timeZone = TimeZone.current.identifier
    var enabledCategories: [String] = []
}

enum NewsError: Error { case invalidCatalog, invalidFeed, badResponse, tooLarge }

struct TopicStorage {
    let url: URL
    func read(defaults: [NewsCategory]) -> [NewsCategory] {
        guard let data = try? Data(contentsOf: url), let topics = try? JSONDecoder().decode([NewsCategory].self, from: data),
              Set(topics.map(\.id)).count == topics.count else { return defaults }
        return topics
    }
    func save(_ topics: [NewsCategory]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(topics).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

enum ResearchPolicy {
    static func permits(_ article: Article) -> Bool {
        guard article.official, let url = SafeURL.article(article.url), let host = url.host else { return false }
        return !["wikipedia.org", "reddit.com", "quora.com", "news.google.com"].contains { host == $0 || host.hasSuffix("." + $0) }
            && isSpecific(url)
    }

    static func isSpecific(_ url: URL) -> Bool {
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return false }
        return !["news", "newsroom", "press", "search", "login", "signin", "rss", "feed", "en", "en/news"].contains(path)
            && !["/search", "/login", "/signin", "/captcha", "/challenge"].contains(where: { url.path.lowercased().contains($0) })
    }
}

enum SafeURL {
    static let secretNames: Set<String> = ["api_key", "apikey", "access_token", "refresh_token", "authorization", "password", "secret", "token"]

    static func article(_ text: String) -> URL? {
        guard var c = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(c.scheme?.lowercased() ?? ""),
              let host = c.host?.lowercased(), !host.isEmpty,
              c.user == nil, c.password == nil,
              host != "localhost", !host.hasSuffix(".local"),
              host != "::1", !host.hasPrefix("127."), !host.hasPrefix("10."),
              !host.hasPrefix("192.168."), !host.hasPrefix("169.254."),
              host != "0.0.0.0", !host.contains(":"), !host.hasPrefix("["),
              !(c.queryItems ?? []).contains(where: { secretNames.contains($0.name.lowercased()) }) else { return nil }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets[0] == 172, (16...31).contains(octets[1]) { return nil }
        c.scheme = "https"
        c.fragment = nil
        c.queryItems = c.queryItems?.filter {
            !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name.lowercased())
        }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        return c.url
    }

    static func isPublicFeed(_ text: String) -> Bool {
        guard text.hasPrefix("https://"), let url = article(text) else { return false }
        return url.host != nil
    }
}

enum NewsText {
    static func clean(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities = ["&amp;": "&", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&rsquo;": "’", "&lsquo;": "‘", "&ndash;": "–", "&mdash;": "—", "&hellip;": "…"]
        for (entity, replacement) in entities { value = value.replacingOccurrences(of: entity, with: replacement) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") {
            let ns = value as NSString
            for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).reversed() {
                let code = ns.substring(with: match.range(at: 1))
                let number = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: value) {
                    value.replaceSubrange(range, with: String(scalar))
                }
            }
        }
        return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
    }
}

enum ArticleSelection {
    static func recent(_ articles: [Article], days: Int, now: Date = Date()) -> [Article] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        var seen: Set<String> = []
        return articles.sorted { $0.publishedAt > $1.publishedAt }.filter {
            $0.publishedAt >= cutoff && $0.publishedAt <= now.addingTimeInterval(300)
                && !$0.title.isEmpty && SafeURL.article($0.url) != nil && seen.insert($0.id).inserted
        }
    }

    static func daily(_ articles: [Article], limit: Int = 10) -> [Article] {
        let ordered = articles.sorted { $0.publishedAt > $1.publishedAt }
        var chosen: [Article] = []
        var categories: Set<String> = []
        var links: Set<String> = []
        for article in ordered where chosen.count < limit {
            if !categories.contains(article.category) && links.insert(article.url).inserted {
                categories.insert(article.category)
                chosen.append(article)
            }
        }
        for article in ordered where chosen.count < limit {
            if links.insert(article.url).inserted { chosen.append(article) }
        }
        return chosen
    }
}

struct CacheStorage {
    let directory: URL
    var cacheURL: URL { directory.appendingPathComponent("news.json") }

    func read() -> NewsCache? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(NewsCache.self, from: data)
    }

    func save(_ cache: NewsCache) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Preserve the exact old cache once, before this version's first write.
        let backup = directory.appendingPathComponent("news-before-1.3.0.json")
        if manager.fileExists(atPath: cacheURL.path), !manager.fileExists(atPath: backup.path) {
            try manager.copyItem(at: cacheURL, to: backup)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let data = try JSONEncoder().encode(cache)
        try data.write(to: cacheURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}

func limitedMap<Input: Sendable, Output: Sendable>(_ inputs: [Input], limit: Int, operation: @escaping @Sendable (Input) async -> Output) async -> [Output] {
    guard !inputs.isEmpty else { return [] }
    return await withTaskGroup(of: Output.self) { group in
        var index = 0
        for _ in 0..<min(max(1, limit), inputs.count) {
            let input = inputs[index]
            index += 1
            group.addTask { await operation(input) }
        }
        var result: [Output] = []
        while let value = await group.next() {
            result.append(value)
            if index < inputs.count {
                let input = inputs[index]
                index += 1
                group.addTask { await operation(input) }
            }
        }
        return result
    }
}
