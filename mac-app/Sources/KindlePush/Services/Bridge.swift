import Foundation

import PDFKit
import AppKit
import CryptoKit

/// PDF covers: the first page, rendered once into the covers cache.
enum Covers {
    static func pdf(_ path: String) async -> String? {
        await Task.detached(priority: .utility) {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            let folder = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/KindlePush/covers")
            let key = "\(path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
            let digest = SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            let target = folder.appendingPathComponent(digest + ".png")
            if FileManager.default.fileExists(atPath: target.path) { return target.path }
            let image = page.thumbnail(of: NSSize(width: 240, height: 320), for: .cropBox)
            guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return (try? png.write(to: target)) != nil ? target.path : nil
        }.value
    }
}

enum Bridge {
    /// `input` goes to stdin, so secrets never appear in the process list.
    static func call(_ arguments: [String], input: String? = nil) async -> BridgeResponse {
        await Task.detached(priority: .userInitiated) {
            guard let resources = Bundle.main.resourceURL else {
                return BridgeResponse(ok: false, message: "应用组件不完整，请重新安装。")
            }
            let process = Process()
            let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let python else {
                return BridgeResponse(ok: false, message: "请先安装 Homebrew Python 和 Pandoc，参见项目安装文档。")
            }
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-B", resources.appendingPathComponent("app_bridge.py").path] + arguments
            let output = Pipe()
            process.standardOutput = output
            let stdin = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            // Backend catches errors and returns structured diagnostics on stdout.
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                if let input {
                    stdin.fileHandleForWriting.write(Data((input + "\n").utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return try JSONDecoder().decode(BridgeResponse.self, from: data)
            } catch {
                return BridgeResponse(ok: false, message: "无法启动本机转换组件。请确认 Python 和 Pandoc 仍已安装。", details: error.localizedDescription)
            }
        }.value
    }
}
