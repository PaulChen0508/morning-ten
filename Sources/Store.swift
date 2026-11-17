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
    private let defaults: UserDefaults
    private let http: NewsHTTP
    private let verifier: LinkVerifier
    private let topicStorage: TopicStorage
    private var queuedRefresh = false
    private var rawArticles: [Article] = []
    private var failedTranslations: Set<String> = []
    private var unavailableTranslationPairs: Set<String> = []
    private var activeTranslationID: UUID?
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
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: preferenceKey) }
            translationRevision += 1
            if oldValue.language != preferences.language || oldValue.translateArticles != preferences.translateArticles || oldValue.protectedTerms != preferences.protectedTerms {
                failedTranslations = []
                unavailableTranslationPairs = []
            }
            if oldValue.language != preferences.language {
                NotificationCenter.default.post(name: .morningTenLanguageChanged, object: nil)
                if preferences.morningEnabled { Task { await updateNotifications() } }
            }
            if oldValue.days != preferences.days { Task { await refresh() } }
            if oldValue.morningEnabled != preferences.morningEnabled || oldValue.hour != preferences.hour || oldValue.minute != preferences.minute || oldValue.timeZone != preferences.timeZone {
                Task { await updateNotifications() }
            }
        }
    }

    init(catalog: Catalog, storage: CacheStorage, defaults: UserDefaults = .standard) {
        self.catalog = catalog
        self.storage = storage
        self.defaults = defaults
        let topics = TopicStorage(url: storage.directory.appendingPathComponent("topics-v3.json"))
        topicStorage = topics
        let loadedTopics = topics.read(defaults: catalog.categories)
        categories = loadedTopics
        let client = NewsHTTP()
        http = client
        verifier = LinkVerifier(http: client, authorities: catalog.sources, cacheURL: storage.directory.appendingPathComponent("link-health-v3.json"))
        if let data = defaults.data(forKey: "MorningTen.preferences.v2"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
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
        let translationsURL = storage.directory.appendingPathComponent("translations-v3.json")
        if let data = try? Data(contentsOf: translationsURL), let saved = try? JSONDecoder().decode([String: String].self, from: data) { translations = saved }
        ready = true
    }

    func start() async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        legacyNotificationIDs = pending.filter { $0.identifier != "morning-ten.daily" }.map(\.identifier)
        if defaults.data(forKey: preferenceKey) == nil,
           let trigger = pending.compactMap({ $0.trigger as? UNCalendarNotificationTrigger }).first {
            ready = false
            preferences.morningEnabled = true
            preferences.hour = trigger.dateComponents.hour ?? 8
            preferences.minute = trigger.dateComponents.minute ?? 0
            preferences.timeZone = trigger.dateComponents.timeZone?.identifier ?? TimeZone.current.identifier
            ready = true
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: preferenceKey) }
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
        eligible.filter { article in
            search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                [article.title, article.summary, article.source, displayTitle(article), displaySummary(article)].joined(separator: " ").localizedCaseInsensitiveContains(search.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private var eligible: [Article] {
        let enabled = Set(preferences.enabledCategories)
        return ArticleSelection.recent(articles, days: preferences.days).filter {
            enabled.contains($0.category) && ResearchPolicy.permits($0) && $0.verifiedAt != nil
        }
    }

    var visible: [Article] {
        if selection == "daily" { return ArticleSelection.daily(filtered) }
        return Array(filtered.filter { $0.category == selection }.prefix(40))
    }

    var selectedTitle: String {
        if selection == "daily" { return text("每日精选", "Today") }
        if selection == "settings" { return text("设置", "Settings") }
        if selection == "sources" { return text("来源", "Sources") }
        return categoryTitle(selection)
    }

    var language: AppLanguage { preferences.language.resolved }
    var locale: Locale { language.locale }
    func text(_ chinese: String, _ english: String) -> String { language.text(chinese, english) }
    func categoryTitle(_ id: String) -> String {
        guard let topic = categories.first(where: { $0.id == id }) else { return text("新闻", "News") }
        if language == .english, !topic.isCustom, catalog.categories.first(where: { $0.id == id })?.title == topic.title {
            return PresetTitles.english[id] ?? topic.title
        }
        return topic.title
    }

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
        guard !refreshing, checkingArticles.isEmpty else { queuedRefresh = true; return }
        refreshing = true
        phase = force ? "正在重新连接并验证原文…" : "正在更新一手来源…"
        defer {
            refreshing = false
            phase = ""
            if queuedRefresh { queuedRefresh = false; Task { await refresh(force: true) } }
        }
        let days = preferences.days
        guard !preferences.enabledCategories.isEmpty else {
            articles = []; sources = []; updatedAt = Date(); offline = false
            localMessage = "请先添加或开启一个关注主题。"
            return
        }
        let loader = FeedLoader(http: http)
        let hasKeywordTopics = categories.contains { preferences.enabledCategories.contains($0.id) && !$0.searchTerms.isEmpty }
        let feeds = catalog.sources.filter { $0.official && (hasKeywordTopics || preferences.enabledCategories.contains($0.category)) } + searchSources()
        let results = await limitedMap(feeds, limit: 6) { await loader.load($0, days: days) }.compactMap { $0 }
        phase = "正在读取原文并核对文章标题…"
        // Keep recent cached candidates for retries, but publish only this round's verified documents.
        var seen: Set<String> = []
        let candidates = ArticleSelection.recent(results.flatMap(\.articles) + rawArticles, days: days)
            .filter { ResearchPolicy.permits($0) && seen.insert($0.url).inserted }
            .filter { article in categories.contains { preferences.enabledCategories.contains($0.id) && $0.matches(article) } }
        let checker = verifier
        let verified = await limitedMap(candidates, limit: 8) { article in await checker.checked(article, force: force) }.compactMap { $0 }
        var canonicalLinks: Set<String> = []
        let checked = verified.sorted { $0.publishedAt > $1.publishedAt }.filter { canonicalLinks.insert($0.url).inserted }
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
        failedTranslations = []
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
        defer {
            checkingArticles.remove(article.url)
            if checkingArticles.isEmpty, queuedRefresh { queuedRefresh = false; Task { await refresh(force: true) } }
        }
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

    private func translationKey(_ article: Article, field: String, content: String, target: String? = nil) -> String {
        TranslationText.cacheKey(url: article.url, field: field, text: content, target: target ?? language.rawValue, glossary: preferences.protectedTerms)
    }

    func displayTitle(_ article: Article) -> String {
        preferences.translateArticles ? translations[translationKey(article, field: "title", content: article.title)] ?? article.title : article.title
    }

    func displaySummary(_ article: Article) -> String {
        preferences.translateArticles ? translations[translationKey(article, field: "summary", content: article.summary)] ?? article.summary : article.summary
    }

    func nextTranslationBatch() -> TranslationBatch? {
        guard preferences.translateArticles, selection != "settings", selection != "sources" else { return nil }
        let scope = selection == "daily" ? eligible : eligible.filter { $0.category == selection }
        let candidates = search.isEmpty && selection == "daily" ? ArticleSelection.daily(scope) : Array(scope.prefix(search.isEmpty ? 40 : 160))
        var pending: [TranslationWork] = []
        var seen: Set<String> = []
        for article in candidates {
            for (field, content) in [("title", article.title), ("summary", article.summary)] where !content.isEmpty {
                let key = translationKey(article, field: field, content: content)
                guard translations[key] == nil, !failedTranslations.contains(key), seen.insert(key).inserted else { continue }
                let source = TranslationText.language(of: content)
                guard source != language.rawValue, !unavailableTranslationPairs.contains(source + "|" + language.rawValue) else { continue }
                pending.append(TranslationWork(key: key, sourceLanguage: source, targetLanguage: language.rawValue, text: ProtectedText(content, additionalTerms: preferences.protectedTerms)))
            }
        }
        guard let first = pending.first else { return nil }
        return TranslationBatch(sourceLanguage: first.sourceLanguage, targetLanguage: first.targetLanguage, items: Array(pending.filter { $0.sourceLanguage == first.sourceLanguage }.prefix(20)))
    }

    var hasTranslationFailures: Bool { failedTranslations.contains { $0.hasPrefix(language.rawValue + "|") } || unavailableTranslationPairs.contains { $0.hasSuffix("|" + language.rawValue) } }
    func retryTranslations() { failedTranslations = []; unavailableTranslationPairs = []; translationRevision += 1 }
    func beginTranslation(_ batch: TranslationBatch) { activeTranslationID = batch.id; translating = true }
    func finishTranslation(_ batch: TranslationBatch) {
        guard activeTranslationID == batch.id else { return }
        activeTranslationID = nil; translating = false
    }

    func acceptTranslations(_ responses: [TranslationSession.Response], batch: TranslationBatch) {
        let byKey = Dictionary(responses.compactMap { response in response.clientIdentifier.map { ($0, response.targetText) } }, uniquingKeysWith: { _, newest in newest })
        acceptTranslationResults(byKey, batch: batch)
    }

    func acceptTranslationResults(_ byKey: [String: String], batch: TranslationBatch) {
        for work in batch.items {
            if let response = byKey[work.key], let restored = work.text.restore(response) { translations[work.key] = restored }
            else { failedTranslations.insert(work.key) }
        }
        let active = Set(articles.flatMap { article in [AppLanguage.chinese, .english].flatMap { target in
            [translationKey(article, field: "title", content: article.title, target: target.rawValue), translationKey(article, field: "summary", content: article.summary, target: target.rawValue)]
        } })
        translations = translations.filter { active.contains($0.key) }
        let url = storage.directory.appendingPathComponent("translations-v3.json")
        if let data = try? JSONEncoder().encode(translations) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        translationRevision += 1
    }

    func translationFailed(_ batch: TranslationBatch) {
        unavailableTranslationPairs.insert(batch.sourceLanguage + "|" + batch.targetLanguage)
        failedTranslations.formUnion(batch.items.map(\.key))
        translationRevision += 1
    }

    var notice: String { localizedStatus(localMessage) }
    var phaseLabel: String { localizedStatus(phase) }
    var topicErrorLabel: String { localizedStatus(topicError) }
    private func localizedStatus(_ value: String) -> String {
        guard language == .english else { return value }
        return [
            "正在重新连接并验证原文…": "Reconnecting to original sources…", "正在更新一手来源…": "Updating primary sources…", "正在读取原文并核对文章标题…": "Reading originals and checking headlines…",
            "来源重新验证完成，已移除无法读取或无法核对的新闻。": "Sources checked. Unavailable articles have been removed.", "当前新闻可以阅读，缓存暂未保存。": "News is available, but the cache could not be saved.",
            "原文可以访问，已重新验证。": "Original source verified.", "这条新闻的原文无法读取或核对，已从列表移除。": "The original could not be verified. This article was removed.", "请先添加或开启一个关注主题。": "Add or enable a topic to get started.",
            "请填写主题名称（最多 80 字）及有效关键词。": "Enter a topic name (up to 80 characters) and valid keywords.", "已有同名主题，请换一个名称。": "A topic with this name already exists.", "新增主题至少需要一个检索关键词。": "Add at least one search keyword.", "主题未能保存，请重试。": "The topic could not be saved. Try again.", "主题未能删除，请重试。": "The topic could not be deleted. Try again.",
            "请在系统设置中允许晨间十条发送通知。": "Allow Morning Ten notifications in System Settings.", "晨间通知已更新。": "Your morning reminder has been updated.", "通知设置暂未保存，请稍后再试。": "Reminder settings could not be saved. Try again.", "请先允许通知。": "Allow notifications first.", "测试通知暂未发送。": "The test notification could not be sent.", "请在系统设置的登录项中确认。": "Confirm Morning Ten in System Settings > Login Items.", "可在系统设置的登录项中管理晨间十条。": "Manage Morning Ten in System Settings > Login Items."
        ][value] ?? value
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
                content.title = text("晨间十条", "Morning Ten")
                content.body = text("看看今天值得关注的世界。", "Your daily perspective is ready.")
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
            content.title = text("晨间十条 · 测试通知", "Morning Ten · Test reminder")
            content.body = text("通知已准备好。", "Your reminders are ready.")
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
