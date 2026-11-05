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
    /// A translation without the original text beside it.
    var chineseOnly: Bool?
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

/// What the Kindle gets: the book as it is, or a translation in one of two layouts.
enum OutputMode: String, CaseIterable {
    case original, bilingual, chinese

    var title: String {
        switch self {
        case .original: "原文"
        case .bilingual: "中英对照"
        case .chinese: "仅中文"
        }
    }
    var engineMode: String { self == .chinese ? "chinese" : "bilingual" }

    /// The last choice; older versions stored a yes/no for translation.
    static var saved: OutputMode {
        if let raw = UserDefaults.standard.string(forKey: "outputMode"), let mode = OutputMode(rawValue: raw) { return mode }
        return UserDefaults.standard.bool(forKey: "translateBooks") ? .bilingual : .original
    }
}
