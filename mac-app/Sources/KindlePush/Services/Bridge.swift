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
    /// Running calls by tag, so one can be cancelled (a transfer the user stops).
    nonisolated(unsafe) private static var running: [String: Process] = [:]
    private static let lock = NSLock()

    /// Ends the call started with `tag`. The bridge kills its ssh transfer on the way out.
    static func cancel(_ tag: String) {
        let process = lock.withLock { running[tag] }
        if let process, process.isRunning { process.terminate() }
    }

    /// `input` goes to stdin, so secrets never appear in the process list.
    /// `progressFile`: where the bridge writes how far a transfer has got.
    static func call(_ arguments: [String], input: String? = nil, tag: String? = nil, progressFile: String? = nil) async -> BridgeResponse {
        await Task.detached(priority: .userInitiated) {
            guard let resources = Bundle.main.resourceURL else {
                return BridgeResponse(ok: false, message: "应用组件不完整，请重新安装。")
            }
            let process = Process()
            // The copy inside the app; only a build without it (from source) looks elsewhere.
            let python = [resources.appendingPathComponent("runtime/python/bin/python3").path,
                          "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            guard let python else {
                return BridgeResponse(ok: false, message: "应用不完整，请重新下载安装。从源码构建需要 Homebrew Python 和 Pandoc，参见项目安装文档。")
            }
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = ["-B", resources.appendingPathComponent("app_bridge.py").path] + arguments
            // Lets the bridge ask this app to render PDF pages (old Kindle receivers take only EPUB).
            var environment = ProcessInfo.processInfo.environment
            environment["KINDLEPUSH_APP"] = Bundle.main.executablePath
            if let progressFile { environment["KINDLEPUSH_PROGRESS"] = progressFile }
            // Python caches compiled files beside its sources. Inside the app that breaks the signature,
            // so they go here, for this process and everything it starts (venv, pip, the engine).
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            environment["PYTHONPYCACHEPREFIX"] = caches.appendingPathComponent("KindlePush/pycache").path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            let stdin = Pipe()
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            // Backend catches errors and returns structured diagnostics on stdout.
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                if let tag { lock.withLock { running[tag] = process } }
                defer { if let tag { lock.withLock { running[tag] = nil } } }
                if let input {
                    stdin.fileHandleForWriting.write(Data((input + "\n").utf8))
                    try? stdin.fileHandleForWriting.close()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationReason == .uncaughtSignal || process.terminationStatus == 130 {
                    return BridgeResponse(ok: false, message: "已取消", state: "cancelled")
                }
                return try JSONDecoder().decode(BridgeResponse.self, from: data)
            } catch {
                return BridgeResponse(ok: false, message: "无法启动本机转换组件。请重新下载安装应用。", details: error.localizedDescription)
            }
        }.value
    }
}
