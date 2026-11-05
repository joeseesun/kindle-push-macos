import Foundation

/// One book delivered to a Kindle. Kept apart from the list, so clearing the list keeps it.
struct SendRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var path: String
    var title: String
    var author: String?
    var cover: String?
    var device: String
    /// The file name on the Kindle (under 我的文章).
    var sentAs: String?
    var translated = false
    var date = Date()
    /// Delivered before history was kept: the time is not known.
    var earlier: Bool?
    var format: String { Article.fileExtension(of: path).uppercased() }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

struct Article: Identifiable, Codable {
    var id = UUID()
    var path: String
    var status = "等待发送"
    var details = ""
    var output: String?
    var bilingual: Bool? = false
    /// A translation without the original text beside it (named for 1.13, when it was Chinese only).
    var chineseOnly: Bool?
    /// The language the made translation is in.
    var translatedTo: String?
    /// The book's language from `book-info` ('en', 'zh', …); '' when it could not be told, nil until read.
    var language: String?
    /// Bytes of text documents in an EPUB, for a rough translation time.
    var textSize: Int?
    /// What this book gets when it is sent; nil until someone (or the default) decides.
    var choice: OutputMode?
    /// The language this book is translated into; nil means the preferred language from settings.
    var target: String?
    /// From the book's own metadata (bridge `book-info`); the cleaned file name until then.
    var bookTitle: String?
    var author: String?
    var cover: String?
    /// Translation progress, 0...1, while a translation runs.
    var progress: Double?
    var title: String {
        if let bookTitle, !bookTitle.isEmpty { return bookTitle }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return String(name.dropLast(Article.fileExtension(of: name).count + 1))
    }
    var format: String { Article.fileExtension(of: path).uppercased() }

    /// Everything KOReader opens, plus Markdown; must match wifi-push/kindle_push.py.
    static let extensions = ["epub", "md", "markdown", "txt", "html", "htm", "xhtml", "docx", "odt", "rtf",
                             "pdf", "xps", "djvu", "djv", "cbz", "cbr", "cbt",
                             "mobi", "azw", "azw3", "prc", "pdb", "tcr", "fb2", "fb3", "chm", "doc", "docm",
                             "htmlz", "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff"]
    static let zipped = ["fb2.zip", "txt.zip", "html.zip", "htm.zip", "rtf.zip", "md.zip"]

    static func fileExtension(of path: String) -> String {
        let name = (path as NSString).lastPathComponent.lowercased()
        return zipped.first { name.hasSuffix("." + $0) } ?? (name as NSString).pathExtension
    }
    static func isSupported(_ url: URL) -> Bool { extensions.contains(fileExtension(of: url.path)) || zipped.contains(fileExtension(of: url.path)) }
}

struct BridgeResponse: Decodable, Sendable {
    var ok: Bool
    var host: String?
    var output: String?
    var message: String?
    var details: String?
    var job: String?
    var state: String?
    var base: String?
    var model: String?
    var runtimeReady: Bool?
    var workers: Int?
    var style: String?
    var glossary: String?
    var provider: String?
    var hasKey: Bool?
    var key: String?
    var models: [RemoteModel]?
    var installed: Bool?
    var loggedIn: Bool?
    var plan: String?
    var email: String?
    var title: String?
    var author: String?
    var cover: String?
    var percent: Int?
    var mode: String?
    var remaining: Int?
    var language: String?
    var textSize: Int?
    var target: String?
    var names: [String]?
    var device: String?
    var deviceId: String?
    var devices: [KindleDevice]?
    var volumes: [KindleVolume]?
    var candidates: [NewKindle]?
}

/// A Kindle mounted over USB.
struct KindleVolume: Decodable, Sendable, Hashable, Identifiable {
    var path: String
    var name: String
    var ready: Bool
    var installed: Bool
    var id: String { path }
}

/// An unpaired Kindle answering on this network.
struct NewKindle: Decodable, Sendable, Hashable, Identifiable {
    var host: String
    var key: String
    var fingerprint: String
    var ready: Bool
    var reason: String?
    var id: String { key }
}

/// A paired Kindle. `online` is known only after a check of the network.
struct KindleDevice: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var host: String
    var current: Bool
    var online: Bool?
}

enum ArticlePhase { case waiting, working, ready, done, failed, stopped }

extension Article {
    var phase: ArticlePhase {
        switch status {
        case "已发送": .done
        case "发送中", "翻译中", "试译中": .working
        case "试译完成", "翻译完成", "已保存": .ready
        case "失败": .failed
        case "已停止": .stopped
        default: .waiting
        }
    }
    /// Ebooks, comics and PDFs: files named after a book, worth tidying. Notes and documents are not.
    var isBook: Bool {
        !["md", "markdown", "txt", "html", "htm", "xhtml", "docx", "odt", "rtf", "doc", "docm",
          "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff"].contains(format.lowercased())
    }
    var folder: String { URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }

