import SwiftUI
import AppKit
import UserNotifications
import Translation

private struct TopicDraft: Identifiable { let id = UUID(); let topic: NewsCategory? }

#if !MORNINGTEN_INTERFACE_CHECKS
@main
struct MorningTenMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var store: NewsStore?
    private var languageObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let manifest = Bundle.main.url(forResource: "feeds", withExtension: "json"), let catalog = try? Catalog.load(from: manifest) else {
            let alert = NSAlert()
            alert.messageText = AppLanguage.system.text("新闻配置未能加载", "The news catalog could not be loaded")
            alert.informativeText = AppLanguage.system.text("请重新安装完整的应用。本地偏好仍保留。", "Reinstall the complete application. Your local preferences are preserved.")
            alert.runModal(); NSApp.terminate(nil); return
        }
        let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MorningTen", isDirectory: true)
        let directory = ProcessInfo.processInfo.environment["MORNINGTEN_DATA_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultDirectory
        let model = NewsStore(catalog: catalog, storage: CacheStorage(directory: directory))
        store = model
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 850), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        main.minSize = NSSize(width: 960, height: 680)
        main.isReleasedWhenClosed = false
        main.titlebarAppearsTransparent = true
        main.titleVisibility = .hidden
        main.backgroundColor = .windowBackgroundColor
        main.contentViewController = NSHostingController(rootView: DashboardView(store: model))
        main.setFrameAutosaveName("MorningTenDashboard")
        if !main.setFrameUsingName("MorningTenDashboard") { main.center() }
        window = main
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "sun.horizon", accessibilityDescription: "Morning Ten")
        rebuildMenus()
        languageObserver = NotificationCenter.default.addObserver(forName: .morningTenLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.rebuildMenus() }
        }
        UNUserNotificationCenter.current().delegate = self
        showDashboard()
        Task { await model.start() }
    }

    private func rebuildMenus() {
        guard let store else { return }
        let name = store.text("晨间十条", "Morning Ten")
        window?.title = name
        let statusMenu = NSMenu()
        for (title, selector, key) in [(store.text("打开晨间十条", "Open Morning Ten"), #selector(showDashboard), ""), (store.text("刷新新闻", "Refresh News"), #selector(refreshNews), "r"), (store.text("设置…", "Settings…"), #selector(showPreferences), ",")] {
            let item = statusMenu.addItem(withTitle: title, action: selector, keyEquivalent: key); item.target = self
        }
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: store.text("退出晨间十条", "Quit Morning Ten"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = statusMenu
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(title: name); appItem.submenu = appMenu
        let settings = appMenu.addItem(withTitle: store.text("设置…", "Settings…"), action: #selector(showPreferences), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: store.text("隐藏", "Hide") + " " + name, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: store.text("退出", "Quit") + " " + name, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(title: store.text("编辑", "Edit"), action: nil, keyEquivalent: ""); main.addItem(editItem)
        let editMenu = NSMenu(title: store.text("编辑", "Edit")); editItem.submenu = editMenu
        for (zh, en, action, key) in [("撤销", "Undo", "undo:", "z"), ("剪切", "Cut", "cut:", "x"), ("复制", "Copy", "copy:", "c"), ("粘贴", "Paste", "paste:", "v"), ("全选", "Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: store.text(zh, en), action: NSSelectorFromString(action), keyEquivalent: key)
        }
        let redo = editMenu.addItem(withTitle: store.text("重做", "Redo"), action: NSSelectorFromString("redo:"), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let windowItem = NSMenuItem(title: store.text("窗口", "Window"), action: nil, keyEquivalent: ""); main.addItem(windowItem)
        let windowMenu = NSMenu(title: store.text("窗口", "Window")); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: store.text("最小化", "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: store.text("关闭窗口", "Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main; NSApp.windowsMenu = windowMenu
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showDashboard(); return true }
    @objc func showDashboard() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showPreferences() { store?.selection = "settings"; showDashboard() }
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
    @State private var readingArticle: Article?
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var showSidebar = true
    @Environment(\.colorScheme) private var colorScheme
    private func t(_ zh: String, _ en: String) -> String { store.text(zh, en) }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar.frame(width: 235)
                Rectangle().fill(Color.secondary.opacity(0.14)).frame(width: 1)
            }
            VStack(spacing: 0) {
                toolbar
                Divider()
                if store.selection == "settings" { preferences }
                else if store.selection == "sources" { sources }
                else { news }
            }.background(colorScheme == .dark ? Color(red: 0.075, green: 0.08, blue: 0.095) : Color(red: 0.965, green: 0.965, blue: 0.975))
        }
        .tint(.accentColor)
        .environment(\.locale, store.locale)
        .translationTask(translationConfig) { session in
            guard let batch = store.nextTranslationBatch(), session.targetLanguage?.languageCode == Locale.Language(identifier: batch.targetLanguage).languageCode,
                  session.sourceLanguage?.languageCode == Locale.Language(identifier: batch.sourceLanguage).languageCode else { return }
            store.beginTranslation(batch)
            defer { store.finishTranslation(batch) }
            do {
                let requests = batch.items.map { TranslationSession.Request(sourceText: $0.text.masked, clientIdentifier: $0.key) }
                let responses = try await session.translations(from: requests)
                guard !Task.isCancelled else { return }
                store.acceptTranslations(responses, batch: batch)
            } catch is CancellationError { return }
            catch { if !Task.isCancelled { store.translationFailed(batch) } }
        }
        .sheet(item: $topicDraft) { TopicEditor(store: store, topic: $0.topic) }
        .sheet(item: $readingArticle) { ArticleReader(store: store, article: $0) }
        .onAppear { configureTranslation() }
        .onChange(of: store.translationRevision) { _, _ in configureTranslation() }
    }

    private func configureTranslation() {
        guard let batch = store.nextTranslationBatch() else { translationConfig = nil; return }
        let source = Locale.Language(identifier: batch.sourceLanguage)
        let target = Locale.Language(identifier: batch.targetLanguage)
        if translationConfig?.source != source || translationConfig?.target != target { translationConfig = .init(source: source, target: target) }
        else { translationConfig?.invalidate() }
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "sun.horizon.fill").font(.system(size: 24, weight: .medium)).foregroundStyle(.orange)
                    .frame(width: 44, height: 44).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(t("晨间十条", "Morning Ten")).font(.system(size: 18, weight: .bold))
                    Text(t("每天，多一点视野", "A little more perspective")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 20)
            navigationRow(t("每日精选", "Today"), id: "daily", icon: "square.grid.2x2.fill").padding(.horizontal, 11).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("关注主题", "Your Topics")).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 11).padding(.top, 21).padding(.bottom, 7)
                    ForEach(store.categories.filter { store.preferences.enabledCategories.contains($0.id) }) { topic in
                        navigationRow(store.categoryTitle(topic.id), id: topic.id, icon: topic.icon)
                    }
                }.padding(.horizontal, 11).padding(.bottom, 10)
            }
            VStack(spacing: 4) {
                Divider().padding(.horizontal, 10).padding(.vertical, 7)
                navigationRow(t("来源", "Sources"), id: "sources", icon: "checkmark.shield")
                navigationRow(t("设置", "Settings"), id: "settings", icon: "gearshape")
            }.padding(.horizontal, 11)
            HStack {
                Label("1.4.0", systemImage: "sun.max").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                Spacer()
                Button { store.topicError = ""; topicDraft = TopicDraft(topic: nil) } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(t("添加主题", "Add Topic"))
                    .accessibilityLabel(t("添加主题", "Add Topic"))
            }.padding(18)
        }.background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
    }

    private func navigationRow(_ title: String, id: String, icon: String) -> some View {
        Button { store.selection = id; store.search = "" } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 20)
                    .foregroundStyle(store.selection == id ? Color.white : Color.accentColor)
                Text(title).font(.system(size: 12.5, weight: store.selection == id ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 11).padding(.vertical, 9)
                .foregroundStyle(store.selection == id ? Color.white : Color.primary)
                .background(store.selection == id ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).help(title)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.leading") }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .help(t("显示或隐藏侧边栏", "Show or Hide Sidebar"))
                .accessibilityLabel(t("切换侧边栏", "Toggle Sidebar"))
            Text(store.selectedTitle).font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 12)
            if store.refreshing || store.translating { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: { Label(t("刷新", "Refresh"), systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command).disabled(store.refreshing || !store.checkingArticles.isEmpty)
            Menu {
                Button(t("重新验证全部来源", "Verify All Sources")) { Task { await store.refresh(force: true) } }
                Divider()
                Button(t("放大文字", "Larger Text")) { store.preferences.fontScale = min(1.5, store.preferences.fontScale + 0.05) }
                Button(t("缩小文字", "Smaller Text")) { store.preferences.fontScale = max(0.85, store.preferences.fontScale - 0.05) }
                Button(t("还原文字大小", "Reset Text Size")) { store.preferences.fontScale = 1 }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(store.refreshing || !store.checkingArticles.isEmpty)
                .help(t("更多选项", "More Options"))
        }.buttonStyle(.borderless).padding(.horizontal, 28).padding(.vertical, 15).background(.bar)
    }

    private var news: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day().locale(store.locale)))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Text(store.selection == "daily" ? t("世界，正在发生。", "A fresh perspective.") : store.selectedTitle)
                            .font(.system(size: 34, weight: .bold)).tracking(-0.9).fixedSize(horizontal: false, vertical: true)
                        Text(t("从可信的原始发布开始，读懂你关心的事。", "Start with the original. Stay close to what matters."))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                    Image(systemName: "sun.max.fill").symbolRenderingMode(.hierarchical).foregroundStyle(.orange)
                        .font(.system(size: 38, weight: .light)).frame(width: 66, height: 66).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                }.padding(.top, 6)
                HStack(spacing: 18) {
                    Label(t("\(store.visible.count) 条精选", "\(store.visible.count) stories"), systemImage: "newspaper")
                    Label(t("最近 \(store.preferences.days) 天", "Past \(store.preferences.days) days"), systemImage: "calendar")
                    Spacer(minLength: 0)
                    Label(t("原文已核验", "Originals checked"), systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(t("搜索标题、摘要或来源", "Search headlines, summaries, or sources"), text: $store.search).textFieldStyle(.plain)
                        .accessibilityLabel(t("搜索新闻", "Search News"))
                    if !store.search.isEmpty {
                        Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(t("清除搜索", "Clear Search"))
                    }
                }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                HStack(spacing: 8) {
                    Circle().fill(store.offline ? .orange : .green).frame(width: 5, height: 5)
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if store.translating { Text(t("正在翻译…", "Translating…")).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if !store.notice.isEmpty { notice(store.notice) }
                if store.hasTranslationFailures {
                    HStack {
                        Text(t("部分内容暂时保留原文，专业名称不会被替换。", "Some text is shown in its original language. Protected terms remain unchanged.")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(t("重试翻译", "Retry Translation")) { store.retryTranslations() }.font(.system(size: 11))
                    }
                }
                if store.visible.isEmpty { emptyState }
                else {
                    LazyVStack(spacing: 16) {
                        ForEach(Array(store.visible.enumerated()), id: \.element.id) { index, article in articleCard(article, index: index + 1) }
                    }
                }
            }.frame(maxWidth: 980).padding(28).frame(maxWidth: .infinity)
        }.id(store.selection)
    }

    private var statusText: String {
        if store.refreshing { return store.phaseLabel }
        if store.offline { return t("暂时无法更新来源，请稍后重试。", "Sources could not be updated. Try again shortly.") }
        if let date = store.updatedAt { return t("更新于 ", "Updated ") + date.formatted(.dateTime.hour().minute().locale(store.locale)) }
        return t("正在准备你的新闻", "Preparing your daily perspective")
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: store.refreshing ? "arrow.triangle.2.circlepath" : (store.search.isEmpty ? "newspaper" : "magnifyingglass"))
                .font(.system(size: 38, weight: .ultraLight)).foregroundStyle(.secondary)
            Text(store.refreshing ? t("正在核验原文", "Checking original sources") : (store.search.isEmpty ? t("这里还没有可阅读的新闻", "No stories here yet") : t("没有匹配的新闻", "No matching stories")))
                .font(.system(size: 18, weight: .semibold))
            Text(store.search.isEmpty ? t("可以调整主题或时间范围。没有合规来源时，我们会保持空白。", "Try another topic or a wider date range. Stories appear only after their original source passes verification.") : t("换个关键词，或清除搜索再试。", "Try another keyword or clear your search."))
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            if !store.search.isEmpty { Button(t("清除搜索", "Clear Search")) { store.search = "" } }
            else if !store.refreshing { Button(t("管理主题", "Manage Topics")) { store.selection = "settings" } }
        }.frame(maxWidth: .infinity).padding(.vertical, 65)
    }

    private func articleCard(_ article: Article, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Text(String(format: "%02d", index)).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
                Text(store.categoryTitle(article.category)).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.accentColor.opacity(0.08), in: Capsule())
                Spacer()
                Text(article.publishedAt.formatted(.dateTime.month(.abbreviated).day().locale(store.locale))).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button { readingArticle = article } label: {
                Text(store.displayTitle(article)).font(.system(size: 21 * store.preferences.fontScale, weight: .semibold)).tracking(-0.35)
                    .foregroundStyle(.primary).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            }.buttonStyle(.plain)
            if !article.summary.isEmpty {
                Text(store.displaySummary(article)).font(.system(size: 13 * store.preferences.fontScale)).foregroundStyle(.secondary).lineSpacing(5).lineLimit(4).textSelection(.enabled)
            }
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                Button { openArticle(article) } label: { Text(article.source).lineLimit(1) }.buttonStyle(.plain)
                if article.source.lowercased().contains("arxiv") { Text(t("· 预印本", "· Preprint")).foregroundStyle(.secondary) }
                Spacer(minLength: 8)
                if store.checkingArticles.contains(article.url) { ProgressView().controlSize(.mini) }
                Button { Task { await store.recheck(article) } } label: { Image(systemName: "arrow.clockwise") }
                    .help(t("重新连接并核验原文", "Reconnect and Verify Original")).accessibilityLabel(t("重试来源", "Retry Source"))
                Button { openArticle(article) } label: { Label(t("原文", "Original"), systemImage: "arrow.up.right") }
            }.font(.system(size: 11, weight: .medium)).buttonStyle(.borderless).disabled(store.refreshing || store.checkingArticles.contains(article.url))
        }.padding(23).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 19))
            .overlay(RoundedRectangle(cornerRadius: 19).stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5))
    }

    private func openArticle(_ article: Article) { Task { await store.recheck(article, open: true) } }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var preferences: some View {
        Form {
            Section {
                Picker(t("显示语言", "Language"), selection: $store.preferences.language) {
                    ForEach(AppLanguage.allCases) { Text($0.name).tag($0) }
                }
                Toggle(t("将新闻翻译为所选语言", "Translate Stories into This Language"), isOn: $store.preferences.translateArticles)
                Text(t("界面、标题和摘要会随语言切换。系统翻译可能需要首次下载语言包；不可用时显示原文。", "The interface, headlines, and summaries follow your language. Apple Translation may need to download a language pack; original text stays available if translation fails."))
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Label(t("语言与翻译", "Language & Translation"), systemImage: "character.bubble") }
            Section {
                Label(t("公司名、产品名与专业缩写保留原文", "Keep Company Names, Products, and Acronyms in Their Original Form"), systemImage: "lock.shield")
                Text(t("自动保护 NVIDIA、OpenAI、SpaceX、GPU、ETF 等名称。还可以在下面添加你自己的专业术语，逗号或换行分隔。", "Names such as NVIDIA, OpenAI, SpaceX, GPU, and ETF are protected automatically. Add any other terms below, separated by commas or new lines."))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $store.preferences.protectedTerms).font(.system(size: 12)).frame(height: 75).padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(t("自定义保留术语", "Custom Protected Terms"))
                    .onChange(of: store.preferences.protectedTerms) { _, value in
                        if value.count > 8000 { store.preferences.protectedTerms = String(value.prefix(8000)) }
                    }
            } header: { Text(t("术语保护", "Protected Terms")) }
            Section {
                Picker(t("新闻范围", "Date Range"), selection: $store.preferences.days) {
                    ForEach([1, 3, 7, 14, 30], id: \.self) { Text(t("最近 \($0) 天", "Past \($0) days")).tag($0) }
                }
                HStack {
                    Text(t("文字大小", "Text Size"))
                    Slider(value: $store.preferences.fontScale, in: 0.85...1.5, step: 0.05).frame(maxWidth: 230)
                    Text("\(Int((store.preferences.fontScale * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 45)
                }
            } header: { Label(t("阅读", "Reading"), systemImage: "textformat.size") }
            Section {
                Toggle(t("每天提醒我看新闻", "Daily Morning Reminder"), isOn: $store.preferences.morningEnabled)
                HStack {
                    Picker(t("小时", "Hour"), selection: $store.preferences.hour) { ForEach(0..<24) { Text(String(format: "%02d", $0)).tag($0) } }
                    Picker(t("分钟", "Minute"), selection: $store.preferences.minute) { ForEach(0..<60) { Text(String(format: "%02d", $0)).tag($0) } }
                }.disabled(!store.preferences.morningEnabled)
                Picker(t("时区", "Time Zone"), selection: $store.preferences.timeZone) {
                    ForEach(Array(Set([store.preferences.timeZone, TimeZone.current.identifier, "America/New_York", "Asia/Shanghai", "Europe/London", "UTC"])).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Toggle(t("登录时启动", "Launch at Login"), isOn: Binding(get: { store.loginEnabled }, set: { store.setLogin($0) }))
                Button(t("发送测试通知", "Send Test Reminder")) { Task { await store.testNotification() } }
            } header: { Label(t("提醒", "Reminders"), systemImage: "bell") }
            Section {
                HStack {
                    Text(t("用关键词定义你关心的世界。", "Make space for what interests you.")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.topicError = ""; topicDraft = TopicDraft(topic: nil) } label: { Label(t("添加主题", "Add Topic"), systemImage: "plus") }
                }
                ForEach(store.categories) { topic in
                    HStack(spacing: 14) {
                        Toggle(isOn: Binding(get: { store.preferences.enabledCategories.contains(topic.id) }, set: { store.setCategory(topic.id, enabled: $0) })) {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(store.categoryTitle(topic.id), systemImage: topic.icon)
                                Text(topic.searchTerms.isEmpty ? t("预设领域", "Preset topic") : topic.searchTerms.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Button { store.topicError = ""; topicDraft = TopicDraft(topic: topic) } label: { Image(systemName: "pencil") }.help(t("编辑主题", "Edit Topic"))
                        Button(role: .destructive) { store.deleteTopic(topic) } label: { Image(systemName: "trash") }.help(t("删除主题", "Delete Topic"))
                    }.padding(.vertical, 5)
                }
                if store.categories.isEmpty { Text(t("还没有主题。添加一个开始阅读。", "Add your first topic to get started.")).foregroundStyle(.secondary) }
                if !store.topicErrorLabel.isEmpty { Text(store.topicErrorLabel).font(.caption).foregroundStyle(.red) }
            } header: { Label(t("关注主题", "Your Topics"), systemImage: "square.stack") }
            Section {
                Label("Research", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                Text(t("只显示能读取并核对标题的原始发布。公司表述保留归属；预印本未经同行评审。没有合规来源时不凑数。", "Only readable, matching original publications appear. Company claims remain attributed; preprints are not peer reviewed. We never fill gaps with unverifiable sources."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(t("偏好、主题和翻译缓存在本机保存，无需 API 密钥。", "Preferences, topics, and translations are stored locally. No API key is required.")).font(.caption).foregroundStyle(.secondary)
                if !store.notice.isEmpty { Text(store.notice).font(.caption).foregroundStyle(.secondary) }
            } header: { Text(t("来源与隐私", "Sources & Privacy")) }
        }.formStyle(.grouped).scrollContentBackground(.hidden)
    }

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(t("每条新闻，都有来处。", "Every story starts somewhere.")).font(.system(size: 30, weight: .bold)).tracking(-0.7)
                Text(t("这里只列出通过本轮核验的原始发布者。新闻中的来源名称直接连接对应原文。", "These publishers have originals that passed verification. Source names on each story open the specific original article."))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button { Task { await store.refresh(force: true) } } label: { Label(t("重新连接并核验全部来源", "Reconnect and Verify All Sources"), systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderedProminent).disabled(store.refreshing || !store.checkingArticles.isEmpty)
                if store.refreshing { HStack { ProgressView().controlSize(.small); Text(store.phaseLabel).foregroundStyle(.secondary) } }
                if !store.notice.isEmpty { notice(store.notice) }
                LazyVStack(spacing: 10) {
                    ForEach(store.sources) { source in
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.shield.fill").font(.system(size: 22)).foregroundStyle(.green).frame(width: 45, height: 45).background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            VStack(alignment: .leading, spacing: 5) {
                                Text(source.name).font(.system(size: 14, weight: .semibold))
                                Text(URL(string: source.url)?.host ?? source.name).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(t("\(source.count) 条原文", "\(source.count) originals")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(17).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15))
                    }
                }
                if store.sources.isEmpty { Text(t("核验完成后，可用来源会出现在这里。", "Verified sources will appear here after an update.")).foregroundStyle(.secondary).padding(.vertical, 25) }
            }.frame(maxWidth: 900).padding(28).frame(maxWidth: .infinity)
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
        self.store = store; self.topic = topic
        _title = State(initialValue: topic?.title ?? "")
        _keywords = State(initialValue: topic?.searchTerms.joined(separator: "\n") ?? "")
    }
    private func t(_ zh: String, _ en: String) -> String { store.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "text.magnifyingglass").font(.system(size: 26)).foregroundStyle(Color.accentColor)
            Text(topic == nil ? t("添加关注主题", "Add a Topic") : t("编辑关注主题", "Edit Topic")).font(.system(size: 25, weight: .bold)).tracking(-0.5)
            TextField(t("主题名称，例如 商业航天", "Topic name, e.g. Commercial Space"), text: $title).textFieldStyle(.roundedBorder)
            Text(t("关键词与关键句", "Keywords & Phrases")).font(.system(size: 12, weight: .semibold))
            TextEditor(text: $keywords).font(.system(size: 13)).frame(height: 115).padding(8)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary)).accessibilityLabel(t("检索关键词", "Search Keywords"))
            Text(t("例如 SpaceX、commercial space、商业航天。用逗号或换行分隔；任一关键词匹配即可。新主题至少需要一个关键词。", "For example: SpaceX, commercial space. Separate phrases with commas or new lines; any match qualifies. New topics need at least one keyword."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if !store.topicErrorLabel.isEmpty { Text(store.topicErrorLabel).font(.system(size: 12)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(t("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("保存主题", "Save Topic")) { if store.saveTopic(topic, title: title, keywords: keywords) { dismiss() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(28).frame(width: 520)
    }
}

@MainActor
struct ArticleReader: View {
    @ObservedObject var store: NewsStore
    let article: Article
    @Environment(\.dismiss) private var dismiss
    @State private var showOriginal = false
    private func t(_ zh: String, _ en: String) -> String { store.text(zh, en) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(article.source, systemImage: "checkmark.seal.fill").foregroundStyle(.secondary)
                Spacer()
                Toggle(t("显示原文", "Show Original"), isOn: $showOriginal).toggleStyle(.switch).controlSize(.small)
                Button(t("完成", "Done")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.font(.system(size: 12)).padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(showOriginal ? article.title : store.displayTitle(article)).font(.system(size: 29 * store.preferences.fontScale, weight: .bold)).tracking(-0.6).textSelection(.enabled)
                    Text(article.publishedAt.formatted(.dateTime.year().month(.wide).day().locale(store.locale))).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(showOriginal ? article.summary : store.displaySummary(article)).font(.system(size: 16 * store.preferences.fontScale)).lineSpacing(8).textSelection(.enabled)
                    Divider()
                    if article.source.lowercased().contains("arxiv") { Label(t("预印本，未经同行评审", "Preprint · Not peer reviewed"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    Text(article.url).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(t("摘要来自发布者。打开原文查看完整内容。", "This summary comes from the publisher. Open the original for the complete article.")).font(.caption).foregroundStyle(.secondary)
                }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if store.checkingArticles.contains(article.url) { ProgressView().controlSize(.small) }
                if !store.notice.isEmpty { Text(store.notice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Spacer()
                Button { Task { await store.recheck(article) } } label: { Label(t("重试来源", "Retry Source"), systemImage: "arrow.clockwise") }
                Button { Task { await store.recheck(article, open: true) } } label: { Label(t("阅读完整原文", "Read Full Original"), systemImage: "arrow.up.right") }.buttonStyle(.borderedProminent)
            }.disabled(store.refreshing || store.checkingArticles.contains(article.url)).padding(20)
        }.frame(width: 720, height: 620).environment(\.locale, store.locale)
            .onChange(of: store.articles) { _, articles in
                if !store.refreshing, !articles.contains(where: { $0.url == article.url }) { dismiss() }
            }
            .onChange(of: store.refreshing) { _, refreshing in
                if !refreshing, !store.articles.contains(where: { $0.url == article.url }) { dismiss() }
            }
    }
}
