import SwiftUI
import AppKit
import UserNotifications
import Translation

private let pine = Color(red: 0.15, green: 0.35, blue: 0.32)
private let cream = Color(red: 0.97, green: 0.96, blue: 0.93)
private let peach = Color(red: 0.91, green: 0.64, blue: 0.49)

private struct TopicDraft: Identifiable { let id = UUID(); let topic: NewsCategory? }

@main
struct MorningTenMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var store: NewsStore?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let manifest = Bundle.main.url(forResource: "feeds", withExtension: "json"),
              let catalog = try? Catalog.load(from: manifest) else {
            let alert = NSAlert()
            alert.messageText = "晨间十条的新闻配置未能加载。"
            alert.informativeText = "请重新安装完整的应用。原有本地数据仍保留在电脑上。"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MorningTen", isDirectory: true)
        let directory = ProcessInfo.processInfo.environment["MORNINGTEN_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
        let model = NewsStore(catalog: catalog, storage: CacheStorage(directory: directory))
        store = model
        let root = DashboardView(store: model)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        main.title = "晨间十条"
        main.minSize = NSSize(width: 980, height: 640)
        main.isReleasedWhenClosed = false
        main.contentView = NSHostingView(rootView: root)
        main.setFrameAutosaveName("MorningTenDashboard")
        if !main.setFrameUsingName("MorningTenDashboard") { main.center() }
        window = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "晨间十条")
        let menu = NSMenu()
        let open = menu.addItem(withTitle: "打开晨间十条", action: #selector(showDashboard), keyEquivalent: "")
        open.target = self
        let refresh = menu.addItem(withTitle: "刷新新闻", action: #selector(refreshNews), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出晨间十条", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        UNUserNotificationCenter.current().delegate = self
        showDashboard()
        Task { await model.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    @objc func showDashboard() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func refreshNews() { Task { await store?.refresh() } }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.store?.selection = "daily"; self.showDashboard() }
    }
}

@MainActor
struct DashboardView: View {
    @ObservedObject var store: NewsStore
    @State private var topicDraft: TopicDraft?
    @State private var translationConfig: TranslationSession.Configuration?

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 225)
            VStack(spacing: 0) {
                toolbar
                Divider().opacity(0.5)
                if store.selection == "settings" { preferences }
                else if store.selection == "sources" { sources }
                else { news }
            }
        }
        .background(cream)
        .font(.system(size: 14 * store.preferences.fontScale))
        .preferredColorScheme(.light)
        .translationTask(translationConfig) { session in
            let requests = store.translationRequests()
            guard !requests.isEmpty else { return }
            store.translating = true
            defer { store.translating = false }
            do { store.acceptTranslations(try await session.translations(from: requests)) }
            catch { /* Original text remains readable if translation is unavailable. */ }
        }
        .sheet(item: $topicDraft) { draft in
            TopicEditor(store: store, topic: draft.topic)
        }
        .onAppear { configureTranslation() }
        .onChange(of: store.translationRevision) { _, _ in configureTranslation() }
    }

    private func configureTranslation() {
        guard store.preferences.chinese, !store.translationRequests().isEmpty else { return }
        if translationConfig == nil { translationConfig = .init(source: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "zh-Hans")) }
        else { translationConfig?.invalidate() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "sun.max.fill").font(.system(size: 28)).foregroundStyle(peach)
                VStack(alignment: .leading, spacing: 5) {
                    Text("晨间十条").font(.system(size: 22, weight: .semibold, design: .serif))
                    Text("YOUR DAILY PERSPECTIVE").font(.system(size: 8, weight: .medium)).tracking(1.1).opacity(0.6)
                }
            }.padding(.horizontal, 21).padding(.top, 30).padding(.bottom, 28)
            nav("每日精选", id: "daily", icon: "sun.horizon.fill")
            Text("关注的世界").font(.system(size: 11, weight: .medium)).opacity(0.5).padding(.leading, 23).padding(.top, 24).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(store.categories.filter { store.preferences.enabledCategories.contains($0.id) }) { category in
                        nav(category.title, id: category.id, icon: category.icon)
                    }
                }.padding(.bottom, 10)
            }
            Divider().overlay(Color.white.opacity(0.15)).padding(.horizontal, 19)
            VStack(spacing: 4) {
                nav("时间与偏好", id: "settings", icon: "slider.horizontal.3")
                nav("来源与状态", id: "sources", icon: "checkmark.shield")
            }.padding(.vertical, 13)
            Text("1.3.0  ·  \(store.categories.count) 个新闻领域").font(.system(size: 10)).opacity(0.4).padding(.leading, 24).padding(.bottom, 17)
        }.foregroundStyle(.white).background(pine)
    }

    private func nav(_ title: String, id: String, icon: String) -> some View {
        Button { store.selection = id; store.search = "" } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).frame(width: 19)
                Text(title).font(.system(size: 12.5 * store.preferences.fontScale))
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).padding(.vertical, 10)
                .background(store.selection == id ? Color.white.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.horizontal, 10)
    }

    private var toolbar: some View {
        HStack {
            Text("你的每日新闻空间").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            Button { store.preferences.fontScale = max(0.85, store.preferences.fontScale - 0.05) } label: { Image(systemName: "textformat.size.smaller") }.help("缩小文字")
            Text("\(Int((store.preferences.fontScale * 100).rounded()))%").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 37)
            Button { store.preferences.fontScale = min(1.5, store.preferences.fontScale + 0.05) } label: { Image(systemName: "textformat.size.larger") }.help("放大文字")
            Divider().frame(height: 16).padding(.horizontal, 7)
            if store.refreshing { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: { Label("刷新新闻", systemImage: "arrow.clockwise") }.disabled(store.refreshing || !store.checkingArticles.isEmpty)
            Button { Task { await store.refresh(force: true) } } label: { Label("重新验证来源", systemImage: "checkmark.shield") }.disabled(store.refreshing || !store.checkingArticles.isEmpty)
                .help("重新连接原文，跳过旧验证缓存；无法读取的新闻将被移除")
        }.buttonStyle(.borderless).padding(.horizontal, 30).padding(.vertical, 16)
    }

    private var news: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(Date(), format: .dateTime.month(.wide).day().weekday(.wide)).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(store.selection == "daily" ? "早安，世界。" : store.selectedTitle).font(.system(size: 36, weight: .medium, design: .serif)).foregroundStyle(pine)
                        Text("一杯咖啡的时间，看看你关心的世界。").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "sun.horizon.fill").font(.system(size: 43, weight: .light)).foregroundStyle(peach).padding(.top, 14)
                }
                HStack(spacing: 24) {
                    metric("\(store.visible.count)", "条可阅读新闻", icon: "newspaper")
                    metric("\(store.preferences.days)", "天内发布", icon: "calendar")
                    metric("\(Set(store.filtered.map(\.category)).count)", "个活跃领域", icon: "square.grid.2x2")
                    Spacer()
                }.padding(18).background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Image(systemName: store.offline ? "wifi.slash" : "checkmark.circle.fill").foregroundStyle(pine)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if store.translating { Text("正在准备中文摘要…").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                if !store.localMessage.isEmpty { Text(store.localMessage).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled) }
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索新闻、来源或关键词", text: $store.search).textFieldStyle(.plain)
                    if !store.search.isEmpty { Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
                }.padding(11).background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
                if store.visible.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: store.refreshing ? "arrow.clockwise" : "newspaper").font(.system(size: 33, weight: .light)).foregroundStyle(pine.opacity(0.55))
                        Text(store.refreshing ? "正在整理可阅读的新闻" : "这个领域暂时没有最近的可访问新闻").font(.system(size: 15)).foregroundStyle(pine)
                        Text("不以旧新闻补齐，也不显示失效内容。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 65)
                } else {
                    LazyVStack(spacing: 15) {
                        ForEach(Array(store.visible.enumerated()), id: \.element.id) { index, article in
                            articleCard(article, index: index + 1)
                        }
                    }
                }
            }.padding(30)
        }
    }

    private var statusText: String {
        if store.refreshing { return store.phase }
        if store.offline { return "来源暂时无法更新；仅显示本轮可以重新读取的原文" }
        if let date = store.updatedAt { return "更新于 \(date.formatted(date: .omitted, time: .shortened)) · 自动跳过不可用来源和文章" }
        return "准备新闻中"
    }

    private func metric(_ value: String, _ label: String, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 20, weight: .light)).foregroundStyle(pine.opacity(0.7))
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.system(size: 20, weight: .medium, design: .serif)).foregroundStyle(pine)
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func articleCard(_ article: Article, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(format: "%02d", index)).font(.system(size: 13, weight: .medium, design: .monospaced)).foregroundStyle(peach)
                Text(store.categoryTitle(article.category)).font(.system(size: 10, weight: .semibold)).foregroundStyle(pine)
                Spacer()
                Text(article.publishedAt, format: .dateTime.month(.twoDigits).day(.twoDigits)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Button { openArticle(article) } label: {
                Text(store.displayTitle(article)).font(.system(size: 19 * store.preferences.fontScale, weight: .medium)).foregroundStyle(pine).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).disabled(store.refreshing || store.checkingArticles.contains(article.url))
            if !article.summary.isEmpty {
                Text(store.displaySummary(article)).font(.system(size: 12.5 * store.preferences.fontScale)).foregroundStyle(.secondary).lineSpacing(5).lineLimit(5).textSelection(.enabled)
            }
            HStack {
                Image(systemName: article.official ? "checkmark.seal" : "newspaper").foregroundStyle(pine.opacity(0.65))
                Button { openArticle(article) } label: { Text(article.source + " · 一手发布").underline() }.buttonStyle(.plain).foregroundStyle(pine)
                    .disabled(store.refreshing || store.checkingArticles.contains(article.url))
                Spacer()
                if store.checkingArticles.contains(article.url) { ProgressView().controlSize(.mini) }
                Button { Task { await store.recheck(article) } } label: { Label("重试来源", systemImage: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(pine)
                    .disabled(store.refreshing || store.checkingArticles.contains(article.url))
                Button { openArticle(article) } label: { Label("阅读原文", systemImage: "arrow.up.right") }.buttonStyle(.plain).foregroundStyle(pine)
                    .disabled(store.refreshing || store.checkingArticles.contains(article.url))
            }.font(.system(size: 10))
            if let checked = article.verifiedAt, let host = URL(string: article.url)?.host {
                Text("\(host) · 原文已读取 \(checked.formatted(date: .omitted, time: .shortened)) · 摘要保留发布者表述")
                    .font(.system(size: 9)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(21).background(.white, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(pine.opacity(0.06)))
    }

    private func openArticle(_ article: Article) { Task { await store.recheck(article, open: true) } }

    private var preferences: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Text("时间与偏好").font(.system(size: 30, weight: .medium, design: .serif)).foregroundStyle(pine)
                GroupBox("阅读") {
                    VStack(alignment: .leading, spacing: 17) {
                        Picker("新闻范围", selection: $store.preferences.days) { ForEach([1, 3, 7, 14, 30], id: \.self) { Text("最近 \($0) 天").tag($0) } }.frame(maxWidth: 270)
                        Toggle("中文标题与摘要", isOn: $store.preferences.chinese)
                        Text("使用 macOS 系统翻译；无需填写 API 密钥。翻译暂不可用时保留原文。").font(.system(size: 11)).foregroundStyle(.secondary)
                        Label("Research · 一手来源", systemImage: "checkmark.shield.fill").foregroundStyle(pine)
                        Text("优先政府原始文件、公司公告及原创论文。只显示可以打开并核对标题的具体原文；公司自述保留归属，预印本注明未经同行评审。不以媒体转述、首页或搜索结果替代出处。").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("晨间通知") {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("每天提醒我看新闻", isOn: $store.preferences.morningEnabled)
                        HStack {
                            Picker("小时", selection: $store.preferences.hour) { ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 110)
                            Text(":")
                            Picker("分钟", selection: $store.preferences.minute) { ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) } }.frame(width: 110)
                        }
                        Picker("时区", selection: $store.preferences.timeZone) {
                            ForEach(Array(Set([TimeZone.current.identifier, "America/New_York", "Asia/Shanghai", "Europe/London", "UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                        }.frame(maxWidth: 340)
                        HStack { Toggle("登录时启动", isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) })); Spacer(); Button("测试通知") { Task { await store.testNotification() } } }
                        if !store.localMessage.isEmpty { Text(store.localMessage).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("关注主题") {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("添加主题与检索关键词，也可以编辑或删除现有主题。").font(.system(size: 12)).foregroundStyle(.secondary)
                            Spacer()
                            Button { store.topicError = ""; topicDraft = TopicDraft(topic: nil) } label: { Label("添加主题", systemImage: "plus") }
                        }
                        Text("关键词用于匹配一手来源，并检索原始公告与论文。多个关键词以逗号或换行分隔，任意一个匹配即可；建议同时填写中英文词。没有符合来源的新闻时保持空白。").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(store.categories) { category in
                            HStack(spacing: 12) {
                                Toggle(isOn: Binding(get: { store.preferences.enabledCategories.contains(category.id) }, set: { store.setCategory(category.id, enabled: $0) })) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(category.title, systemImage: category.icon).foregroundStyle(pine)
                                        Text(category.searchTerms.isEmpty ? "预设领域来源" : category.searchTerms.joined(separator: " · "))
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 10)
                                Button("编辑") { store.topicError = ""; topicDraft = TopicDraft(topic: category) }
                                Button(role: .destructive) { store.deleteTopic(category) } label: { Image(systemName: "trash") }.help("删除主题")
                            }.padding(.vertical, 6)
                            if category.id != store.categories.last?.id { Divider() }
                        }
                        if store.categories.isEmpty { Text("还没有关注主题。点击“添加主题”开始。").foregroundStyle(.secondary) }
                        if !store.topicError.isEmpty { Text(store.topicError).font(.system(size: 11)).foregroundStyle(.red) }
                    }.padding(14)
                }
                Text("个人偏好、新闻缓存和翻译缓存仅保存在这台电脑上。").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(30)
        }
    }

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("来源与状态").font(.system(size: 30, weight: .medium, design: .serif)).foregroundStyle(pine)
                Text("仅列出本轮有具体原文通过验证的一手发布者。文章卡片中的来源名称与“阅读原文”均指向该篇文章。").font(.system(size: 13)).foregroundStyle(.secondary)
                Button { Task { await store.refresh(force: true) } } label: { Label(store.refreshing ? store.phase : "重新连接并验证全部来源", systemImage: "arrow.clockwise") }.disabled(store.refreshing || !store.checkingArticles.isEmpty)
                if !store.localMessage.isEmpty { Text(store.localMessage).font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(store.sources) { source in
                    HStack(spacing: 13) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(pine)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(source.name).fontWeight(.medium).foregroundStyle(pine)
                            Text("原始发布 · 文章正文已读取").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(source.count == 0 ? "暂无近期文章" : "\(source.count) 条可阅读新闻").font(.system(size: 11)).foregroundStyle(.secondary)
                        if let url = URL(string: source.url) { Link(destination: url) { Label("订阅源", systemImage: "dot.radiowaves.left.and.right") }.foregroundStyle(pine) }
                    }.padding(17).background(.white, in: RoundedRectangle(cornerRadius: 10))
                }
                if store.sources.isEmpty { Text("更新完成后，这里会列出可用来源。").foregroundStyle(.secondary).padding(.vertical, 30) }
            }.padding(30)
        }
    }
}

