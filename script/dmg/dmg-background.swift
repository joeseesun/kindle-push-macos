// Renders the DMG window background (640×400 pt) at 1x and 2x.
// usage: swift scripts/dmg-background.swift out.png out@2x.png ["second line, e.g. 安装后在菜单栏运行"]
import AppKit

let args = CommandLine.arguments
let fontsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../Resources/Fonts")
for f in (try? FileManager.default.contentsOfDirectory(at: fontsDir, includingPropertiesForKeys: nil)) ?? [] {
    CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
}

func font(_ name: String, _ size: CGFloat, fallback weight: NSFont.Weight) -> NSFont {
    NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
}

func render(scale: CGFloat, to path: String) {
    let w: CGFloat = 640, h: CGFloat = 400
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(h * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    // Flip so y grows downward, like Finder's icon coordinates (and tell AppKit, so text isn't mirrored).
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: h)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()

    // Dot grid.
    NSColor(white: 0, alpha: 0.07).setFill()
    for x in stride(from: CGFloat(10), to: w, by: 20) {
        for y in stride(from: CGFloat(10), to: h, by: 20) {
            NSBezierPath(ovalIn: NSRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
        }
    }

    // Dashed arrow between the app (x 170) and Applications (x 470), at icon centre height.
    let y: CGFloat = 186
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 248, y: y)); line.line(to: NSPoint(x: 386, y: y))
    line.lineWidth = 1.5
    line.setLineDash([5, 5], count: 2, phase: 0)
    NSColor(white: 0.62, alpha: 1).setStroke()
    line.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: 383, y: y - 7)); head.line(to: NSPoint(x: 392, y: y)); head.line(to: NSPoint(x: 383, y: y + 7))
    head.lineWidth = 1.5; head.lineCapStyle = .round; head.lineJoinStyle = .round
    head.stroke()

    // Copy.
    let para = NSMutableParagraphStyle(); para.alignment = .center
    func text(_ s: String, _ f: NSFont, _ color: NSColor, _ top: CGFloat) {
        let a = NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: para])
        a.draw(in: NSRect(x: 0, y: top, width: w, height: 30))
    }
    text("拖到「应用程序」完成安装", font("Geist-Medium", 15, fallback: .medium), NSColor(white: 0.04, alpha: 1), 300)
    text(args.count > 3 ? args[3] : "",
         font("Geist-Regular", 11.5, fallback: .regular), NSColor(white: 0.45, alpha: 1), 328)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

render(scale: 1, to: args[1])
render(scale: 2, to: args[2])
