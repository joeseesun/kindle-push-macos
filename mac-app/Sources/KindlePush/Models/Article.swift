import Foundation

struct Article: Identifiable, Codable {
    var id = UUID()
    var path: String
    var status = "等待发送"
    var details = ""
    var output: String?
    var bilingual: Bool? = false
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
    var remaining: Int?
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
    var folder: String { URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent }
}

struct RemoteModel: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var `default`: Bool?
}