@MainActor
struct TopicEditor: View {
    @ObservedObject var store: NewsStore
    let topic: NewsCategory?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var keywords: String

    init(store: NewsStore, topic: NewsCategory?) {
        self.store = store
        self.topic = topic
        _title = State(initialValue: topic?.title ?? "")
        _keywords = State(initialValue: topic?.searchTerms.joined(separator: "\n") ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(topic == nil ? "添加关注主题" : "编辑关注主题").font(.system(size: 23, weight: .semibold, design: .serif)).foregroundStyle(pine)
            TextField("主题名称，例如 商业航天", text: $title).textFieldStyle(.roundedBorder)
            Text("检索关键词 / 关键句").fontWeight(.medium)
            TextEditor(text: $keywords).font(.system(size: 13)).frame(height: 125).padding(5)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(pine.opacity(0.2)))
            Text("例如 SpaceX、commercial space、商业航天。以逗号或换行分隔；英文短语按完整短语匹配。新增主题至少填写一个关键词。预设主题留空时继续使用原来的领域来源。").font(.system(size: 11)).foregroundStyle(.secondary)
            if !store.topicError.isEmpty { Text(store.topicError).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存主题") {
                    if store.saveTopic(topic, title: title, keywords: keywords) { dismiss() }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 510).background(cream)
    }
}
