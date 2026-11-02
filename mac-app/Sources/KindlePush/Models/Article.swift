import Foundation

struct Article: Identifiable, Codable {
    var id = UUID()
    var path: String
    var status = "等待发送"
    var details = ""
    var output: String?
    var bilingual: Bool? = false
    var title: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    var format: String { URL(fileURLWithPath: path).pathExtension.uppercased() }
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
}
