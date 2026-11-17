import Foundation
import SwiftUI
import AppKit

@main
struct InterfaceChecks {
    @MainActor static func main() throws {
        var count = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else { throw TestFailure.failed(message) }
            count += 1
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MorningTen-interface-" + UUID().uuidString)
        let suiteName = "MorningTen.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName); try? FileManager.default.removeItem(at: directory) }
        let catalog = try Catalog.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
        let store = NewsStore(catalog: catalog, storage: CacheStorage(directory: directory), defaults: defaults)
        store.preferences.language = .chinese
        var story = Article(title: "NVIDIA announces new GPU chips", url: "https://example.com/gpu-release", official: true, category: "ai", source: "NVIDIA", summary: "New chips accelerate scientific research.", publishedAt: Date(), verifiedAt: Date())
        store.articles = [story]
        guard let batch = store.nextTranslationBatch() else { throw TestFailure.failed("Missing translation batch") }
        try expect(batch.sourceLanguage == "en" && batch.targetLanguage == "zh-Hans", "Translation uses the selected language pair")
        let translated = Dictionary(uniqueKeysWithValues: batch.items.map { work in
            (work.key, work.text.masked.replacingOccurrences(of: "announces new", with: "发布全新").replacingOccurrences(of: "chips", with: "芯片"))
        })
        store.acceptTranslationResults(translated, batch: batch)
        try expect(store.displayTitle(story).contains("NVIDIA") && store.displayTitle(story).contains("GPU") && store.displayTitle(story).contains("芯片"), "Translated stories retain exact protected names")
        store.search = "  芯片  "
        try expect(store.filtered.count == 1, "Chinese search finds translated headlines and trims whitespace")
        store.search = ""
        store.preferences.language = .english
        try expect(store.displayTitle(story) == story.title && store.categoryTitle("science") == "Science & Space", "Switching to English changes content and preset topic labels")
        store.preferences.language = .chinese
        try expect(store.displayTitle(story).contains("芯片"), "Switching back reuses only the matching language cache")
        story.title = "NVIDIA announces a different GPU processor"
        store.articles = [story]
        try expect(store.displayTitle(story) == story.title, "A changed headline at the same URL never shows stale translated text")
        store.preferences.protectedTerms = "scientific research"
        try expect(store.nextTranslationBatch()?.items.contains(where: { $0.text.original.contains("scientific research") && !$0.text.masked.contains("scientific research") }) == true, "Custom protected terms reach the actual translation request")
        if let rejected = store.nextTranslationBatch() { store.translationFailed(rejected) }
        try expect(store.nextTranslationBatch() == nil && store.hasTranslationFailures, "A declined language download does not repeatedly prompt for later batches")
        store.retryTranslations()
        try expect(store.nextTranslationBatch() != nil && !store.hasTranslationFailures, "Explicit retry restores an unavailable translation pair")
        store.articles = (0..<40).map { index in
            Article(title: "NVIDIA announces new GPU processor number \(index)", url: "https://example.com/story-\(index)", official: true, category: "ai", source: "NVIDIA", summary: "Researchers describe new computer hardware.", publishedAt: Date().addingTimeInterval(-Double(index)), verifiedAt: Date())
        }
        store.selection = "ai"
        for _ in 0..<10 {
            guard let next = store.nextTranslationBatch() else { break }
            store.acceptTranslationResults(Dictionary(uniqueKeysWithValues: next.items.map { ($0.key, "译文 " + $0.text.masked) }), batch: next)
        }
        try expect(store.nextTranslationBatch() == nil && store.displayTitle(store.articles[39]).hasPrefix("译文 "), "Translation continues beyond the first 20 stories")
        store.preferences.translateArticles = false
        try expect(store.displayTitle(store.articles[0]) == store.articles[0].title && store.nextTranslationBatch() == nil, "Original-language mode bypasses translated content")
        store.localMessage = "原文可以访问，已重新验证。"
        store.preferences.language = .english
        try expect(store.notice == "Original source verified.", "Existing notices follow a language change")
        if CommandLine.arguments.contains("--render") {
            store.preferences.translateArticles = false
            store.selection = "daily"
            let output = URL(fileURLWithPath: CommandLine.arguments.last!, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            for (name, language, appearance, selection) in [
                ("english-light", AppLanguage.english, NSAppearance.Name.aqua, "daily"),
                ("chinese-dark", AppLanguage.chinese, NSAppearance.Name.darkAqua, "daily"),
                ("settings", AppLanguage.chinese, NSAppearance.Name.aqua, "settings")
            ] {
                store.preferences.language = language
                store.selection = selection
                let controller = NSHostingController(rootView: DashboardView(store: store).overlay(alignment: .bottomTrailing) {
                    Text("设计预览 · 示例内容 / Design preview · Sample content").font(.system(size: 10)).padding(5).background(.background).padding(8)
                })
                let view = controller.view
                view.frame = NSRect(x: 0, y: 0, width: 1220, height: 850)
                view.appearance = NSAppearance(named: appearance)
                let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentViewController = controller
                window.orderBack(nil)
                view.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw TestFailure.failed("No preview bitmap") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw TestFailure.failed("No preview PNG") }
                try png.write(to: output.appendingPathComponent(name + ".png"))
                if name == "english-light" {
                    let sidebar = NSHostingView(rootView: DashboardView(store: store).sidebar)
                    sidebar.frame = NSRect(x: 0, y: 0, width: 235, height: 850)
                    sidebar.layoutSubtreeIfNeeded()
                    if let bitmap = sidebar.bitmapImageRepForCachingDisplay(in: sidebar.bounds) {
                        sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
                        try bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("sidebar.png"))
                    }
                }
                window.orderOut(nil)
                window.contentView = nil
            }
        }
        print("PASS: \(count) integration checks — language switching, protected terms, translated search and cache invalidation")
    }
}

private enum TestFailure: Error { case failed(String) }
