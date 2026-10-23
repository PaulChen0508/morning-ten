import Foundation
import PDFKit

enum DocumentEvidence {
    static func headline(_ data: Data, mime: String, expected: String) -> String? {
        let title: String
        let body: String
        if mime.contains("pdf"), data.starts(with: Data("%PDF-".utf8)), let pdf = PDFDocument(data: data) {
            body = (0..<min(pdf.pageCount, 3)).compactMap { pdf.page(at: $0)?.string }.joined(separator: " ")
            title = String(body.prefix(900))
        } else {
            guard mime.contains("html"), let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
                  html.lowercased().contains("<html") || html.lowercased().contains("<article") else { return nil }
            func element(_ tag: String) -> String? {
                guard let range = html.range(of: "(?is)<" + tag + "\\b[^>]*>(.*?)</" + tag + ">", options: .regularExpression) else { return nil }
                return NewsText.clean(String(html[range]))
            }
            let pageTitle = element("title") ?? ""
            let heading = element("h1") ?? pageTitle
            let errorText = (pageTitle + " " + heading).lowercased()
            guard !["access denied", "just a moment", "page not found", "404 not found", "verify you are human", "attention required", "sign in", "log in", "service unavailable", "robot check", "页面不存在", "访问受限"].contains(where: errorText.contains) else { return nil }
            let headingRegex = try? NSRegularExpression(pattern: "(?is)<h1\\b[^>]*>(.*?)</h1>")
            let whole = html as NSString
            let headings = headingRegex?.matches(in: html, range: NSRange(location: 0, length: whole.length)).map { NewsText.clean(whole.substring(with: $0.range)) } ?? []
            title = ([pageTitle] + headings).joined(separator: " · ")
            let stripped = html.replacingOccurrences(of: "(?is)<(script|style|nav|footer|header)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            body = NewsText.clean(stripped)
        }
        guard body.count >= 150, !title.isEmpty else { return nil }
        let stop: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "into", "are", "was", "its", "has", "have", "new", "news", "press", "release", "says", "announces"]
        let words = Set(expected.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 && !stop.contains($0) })
        guard !words.isEmpty else { return nil }
        let normalizedTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let matches = words.filter { normalizedTitle.contains($0) }.count
        guard matches >= min(2, words.count), Double(matches) / Double(words.count) >= 0.45 else { return nil }
        let bodyMatches = words.filter { body.localizedCaseInsensitiveContains($0) }.count
        guard bodyMatches >= min(2, words.count) else { return nil }
        return String(title.prefix(400))
    }
}

actor LinkVerifier {
    struct Entry: Codable { let checkedAt: Date; let article: Article? }
    private var entries: [String: Entry] = [:]
    private let http: NewsHTTP
    private let authorities: [FeedSource]
    private let cacheURL: URL?

    init(http: NewsHTTP, authorities: [FeedSource], cacheURL: URL? = nil) {
        self.http = http
        self.authorities = authorities
        self.cacheURL = cacheURL
        if let cacheURL, let data = try? Data(contentsOf: cacheURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
    }

    func checked(_ article: Article, force: Bool = false) async -> Article? {
        guard ResearchPolicy.permits(article), let url = SafeURL.article(article.url),
              let authority = authorities.first(where: { $0.name == article.source && $0.owns(url) }) else { return nil }
        let key = article.url + "|" + article.title
        if !force, let entry = entries[key], Date().timeIntervalSince(entry.checkedAt) < (entry.article == nil ? 60 : 300) {
            guard var cached = entry.article else { return nil }
            cached.category = article.category
            return cached
        }
        var verified: Article?
        if let document = await http.document(url), authority.owns(document.url), ResearchPolicy.isSpecific(document.url),
           let headline = DocumentEvidence.headline(document.data, mime: document.mime, expected: article.title) {
            var value = article
            value.url = document.url.absoluteString
            value.verifiedAt = Date()
            value.evidenceTitle = headline
            verified = value
        }
        entries[key] = Entry(checkedAt: Date(), article: verified)
        return verified
    }

    func save() {
        guard let cacheURL else { return }
        entries = entries.filter { Date().timeIntervalSince($0.value.checkedAt) < 86400 }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
    }
}
