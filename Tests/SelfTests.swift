import Foundation

enum TestFailure: Error { case failed(String) }

final class FakeNewsProtocol: URLProtocol {
    struct Reply { var status: Int; var data: Data; var mime: String = "text/html"; var final: String? = nil }
    static let lock = NSLock()
    static var replies: [String: [Reply]] = [:]
    static var requests: [String: Int] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.lock.lock()
        let index = Self.requests[path, default: 0]
        Self.requests[path] = index + 1
        let options = Self.replies[path] ?? [Reply(status: 404, data: Data())]
        let reply = options[min(index, options.count - 1)]
        Self.lock.unlock()
        let response = HTTPURLResponse(url: reply.final.flatMap(URL.init(string:)) ?? request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct SelfTests {
    static func main() async throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw TestFailure.failed(message) }
            count += 1
        }
        let now = Date()
        let source = FeedSource(id: "original", name: "Original Publisher", category: "science", official: true, urls: ["https://example.com/feed"], hosts: ["example.com"])
        var story = Article(title: "Lunar mission discovers water deposits", url: "https://example.com/story", official: true, category: "science", source: source.name, summary: "Mission team reports lunar water observations.", publishedAt: now)
        let html = Data(("<html><head><title>Lunar mission discovers water deposits | Publisher</title></head><body><article><h1>Lunar mission discovers water deposits</h1><p>" + String(repeating: "The mission team describes original measurements of lunar water deposits. ", count: 8) + "</p></article></body></html>").utf8)
        let multiHeading = Data(String(decoding: html, as: UTF8.self).replacingOccurrences(of: "<title>Lunar mission discovers water deposits | Publisher</title>", with: "<title>Original Publisher</title>").replacingOccurrences(of: "<article>", with: "<article><h1>Computer Science</h1>").utf8)
        try expect(DocumentEvidence.headline(multiHeading, mime: "text/html", expected: story.title) != nil, "A subject heading must not hide the original paper title")
        let denied = Data("<html><head><title>Just a moment...</title></head><body>Verify you are human</body></html>".utf8)
        let soft404 = Data(("<html><head><title>Page not found</title></head><body>" + String(repeating: "Lunar mission discovers water deposits ", count: 8) + "</body></html>").utf8)
        try expect(DocumentEvidence.headline(html, mime: "text/html", expected: story.title) != nil, "Read the original article before displaying it")
        try expect(DocumentEvidence.headline(denied, mime: "text/html", expected: story.title) == nil, "HTTP 200 challenge pages are not evidence")
        try expect(DocumentEvidence.headline(soft404, mime: "text/html", expected: story.title) == nil, "HTTP 200 error pages are not evidence")
        try expect(DocumentEvidence.headline(html, mime: "text/html", expected: "Interest rates fall after inflation report") == nil, "A working page about another topic is not the cited article")
        try expect(DocumentEvidence.headline(Data(), mime: "text/html", expected: story.title) == nil, "Empty successful responses are not articles")
        let substringPage = Data(("<html><head><title>Sublunary watering corporate</title></head><body>" + String(repeating: "Sublunary watering corporate reports. ", count: 10) + "</body></html>").utf8)
        try expect(DocumentEvidence.headline(substringPage, mime: "text/html", expected: "Lunar water rate") == nil, "Substrings inside unrelated words must not validate a headline")
        try expect(!ResearchPolicy.isSpecific(URL(string: "https://example.com/")!), "Publisher homepage cannot replace an article")
        try expect(!ResearchPolicy.isSpecific(URL(string: "https://example.com/search?q=moon")!), "Search results cannot replace a source")
        try expect(!source.owns(URL(string: "https://example.com.evil.test/story")!), "Publisher ownership uses host boundaries")
        try expect(source.owns(URL(string: "https://news.example.com/story")!), "Publisher-owned subdomains are accepted")
        var secondary = story; secondary.official = false
        try expect(!ResearchPolicy.permits(secondary), "Do not quietly substitute secondary sources")
        secondary = story; secondary.url = "https://en.wikipedia.org/wiki/Moon"
        try expect(!ResearchPolicy.permits(secondary), "Research prohibited sources cannot be shown")
        try expect(SafeURL.article("https://127.0.0.1/private") == nil && SafeURL.article("https://example.com/a?api_key=secret") == nil, "Reject private and credential-bearing source URLs")

