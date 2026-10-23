import Foundation
import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import Translation

@MainActor
final class NewsStore: ObservableObject {
    let catalog: Catalog
    let storage: CacheStorage
    private let http: NewsHTTP
    private let verifier: LinkVerifier
    private let topicStorage: TopicStorage
    private var queuedRefresh = false
    private var rawArticles: [Article] = []
    @Published var categories: [NewsCategory]
    @Published var checkingArticles: Set<String> = []
    @Published var topicError = ""
    private let preferenceKey = "MorningTen.preferences.v2"
    private var ready = false
    private var timer: Timer?
    private var legacyNotificationIDs: [String] = []

    @Published var selection = "daily" { didSet { translationRevision += 1 } }
    @Published var search = "" { didSet { translationRevision += 1 } }
    @Published var articles: [Article] = []
    @Published var sources: [SourceStatus] = []
    @Published var updatedAt: Date?
    @Published var refreshing = false
    @Published var phase = ""
    @Published var offline = false
    @Published var localMessage = ""
    @Published var translationRevision = 0
    @Published var translating = false
    @Published var translations: [String: String] = [:]
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var preferences: Preferences {
        didSet {
            guard ready else { return }
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: preferenceKey) }
            translationRevision += 1
            if oldValue.days != preferences.days { Task { await refresh() } }
            if oldValue.morningEnabled != preferences.morningEnabled || oldValue.hour != preferences.hour || oldValue.minute != preferences.minute || oldValue.timeZone != preferences.timeZone {
                Task { await updateNotifications() }
            }
        }
    }

    init(catalog: Catalog, storage: CacheStorage) {
        self.catalog = catalog
        self.storage = storage
        let topics = TopicStorage(url: storage.directory.appendingPathComponent("topics-v3.json"))
        topicStorage = topics
        let loadedTopics = topics.read(defaults: catalog.categories)
        categories = loadedTopics
        let client = NewsHTTP()
        http = client
        verifier = LinkVerifier(http: client, authorities: catalog.sources, cacheURL: storage.directory.appendingPathComponent("link-health-v3.json"))
        if let data = UserDefaults.standard.data(forKey: "MorningTen.preferences.v2"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = saved
        } else {
            var initial = Preferences()
            initial.enabledCategories = loadedTopics.map(\.id)
            preferences = initial
        }
        preferences.officialOnly = true
        if let cache = storage.read() {
            // A previous successful check never makes an old cache visible at startup.
            rawArticles = cache.articles
            updatedAt = cache.updatedAt
        }
        let translationsURL = storage.directory.appendingPathComponent("translations-v2.json")
        if let data = try? Data(contentsOf: translationsURL), let saved = try? JSONDecoder().decode([String: String].self, from: data) { translations = saved }
        ready = true
    }

    func start() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        legacyNotificationIDs = pending.filter { $0.identifier != "morning-ten.daily" }.map(\.identifier)
        if UserDefaults.standard.data(forKey: preferenceKey) == nil,
           let trigger = pending.compactMap({ $0.trigger as? UNCalendarNotificationTrigger }).first {
            ready = false
            preferences.morningEnabled = true
            preferences.hour = trigger.dateComponents.hour ?? 8
            preferences.minute = trigger.dateComponents.minute ?? 0
            preferences.timeZone = trigger.dateComponents.timeZone?.identifier ?? TimeZone.current.identifier
            ready = true
            if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: preferenceKey) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.refreshing else { return }
                if Date().timeIntervalSince(self.updatedAt ?? .distantPast) > 1800 { await self.refresh() }
            }
        }
        await refresh(force: true)
    }

    var filtered: [Article] {
        let enabled = Set(preferences.enabledCategories)
        return ArticleSelection.recent(articles, days: preferences.days).filter {
            enabled.contains($0.category) && ResearchPolicy.permits($0) && $0.verifiedAt != nil
                && (search.isEmpty || ($0.title + " " + $0.summary + " " + $0.source).localizedCaseInsensitiveContains(search))
        }
    }

    var visible: [Article] {
        if selection == "daily" { return ArticleSelection.daily(filtered) }
        return Array(filtered.filter { $0.category == selection }.prefix(40))
    }

    var selectedTitle: String {
        if selection == "daily" { return "每日精选" }
        if selection == "settings" { return "时间与偏好" }
        if selection == "sources" { return "来源与状态" }
        return categories.first { $0.id == selection }?.title ?? "新闻"
    }

    func categoryTitle(_ id: String) -> String { categories.first { $0.id == id }?.title ?? id }

    private func searchSources() -> [FeedSource] {
        var result: [FeedSource] = []
        for topic in categories where preferences.enabledCategories.contains(topic.id) && !topic.searchTerms.isEmpty {
            let terms = Array(topic.searchTerms.prefix(8))
            if let base = catalog.sources.first(where: { $0.id == "federal-register" }) {
                var components = URLComponents(string: "https://www.federalregister.gov/api/v1/documents.json")!
                components.queryItems = [URLQueryItem(name: "per_page", value: "20"), URLQueryItem(name: "order", value: "newest"), URLQueryItem(name: "conditions[term]", value: terms.map { "\"" + $0 + "\"" }.joined(separator: " OR "))]
                result.append(FeedSource(id: "search-register-" + topic.id, name: base.name, category: topic.id, official: true, urls: [components.url!.absoluteString], hosts: base.hosts))
            }
            if let base = catalog.sources.first(where: { $0.id == "arxiv" }) {
                var components = URLComponents(string: "https://export.arxiv.org/api/query")!
                components.queryItems = [URLQueryItem(name: "search_query", value: terms.map { "all:\"" + $0 + "\"" }.joined(separator: " OR ")), URLQueryItem(name: "sortBy", value: "submittedDate"), URLQueryItem(name: "sortOrder", value: "descending"), URLQueryItem(name: "max_results", value: "20")]
                result.append(FeedSource(id: "search-arxiv-" + topic.id, name: base.name, category: topic.id, official: true, urls: [components.url!.absoluteString], hosts: base.hosts))
            }
        }
        return result
    }

    func refresh(force: Bool = false) async {
        guard !refreshing else { queuedRefresh = true; return }
        refreshing = true
        phase = force ? "正在重新连接并验证原文…" : "正在更新一手来源…"
        defer {
            refreshing = false
            phase = ""
            if queuedRefresh { queuedRefresh = false; Task { await refresh(force: true) } }
        }
        let days = preferences.days
        let loader = FeedLoader(http: http)
        let feeds = catalog.sources.filter(\.official) + searchSources()
        let results = await limitedMap(feeds, limit: 6) { await loader.load($0, days: days) }.compactMap { $0 }
        phase = "正在读取原文并核对文章标题…"
        // Keep recent cached candidates for retries, but publish only this round's verified documents.
        var seen: Set<String> = []
        let candidates = ArticleSelection.recent(results.flatMap(\.articles) + rawArticles, days: days)
            .filter { ResearchPolicy.permits($0) && seen.insert($0.url).inserted }
            .filter { article in categories.contains { preferences.enabledCategories.contains($0.id) && $0.matches(article) } }
        let checker = verifier
        let checked = await limitedMap(candidates, limit: 8) { article in await checker.checked(article, force: true) }.compactMap { $0 }
        rawArticles = checked
        articles = categories.flatMap { topic in
            checked.filter { topic.matches($0) }.map { article in var copy = article; copy.category = topic.id; return copy }
        }.sorted { $0.publishedAt > $1.publishedAt }
        var statuses = results.map(\.status)
        for index in statuses.indices {
            statuses[index].count = Set(checked.filter { $0.source == statuses[index].name }.map(\.url)).count
        }
        var sourceNames: Set<String> = []
        sources = statuses.filter { $0.count > 0 && sourceNames.insert($0.name).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        updatedAt = Date()
        offline = results.isEmpty
        translationRevision += 1
        saveCurrent()
        await verifier.save()
        if force { localMessage = "来源重新验证完成，已移除无法读取或无法核对的新闻。" }
    }

    private func saveCurrent() {
        do { try storage.save(NewsCache(updatedAt: updatedAt ?? Date(), sources: sources, articles: rawArticles)) }
        catch { localMessage = "当前新闻可以阅读，缓存暂未保存。" }
    }

    func recheck(_ article: Article, open: Bool = false) async {
        guard !refreshing, !checkingArticles.contains(article.url) else { return }
        checkingArticles.insert(article.url)
        defer { checkingArticles.remove(article.url) }
        let checked = await verifier.checked(article, force: true)
        if let checked {
            for index in articles.indices where articles[index].url == article.url {
                let category = articles[index].category
                articles[index] = checked
                articles[index].category = category
            }
            rawArticles = rawArticles.map { original in
                guard original.url == article.url else { return original }
                var value = checked
                value.category = original.category
                return value
            }
            if open, let url = SafeURL.article(checked.url) { NSWorkspace.shared.open(url) }
            localMessage = "原文可以访问，已重新验证。"
        } else {
            articles.removeAll { $0.url == article.url }
            rawArticles.removeAll { $0.url == article.url }
            localMessage = "这条新闻的原文无法读取或核对，已从列表移除。"
        }
        for index in sources.indices {
            sources[index].count = Set(rawArticles.filter { $0.source == sources[index].name }.map(\.url)).count
        }
        sources.removeAll { $0.count == 0 }
        saveCurrent()
        await verifier.save()
    }

    @discardableResult
    func saveTopic(_ original: NewsCategory?, title: String, keywords: String) -> Bool {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let terms = NewsCategory.terms(keywords)
        guard !name.isEmpty, name.count <= 80, keywords.count <= 4000 else { topicError = "请填写主题名称（最多 80 字）及有效关键词。"; return false }
        guard !categories.contains(where: { $0.id != original?.id && $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame }) else { topicError = "已有同名主题，请换一个名称。"; return false }
        guard original?.isCustom == false || !terms.isEmpty else { topicError = "新增主题至少需要一个检索关键词。"; return false }
        var next = categories
        var topic = original ?? NewsCategory(id: "custom-" + UUID().uuidString.lowercased(), title: name, icon: "text.magnifyingglass")
        topic.title = name
        topic.keywords = terms
        if let index = next.firstIndex(where: { $0.id == topic.id }) { next[index] = topic }
        else { next.append(topic) }
        do { try topicStorage.save(next) }
        catch { topicError = "主题未能保存，请重试。"; return false }
        categories = next
        if original == nil { preferences.enabledCategories.append(topic.id) }
        topicError = ""
        Task { await refresh(force: true) }
        return true
    }

    func deleteTopic(_ topic: NewsCategory) {
        let next = categories.filter { $0.id != topic.id }
        do { try topicStorage.save(next) }
        catch { topicError = "主题未能删除，请重试。"; return }
        categories = next
        preferences.enabledCategories.removeAll { $0 == topic.id }
        articles.removeAll { $0.category == topic.id }
        if selection == topic.id { selection = "daily"; search = "" }
        topicError = ""
    }

    func setCategory(_ id: String, enabled: Bool) {
        var selected = Set(preferences.enabledCategories)
        if enabled { selected.insert(id) } else { selected.remove(id) }
        preferences.enabledCategories = categories.map(\.id).filter { selected.contains($0) }
        if !enabled && selection == id { selection = "daily" }
        if enabled { Task { await refresh() } }
    }

    func displayTitle(_ article: Article) -> String {
        preferences.chinese ? translations[article.url + "|title"] ?? article.title : article.title
    }

    func displaySummary(_ article: Article) -> String {
        preferences.chinese ? translations[article.url + "|summary"] ?? article.summary : article.summary
    }

    func translationRequests() -> [TranslationSession.Request] {
        guard preferences.chinese else { return [] }
        return visible.prefix(20).flatMap { article -> [TranslationSession.Request] in
            [("title", article.title), ("summary", article.summary)].compactMap { field, text in
                let key = article.url + "|" + field
                guard !text.isEmpty, !NewsText.containsChinese(text), translations[key] == nil else { return nil }
                return TranslationSession.Request(sourceText: text, clientIdentifier: key)
            }
        }
    }

    func acceptTranslations(_ responses: [TranslationSession.Response]) {
        for response in responses {
            if let key = response.clientIdentifier { translations[key] = response.targetText }
        }
        let active = Set(articles.flatMap { [$0.url + "|title", $0.url + "|summary"] })
        translations = translations.filter { active.contains($0.key) }
        let url = storage.directory.appendingPathComponent("translations-v2.json")
        if let data = try? JSONEncoder().encode(translations) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    func updateNotifications() async {
        let center = UNUserNotificationCenter.current()
        if preferences.morningEnabled {
            do {
                let allowed = try await center.requestAuthorization(options: [.alert, .sound])
                guard allowed else { localMessage = "请在系统设置中允许晨间十条发送通知。"; return }
                var components = DateComponents()
                components.hour = preferences.hour
                components.minute = preferences.minute
                components.timeZone = TimeZone(identifier: preferences.timeZone) ?? .current
                let content = UNMutableNotificationContent()
                content.title = "晨间十条"
                content.body = "一杯咖啡的时间，看看你关心的世界。"
                content.sound = .default
                center.removePendingNotificationRequests(withIdentifiers: legacyNotificationIDs + ["morning-ten.daily"])
                let request = UNNotificationRequest(identifier: "morning-ten.daily", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true))
                try await center.add(request)
                legacyNotificationIDs = []
                localMessage = "晨间通知已更新。"
            } catch { localMessage = "通知设置暂未保存，请稍后再试。" }
        } else {
            center.removePendingNotificationRequests(withIdentifiers: legacyNotificationIDs + ["morning-ten.daily"])
            legacyNotificationIDs = []
        }
    }

    func testNotification() async {
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { localMessage = "请先允许通知。"; return }
            let content = UNMutableNotificationContent()
            content.title = "晨间十条 · 测试通知"
            content.body = "通知已准备好。"
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: "morning-ten.test", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)))
        } catch { localMessage = "测试通知暂未发送。" }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if enabled, !loginEnabled { localMessage = "请在系统设置的登录项中确认。" }
        } catch { localMessage = "可在系统设置的登录项中管理晨间十条。" }
    }
}
