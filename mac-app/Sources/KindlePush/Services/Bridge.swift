import Foundation

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
