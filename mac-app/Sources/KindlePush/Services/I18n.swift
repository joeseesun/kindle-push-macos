import Foundation

/// The interface's other languages. Code, state and the Python side all keep Chinese, because logic
/// and saved lists depend on those words; what the views are about to draw goes through `t`.
///
/// The catalog (mac-app/Assets/i18n/en.tsv) maps templates to translations, with {} for whatever was
/// filled in: 已移除 {} 本 → Removed {} books. A filled-in value is translated too, when it can be.
enum I18n {
    /// "zh" or "en" from Settings; otherwise macOS decides.
    static var choice: String { UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "" }
    static var english = choice.isEmpty ? !(Locale.preferredLanguages.first ?? "zh").hasPrefix("zh") : choice == "en"
    /// Chinese sentences run on; English ones need a space.
    static var sentenceGap: String { english ? " " : "" }

    private static let (exact, templates): ([String: String], [(NSRegularExpression, String)]) = {
        guard let url = Bundle.main.url(forResource: "en", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ([:], []) }
        return parse(text)
    }()
    private nonisolated(unsafe) static var cache: [String: String] = [:]
    private static let lock = NSLock()

    static func parse(_ text: String) -> ([String: String], [(NSRegularExpression, String)]) {
        var exact: [String: String] = [:]
        var templates: [(key: String, value: String)] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].replacingOccurrences(of: "\\n", with: "\n")
            let value = parts[1].replacingOccurrences(of: "\\n", with: "\n")
            if key.contains("{}") { templates.append((key, value)) } else { exact[key] = value }
        }
        // Most specific first: the most fixed text wins, so 已发到 {}；{} beats 已发到 {}；.
        let compiled = templates.sorted { $0.key.replacingOccurrences(of: "{}", with: "").count > $1.key.replacingOccurrences(of: "{}", with: "").count }
            .compactMap { item -> (NSRegularExpression, String)? in
                let pattern = "^" + item.key.components(separatedBy: "{}").map(NSRegularExpression.escapedPattern).joined(separator: "(.+?)") + "$"
                return (try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)).map { ($0, item.value) }
            }
        return (exact, compiled)
    }

    static func translate(_ text: String, exact: [String: String], templates: [(NSRegularExpression, String)]) -> String {
        if let found = exact[text] { return found }
        guard text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        for (pattern, value) in templates {
            guard let match = pattern.firstMatch(in: text, range: range) else { continue }
            var result = value
            for index in 1..<match.numberOfRanges {
                let filled = Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
                if let slot = result.range(of: "{}") {
                    result.replaceSubrange(slot, with: translate(filled, exact: exact, templates: templates))
                }
            }
            return result
        }
        // Sentences this app joins itself: A；B。
        if text.contains("；") {
            return text.components(separatedBy: "；").map { translate($0, exact: exact, templates: templates) }.joined(separator: "; ")
        }
        if text.hasSuffix("。") {
            let shorter = String(text.dropLast())
            let translated = translate(shorter, exact: exact, templates: templates)
            if translated != shorter { return translated.hasSuffix(".") ? translated : translated + "." }
        }
        return text
    }

    static func lookup(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[text] { return cached }
        let result = translate(text, exact: exact, templates: templates)
        if cache.count > 4000 { cache.removeAll() }   // Progress lines never repeat.
        cache[text] = result
        return result
    }
}

/// What to draw for a sentence written in Chinese.
func t(_ text: String) -> String { I18n.english ? I18n.lookup(text) : text }
