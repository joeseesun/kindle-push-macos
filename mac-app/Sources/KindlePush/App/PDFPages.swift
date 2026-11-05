import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// `KindlePush --render-pdf <file.pdf> <folder> [width] [height]`: every page as a 16-gray PNG
/// sized for a Kindle screen, for the Python bridge to wrap into an EPUB when the Kindle's
/// receiver only takes EPUB. Runs before any window or updater starts, then exits.
enum PDFPages {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.count >= 4, args[1] == "--render-pdf" else { return }
        let width = args.count > 4 ? Int(args[4]) ?? 1240 : 1240
        let height = args.count > 5 ? Int(args[5]) ?? 1650 : 1650
        do {
            let count = try render(URL(fileURLWithPath: args[2]), into: URL(fileURLWithPath: args[3]),
                                   width: width, height: height)
            print("{\"ok\": true, \"pages\": \(count)}")
            exit(0)
        } catch {
            print("{\"ok\": false, \"message\": \"\(error.localizedDescription.replacingOccurrences(of: "\"", with: "'"))\"}")
            exit(1)
        }
    }

    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static func render(_ source: URL, into folder: URL, width: Int, height: Int) throws -> Int {
        guard let document = PDFDocument(url: source) else { throw Failure(errorDescription: "无法打开这个 PDF。") }
        if document.isLocked { throw Failure(errorDescription: "这个 PDF 有密码保护。") }
        guard document.pageCount > 0 else { throw Failure(errorDescription: "这个 PDF 没有页面。") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let gray = CGColorSpaceCreateDeviceGray()
        let levels: [UInt8] = (0...255).map { v in v >= 215 ? 255 : UInt8((v & 0xF0) | (v >> 4)) }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            // Rotated pages report their unrotated box.
            let rotated = page.rotation % 180 != 0
            let pageWidth = rotated ? box.height : box.width, pageHeight = rotated ? box.width : box.height
            let scale = min(CGFloat(width) / pageWidth, CGFloat(height) / pageHeight)
            let w = max(1, Int(pageWidth * scale)), h = max(1, Int(pageHeight * scale))
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.interpolationQuality = .high
            context.scaleBy(x: scale, y: scale)
            page.draw(with: .cropBox, to: context)
            // E-ink shows 16 grays: clear the scanner's near-white speckle to white and keep 16 levels,
            // which costs nothing visible and lets PNG compress a scanned page several times smaller.
            if let data = context.data {
                let pixels = UnsafeMutableBufferPointer(start: data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * h),
                                                        count: context.bytesPerRow * h)
                for i in pixels.indices { pixels[i] = levels[Int(pixels[i])] }
            }
            guard let image = context.makeImage() else { continue }
            let url = folder.appendingPathComponent(String(format: "p%04d.png", index + 1))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw Failure(errorDescription: "无法写入页面图片。")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure(errorDescription: "无法写入页面图片。") }
        }
        return document.pageCount
    }
}