    /// The file the app made from this book (translation or converted copy), if it is still on disk.
    var madeFile: URL? {
        guard let output, output != path, FileManager.default.fileExists(atPath: output) else { return nil }
        return URL(fileURLWithPath: output)
    }
    /// What "show in Finder" and double-click use: the made file first, then the original.
    var preferredURL: URL { madeFile ?? URL(fileURLWithPath: path) }
    /// Names the made file in menus: a translation or a converted copy.
    var madeFileLabel: String { bilingual == true ? "译本" : "转换后的文件" }
}

struct RemoteModel: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var `default`: Bool?
}

/// What the Kindle gets: the book as it is, or a translation beside the original or on its own.
enum OutputMode: String, CaseIterable, Codable {
    case original, bilingual, targetOnly = "target-only"

    /// 1.13 stored "chinese" for a translation on its own.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = OutputMode(legacy: raw) ?? .original
    }
    init?(legacy raw: String) {
        if raw == "chinese" { self = .targetOnly } else if let mode = OutputMode(rawValue: raw) { self = mode } else { return nil }
    }

    /// Words for this book's language and the target: 中英对照 / 仅中文, or 中英对照 / 仅英文 for a Chinese book.
    func title(from source: String, to target: String) -> String {
        switch self {
        case .original: "原文"
        case .bilingual: Lang.pairLabel(source, target)
        case .targetOnly: "仅" + Lang.name(target)
        }
    }
}

/// What a foreign book gets when it is added, before anyone chooses.
enum ForeignDefault: String, CaseIterable {
    case ask, bilingual, targetOnly = "target-only", original

    var title: String {
        switch self {
        case .ask: "每次问我"
        case .bilingual: "双语对照"
        case .targetOnly: "仅译文"
        case .original: "发原文"
        }
    }
    var mode: OutputMode? {
        switch self {
        case .ask: nil
        case .bilingual: .bilingual
        case .targetOnly: .targetOnly
        case .original: .original
        }
    }

    /// The saved choice; before 1.14 the footer's last version stood in for it.
    static var saved: ForeignDefault {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "foreignDefault"), let value = ForeignDefault(rawValue: raw) { return value }
        // "原文" was where everyone started, not a decision about foreign books: keep asking.
        switch defaults.string(forKey: "outputMode") {
        case "bilingual": return .bilingual
        case "chinese": return .targetOnly
        case nil: return defaults.bool(forKey: "translateBooks") ? .bilingual : .ask
        default: return .ask
        }
    }
}

/// Languages: the targets the engine translates into, and the names a detected book language goes by.
/// Must match wifi-push/languages.py.
enum Lang {
    /// (code, name in the picker, name in Chinese, short form for 中英对照). Must match wifi-push/languages.py.
    static let targets: [(code: String, picker: String, name: String, char: String)] = [
        ("zh", "简体中文", "中文", "中"), ("zh-hant", "繁體中文", "繁体中文", "繁"),
        ("en", "English", "英文", "英"), ("ja", "日本語", "日文", "日"), ("ko", "한국어", "韩文", "韩"),
        ("fr", "Français", "法文", "法"), ("de", "Deutsch", "德文", "德"), ("es", "Español", "西班牙文", "西"),
        ("ru", "Русский", "俄文", "俄"), ("it", "Italiano", "意大利文", "意"), ("pt", "Português", "葡萄牙文", "葡"),
        ("nl", "Nederlands", "荷兰文", "荷"), ("pl", "Polski", "波兰文", "波"), ("tr", "Türkçe", "土耳其文", "土"),
        ("uk", "Українська", "乌克兰文", "乌"), ("ar", "العربية", "阿拉伯文", "阿"), ("hi", "हिन्दी", "印地文", "印地"),
        ("id", "Bahasa Indonesia", "印尼文", "印尼"), ("vi", "Tiếng Việt", "越南文", "越"), ("th", "ไทย", "泰文", "泰"),
    ]

    static func name(_ code: String) -> String {
        targets.first { $0.code == code }?.name ?? "外文"
    }
    /// The language in its own name, for pickers: English, 日本語.
    static func picker(_ code: String) -> String {
        targets.first { $0.code == code }?.picker ?? name(code)
    }
    private static func char(_ code: String) -> String? {
        targets.first { $0.code == code }?.char
    }
    /// 中英对照 for English and Chinese either way round, 英日对照 for English into Japanese.
    static func pairLabel(_ source: String, _ target: String) -> String {
        if target == "zh-hant" { return pairLabel(source, "zh") + "·繁体" }
        guard let first = char(source), let second = char(target), source != target else { return "双语对照" }
        if source == "zh" { return "中\(second)对照" }
        if target == "zh" { return "中\(first)对照" }
        return "\(first)\(second)对照"
    }
}
