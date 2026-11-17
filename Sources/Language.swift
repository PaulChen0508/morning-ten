import Foundation
import NaturalLanguage
import CryptoKit

enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, chinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var resolved: AppLanguage { self == .system ? ((Locale.preferredLanguages.first ?? "en").hasPrefix("zh") ? .chinese : .english) : self }
    var locale: Locale { Locale(identifier: resolved.rawValue) }
    var name: String {
        switch self {
        case .system: return "跟随系统 · System"
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
    func text(_ chinese: String, _ english: String) -> String { resolved == .chinese ? chinese : english }
}

struct LocalizedMessage: Equatable {
    let chinese: String
    let english: String
    func text(_ language: AppLanguage) -> String { language.text(chinese, english) }
}

extension Notification.Name {
    static let morningTenLanguageChanged = Notification.Name("MorningTen.languageChanged")
}

/// Names and acronyms are masked before translation and restored verbatim.
/// A result with missing/duplicated markers is rejected instead of changing a name.
struct ProtectedText: Sendable {
    let original: String
    let masked: String
    let replacements: [(marker: String, term: String)]

    static let knownTerms = [
        "NVIDIA", "Nvidia", "OpenAI", "ChatGPT", "Anthropic", "Claude", "Google", "DeepMind", "Gemini", "Microsoft", "Apple", "Amazon", "Meta", "Tesla", "SpaceX", "Starlink", "Boeing", "Airbus", "Intel", "AMD", "Qualcomm", "Samsung", "TSMC", "Broadcom", "Oracle", "Palantir", "Adobe", "Salesforce", "Netflix", "Spotify", "ByteDance", "Tencent", "Alibaba", "Baidu", "Huawei", "Xiaomi", "DeepSeek", "Mistral", "Llama", "Hugging Face", "GitHub", "GitLab", "Linux", "macOS", "iOS", "iPadOS", "iPhone", "iPad", "MacBook", "AirPods", "Vision Pro", "Windows", "Android", "Python", "JavaScript", "TypeScript", "Swift", "SwiftUI", "PyTorch", "TensorFlow", "CUDA", "Kubernetes", "Docker", "PostgreSQL", "Bitcoin", "Ethereum", "JPMorgan Chase", "Goldman Sachs", "Morgan Stanley", "BlackRock", "Vanguard", "Federal Reserve", "Federal Register", "arXiv", "Nature", "Science", "University of Virginia", "UVA", "University of Chicago", "UChicago", "F-1", "H-1B", "英伟达", "微软", "谷歌", "特斯拉", "华为", "腾讯", "阿里巴巴", "百度", "小米", "字节跳动"
    ]

    init(_ text: String, additionalTerms: String = "") {
        original = text
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var ranges: [NSRange] = []
        let terms = Self.knownTerms + NewsCategory.terms(additionalTerms)
        for term in terms where !term.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let boundary = NewsText.containsChinese(term) ? escaped : "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])"
            if let regex = try? NSRegularExpression(pattern: boundary, options: .caseInsensitive) {
                ranges += regex.matches(in: text, range: full).map(\.range)
            }
        }
        for pattern in ["\\b[A-Z][A-Z0-9]{1,}(?:[-/][A-Z0-9]+)*\\b", "\\b[A-Za-z]*[a-z][A-Z][A-Za-z0-9]*\\b", "\\b(?:GPT|Claude|Llama|Gemini|Gemma|Qwen|DeepSeek)[- .]?[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*\\b"] {
            if let regex = try? NSRegularExpression(pattern: pattern) { ranges += regex.matches(in: text, range: full).map(\.range) }
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType, options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .organizationName { ranges.append(NSRange(range, in: text)) }
            return true
        }
        // Prefer the longest term when glossary and detected organization names overlap.
        var selected: [NSRange] = []
        for range in ranges.sorted(by: { $0.length == $1.length ? $0.location < $1.location : $0.length > $1.length }) {
            if !selected.contains(where: { NSIntersectionRange($0, range).length > 0 }) { selected.append(range) }
        }
        selected.sort { $0.location < $1.location }
        var value = text
        var pairs: [(marker: String, term: String)] = []
        let prefix = text.contains("ZXQMT") ? "ZXQMTX" : "ZXQMT"
        for (index, range) in selected.enumerated() {
            pairs.append((prefix + String(index) + "QXZ", ns.substring(with: range)))
        }
        for (range, pair) in zip(selected, pairs).reversed() {
            if let swiftRange = Range(range, in: value) { value.replaceSubrange(swiftRange, with: pair.marker) }
        }
        masked = value
        replacements = pairs
    }

    func restore(_ translated: String) -> String? {
        var result = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return nil }
        for pair in replacements {
            guard result.components(separatedBy: pair.marker).count == 2 else { return nil }
            result = result.replacingOccurrences(of: pair.marker, with: pair.term)
        }
        return result
    }
}

enum TranslationText {
    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let code = recognizer.dominantLanguage?.rawValue ?? (NewsText.containsChinese(text) ? "zh-Hans" : "en")
        return code.hasPrefix("zh") ? "zh-Hans" : code
    }

    static func cacheKey(url: String, field: String, text: String, target: String, glossary: String) -> String {
        let data = Data(["protected-v1", url, field, text, target, glossary].joined(separator: "\u{0}").utf8)
        return target + "|" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct TranslationWork: Sendable {
    let key: String
    let sourceLanguage: String
    let targetLanguage: String
    let text: ProtectedText
}

struct TranslationBatch: Sendable {
    let id = UUID()
    let sourceLanguage: String
    let targetLanguage: String
    let items: [TranslationWork]
}

enum PresetTitles {
    static let english = ["visa": "Study & Visas", "ai": "AI & Models", "technology": "Technology", "world": "World", "us": "United States", "china": "China", "business": "Business", "economy": "Economy", "markets": "Markets", "security": "Cybersecurity", "climate": "Climate", "energy": "Energy", "politics": "Public Policy", "culture": "Arts & Culture", "travel": "Travel", "entertainment": "Music & Entertainment", "gaming": "Gaming", "sports": "Sports", "science": "Science & Space", "health": "Health & Medicine", "education": "Education"]
}
