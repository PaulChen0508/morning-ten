import Foundation

final class RSSParser: NSObject, XMLParserDelegate {
    private let source: FeedSource
    private var current: [String: String] = [:]
    private var field = ""
    private var insideItem = false
    private var isAtom = false
    private var recognizedFeed = false
    private var entries = 0
    private var articles: [Article] = []
    private let iso = ISO8601DateFormatter()
    private let dates: [DateFormatter] = ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"].map { format in
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = format
        return f
    }

    init(source: FeedSource) { self.source = source }

    func parse(_ data: Data) throws -> [Article] {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse(), recognizedFeed else { throw NewsError.invalidFeed }
        return articles
    }

    private func date(_ value: String) -> Date? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = iso.date(from: text) { return result }
        iso.formatOptions = [.withInternetDateTime]
        if let result = iso.date(from: text) { return result }
        for formatter in dates { if let result = formatter.date(from: text) { return result } }
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = elementName.lowercased()
        if ["rss", "feed", "rdf:rdf"].contains(element) { recognizedFeed = true }
        if element == "item" || element == "entry" {
            insideItem = true
            isAtom = element == "entry"
            current = [:]
            entries += 1
        }
        guard insideItem else { return }
        let allowed = ["title", "link", "description", "summary", "content", "content:encoded", "pubdate", "published", "updated", "dc:date", "guid"]
        if allowed.contains(element) {
            field = element
            if current[element] == nil { current[element] = "" }
        }
        if isAtom, element == "link", let href = attributeDict["href"], attributeDict["rel"] == nil || attributeDict["rel"] == "alternate" {
            if current["alternateLink"] == nil { current["alternateLink"] = href }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideItem, !field.isEmpty { current[field, default: ""] += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let element = elementName.lowercased()
        if element == "item" || element == "entry" {
            let rawLink = current["alternateLink"] ?? current["link"] ?? current["guid"] ?? ""
            let rawDate = current["published"] ?? current["pubdate"] ?? current["dc:date"] ?? current["updated"] ?? ""
            let title = NewsText.clean(current["title"] ?? "")
            if let url = SafeURL.article(rawLink), let publishedAt = date(rawDate), !title.isEmpty {
                let summary = NewsText.clean(current["description"] ?? current["summary"] ?? current["content:encoded"] ?? current["content"] ?? "")
                articles.append(Article(title: title, url: url.absoluteString, official: source.official, category: source.category, source: source.name, summary: String(summary.prefix(600)), publishedAt: publishedAt))
            }
            insideItem = false
            field = ""
        } else if element == field { field = "" }
    }
}

struct FeedResult: Sendable {
    let status: SourceStatus
    let articles: [Article]
}

struct NewsHTTP: Sendable {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpAdditionalHeaders = ["User-Agent": "MorningTen/1.3 (personal RSS reader)"]
        self.session = URLSession(configuration: config)
    }

    func feed(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.setValue("application/rss+xml, application/atom+xml, application/xml, application/json, text/xml;q=0.9", forHTTPHeaderField: "Accept")
        for attempt in 0...1 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw NewsError.badResponse }
                if [408, 429, 500, 502, 503, 504].contains(http.statusCode), attempt == 0 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                guard (200...299).contains(http.statusCode), !data.isEmpty else { throw NewsError.badResponse }
                guard data.count <= 8_000_000 else { throw NewsError.tooLarge }
                return data
            } catch let error as URLError {
                if attempt == 0, [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                throw error
            }
        }
        throw NewsError.badResponse
    }

    struct Document { let data: Data; let url: URL; let mime: String }

    func document(_ url: URL) async -> Document? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8)
        request.setValue("text/html, application/pdf;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        for attempt in 0...1 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                if [408, 429, 500, 502, 503, 504].contains(http.statusCode), attempt == 0 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    continue
                }
                guard (200...299).contains(http.statusCode), !data.isEmpty, data.count <= 6_000_000,
                      let final = http.url, let safe = SafeURL.article(final.absoluteString) else { return nil }
                return Document(data: data, url: safe, mime: http.mimeType?.lowercased() ?? "")
            } catch {
                if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000); continue }
            }
        }
        return nil
    }

}

struct FeedLoader: Sendable {
    let http: NewsHTTP

    func load(_ source: FeedSource, days: Int, now: Date = Date()) async -> FeedResult? {
        guard source.official else { return nil }
        for address in source.urls {
            guard let url = URL(string: address), SafeURL.isPublicFeed(address) else { continue }
            do {
                let data = try await http.feed(url)
                let articles: [Article]
                if url.path.contains("documents.json") { articles = try federalRegister(data, source: source) }
                else { articles = try RSSParser(source: source).parse(data) }
                let recent = Array(ArticleSelection.recent(articles, days: days, now: now).filter { article in
                    guard let url = SafeURL.article(article.url) else { return false }
                    return ResearchPolicy.permits(article) && source.owns(url)
                }.prefix(30))
                let status = SourceStatus(name: source.name, category: source.category, count: recent.count, url: address, official: source.official, checkedAt: now)
                return FeedResult(status: status, articles: recent)
            } catch { continue }
        }
        // Failed feeds never become articles or visible error cards.
        return nil
    }

    private func federalRegister(_ data: Data, source: FeedSource) throws -> [Article] {
        struct Document: Decodable { let title: String; let abstract: String?; let html_url: String; let publication_date: String }
        struct Response: Decodable { let results: [Document] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return response.results.compactMap {
            guard let url = SafeURL.article($0.html_url), let date = formatter.date(from: $0.publication_date) else { return nil }
            return Article(title: NewsText.clean($0.title), url: url.absoluteString, official: true, category: source.category, source: source.name, summary: String(NewsText.clean($0.abstract ?? "").prefix(600)), publishedAt: date)
        }
    }
}