        let terms = NewsCategory.terms("SpaceX, commercial space；商业航天\nSPACEX")
        try expect(terms == ["SpaceX", "commercial space", "商业航天"], "Normalize bilingual keywords and remove duplicates")
        let topic = NewsCategory(id: "custom-space", title: "商业航天", icon: "sparkles", keywords: ["lunar water", "商业航天"])
        story.summary = "Original lunar water observations."
        try expect(topic.matches(story), "Custom keywords retrieve matching original publications")
        let ai = NewsCategory(id: "custom-ai", title: "AI", icon: "sparkles", keywords: ["AI"])
        var noise = story; noise.title = "Chair said something"; noise.summary = ""; noise.source = "Publisher"
        try expect(!ai.matches(noise), "AI keyword must not match chair or said")
        noise.title = "AI research announcement"
        try expect(ai.matches(noise), "Short keywords match full words")
        let defaults = NewsCategory(id: "science", title: "Science", icon: "moon")
        try expect(defaults.matches(story), "A preset with no keywords keeps its existing category rule")

        let protected = ProtectedText("NVIDIA announces GPU chips with OpenAI and SpaceX.")
        try expect(!protected.masked.contains("NVIDIA") && !protected.masked.contains("OpenAI") && !protected.masked.contains("GPU"), "Company names and acronyms are masked before system translation")
        let translated = protected.masked.replacingOccurrences(of: "announces", with: "发布").replacingOccurrences(of: "chips with", with: "芯片，合作伙伴包括").replacingOccurrences(of: " and ", with: " 和 ")
        let restored = protected.restore(translated)
        try expect(restored?.contains("NVIDIA") == true && restored?.contains("GPU") == true && restored?.contains("OpenAI") == true && restored?.contains("SpaceX") == true, "Restore protected names exactly while translating ordinary text")
        try expect(protected.restore("英伟达发布了芯片") == nil, "Reject a translation that loses protected terminology")
        let marker = protected.replacements[0].marker
        try expect(protected.restore(translated + marker) == nil, "Reject duplicate translation markers")
        let repeated = ProtectedText("Nvidia and NVIDIA use GPU. NVIDIA grows.")
        try expect(repeated.restore(repeated.masked) == repeated.original, "Repeated names preserve their original spelling and capitalization")
        let customTerm = ProtectedText("A Dragonfly-7 satellite enters orbit.", additionalTerms: "Dragonfly-7")
        try expect(!customTerm.masked.contains("Dragonfly-7") && customTerm.restore(customTerm.masked) == customTerm.original, "Protect user-defined technical terms")
        let shortTerm = ProtectedText("AI should not match chair.")
        try expect(shortTerm.masked.contains("chair"), "Protect acronyms only at word boundaries")
        let chineseCompany = ProtectedText("英伟达发布了新的芯片。")
        try expect(chineseCompany.restore(chineseCompany.masked) == chineseCompany.original && !chineseCompany.masked.contains("英伟达"), "Keep company names in their original script")
        let oldPreferences = try JSONDecoder().decode(Preferences.self, from: Data("{\"days\":14,\"chinese\":false,\"fontScale\":1.2,\"enabledCategories\":[\"ai\",\"ai\"]}".utf8))
        try expect(oldPreferences.language == .english && oldPreferences.days == 14 && oldPreferences.fontScale == 1.2 && oldPreferences.enabledCategories == ["ai"], "Migrate old preferences without losing reading settings")
        let newPreferences = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(oldPreferences))
        try expect(newPreferences == oldPreferences, "Save and restore the new language preferences")
        let invalidPreferences = try JSONDecoder().decode(Preferences.self, from: Data("{\"days\":999,\"hour\":99,\"minute\":-2,\"fontScale\":100}".utf8))
        try expect(invalidPreferences.days == 7 && invalidPreferences.hour == 23 && invalidPreferences.minute == 0 && invalidPreferences.fontScale == 1.5, "Clamp malformed saved settings to valid UI ranges")
        let key = TranslationText.cacheKey(url: story.url, field: "title", text: "Old title", target: "zh-Hans", glossary: "")
        try expect(key != TranslationText.cacheKey(url: story.url, field: "title", text: "New title", target: "zh-Hans", glossary: ""), "A changed article at the same URL must not reuse an old translation")
        try expect(key != TranslationText.cacheKey(url: story.url, field: "title", text: "Old title", target: "en", glossary: ""), "Translations are isolated by target language")
        try expect(key != TranslationText.cacheKey(url: story.url, field: "title", text: "Old title", target: "zh-Hans", glossary: "title"), "Changing protected terms invalidates affected translation cache entries")
        try expect(TranslationText.language(of: "The company announced a new research program today.") == "en" && TranslationText.language(of: "今天发布了一项新的科学研究，介绍了最新的实验结果。") == "zh-Hans", "Detect English and Chinese article text for two-way translation")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MorningTen-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let topics = TopicStorage(url: directory.appendingPathComponent("topics.json"))
        try topics.save([topic])
        try expect(topics.read(defaults: [defaults]) == [topic], "New and edited topics survive relaunch")
        try topics.save([])
        try expect(topics.read(defaults: [defaults]).isEmpty, "Deleting every topic must not restore defaults on relaunch")
        let legacy = Data("{\"updatedAt\":100,\"sources\":[],\"articles\":[{\"title\":\"Existing news\",\"url\":\"https://example.com/existing\",\"official\":true,\"category\":\"science\",\"source\":\"Publisher\",\"summary\":\"Existing summary\",\"publishedAt\":90}]}".utf8)
        let storage = CacheStorage(directory: directory)
        try legacy.write(to: storage.cacheURL)
        try expect(storage.read()?.articles.first?.verifiedAt == nil, "Old unverified cache entries do not acquire verification")
        try storage.save(NewsCache(updatedAt: now, sources: [], articles: [story]))
        let backup = try Data(contentsOf: directory.appendingPathComponent("news-before-1.3.0.json"))
        try expect(backup == legacy, "Preserve an exact backup of the existing cache")

        let iso = ISO8601DateFormatter().string(from: now.addingTimeInterval(-30))
        let rss = Data("<rss><channel><item><title>Lunar mission discovers water deposits</title><link>https://example.com/story?utm_source=rss</link><pubDate>\(iso)</pubDate><description>Original observations</description></item><item><title>Undated</title><link>https://example.com/undated</link></item></channel></rss>".utf8)
        let parsed = try RSSParser(source: source).parse(rss)
        try expect(parsed.count == 1 && parsed[0].url == story.url, "Exclude undated entries and remove tracking parameters")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeNewsProtocol.self]
        let http = NewsHTTP(session: URLSession(configuration: config))
        FakeNewsProtocol.replies = [
            "/story": [.init(status: 200, data: html), .init(status: 200, data: denied)],
            "/repair": [.init(status: 404, data: Data()), .init(status: 200, data: html)],
            "/redirect": [.init(status: 200, data: html, final: "https://example.com/")],
            "/external": [.init(status: 200, data: html, final: "https://unrelated.test/story")],
            "/retry": [.init(status: 503, data: Data()), .init(status: 200, data: html)],
            "/feed": [.init(status: 200, data: rss, mime: "application/rss+xml")],
            "/missing": [.init(status: 404, data: Data())]
        ]
        let checker = LinkVerifier(http: http, authorities: [source])
        let first = await checker.checked(story)
        let cached = await checker.checked(story)
        try expect(first?.verifiedAt != nil && cached != nil && FakeNewsProtocol.requests["/story"] == 1, "Cache only successful document checks")
        let broken = await checker.checked(story, force: true)
        try expect(broken == nil && FakeNewsProtocol.requests["/story"] == 2, "Manual retry bypasses positive cache and removes now-broken pages")
        story.url = "https://example.com/repair"
        let missing = await checker.checked(story)
        let repaired = await checker.checked(story, force: true)
        try expect(missing == nil && repaired != nil, "Manual retry bypasses negative cache and recovers a repaired original")
        story.url = "https://example.com/redirect"
        let homepage = await checker.checked(story, force: true)
        try expect(homepage == nil, "Reject a successful redirect to the publisher homepage")
        story.url = "https://example.com/external"
        let external = await checker.checked(story, force: true)
        try expect(external == nil, "Reject redirects outside the original publisher")
        story.url = "https://example.com/retry"
        let retry = await checker.checked(story, force: true)
        try expect(retry != nil && FakeNewsProtocol.requests["/retry"] == 2, "Retry a transient server failure before dropping the article")
        let loader = FeedLoader(http: http)
        let fallback = await loader.load(FeedSource(id: "fallback", name: source.name, category: "science", official: true, urls: ["https://example.com/missing", "https://example.com/feed"]), days: 7)
        try expect(fallback?.articles.count == 1, "Try the next official feed endpoint after a failure")
        let secondaryFeed = await loader.load(FeedSource(id: "secondary", name: "Media", category: "science", official: false, urls: ["https://example.com/feed"]), days: 7)
        try expect(secondaryFeed == nil, "No secondary feed can silently enter the official publication pool")
        let catalog = try Catalog.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        try expect(catalog.categories.count == 21 && catalog.sources.allSatisfy(\.official), "Keep preset topics and enforce the first-party source catalog")
        try expect(!catalog.sources.contains { $0.name.contains("BBC") || $0.name.contains("Guardian") }, "Do not label media summaries as original evidence")
        print("PASS: \(count) checks — topic persistence, keyword matching, original documents, forced retries, dead links and cache compatibility")
    }
}
