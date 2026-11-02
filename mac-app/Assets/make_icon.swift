// Draws the app icon: warm paper tile, graphite e-ink reader, a paper plane leaving the page.
// Usage: swift make_icon.swift <out.png> [blue|vermilion]
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-source.png"
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "vermilion"
let size: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}
/// Continuous-corner rounded rect, close to Apple's squircle.
func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

let accent: (CGColor, CGColor, CGColor) = variant == "vermilion"
    ? (rgb(0xF0674A), rgb(0xD9452B), rgb(0xA8301C))
    : (rgb(0x4C8DFF), rgb(0x2463EB), rgb(0x1745B8))

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
c.setShouldAntialias(true)
c.interpolationQuality = .high

// Flip to a top-left origin, which is easier to reason about.
c.translateBy(x: 0, y: size); c.scaleBy(x: 1, y: -1)

// MARK: Tile — Apple grid: 824pt body, 100pt margin, ~185pt radius.
let tile = CGRect(x: 100, y: 92, width: 824, height: 824)
let tilePath = squircle(tile, 186)
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0x000000, 0.28))
c.addPath(tilePath); c.setFillColor(rgb(0xF4EDE0)); c.fillPath()
c.restoreGState()
c.saveGState()
c.addPath(tilePath); c.clip()
c.drawLinearGradient(gradient([rgb(0xFBF6EC), rgb(0xF1E8D6), rgb(0xE6DAC3)], [0, 0.55, 1]),
                     start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
// Soft light from the top left, like a page under a lamp.
c.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)]),
                     startCenter: CGPoint(x: 330, y: 230), startRadius: 0,
                     endCenter: CGPoint(x: 330, y: 230), endRadius: 560, options: [])
// Faint paper grain lines.
c.setStrokeColor(rgb(0x8A6F45, 0.014)); c.setLineWidth(2)
for y in stride(from: tile.minY + 18, to: tile.maxY, by: 22) {
    c.move(to: CGPoint(x: tile.minX, y: y)); c.addLine(to: CGPoint(x: tile.maxX, y: y + 6))
}
c.strokePath()
c.restoreGState()
// Hairline rim.
c.addPath(squircle(tile.insetBy(dx: 1.5, dy: 1.5), 185)); c.setStrokeColor(rgb(0xFFFFFF, 0.7)); c.setLineWidth(3); c.strokePath()

// MARK: Reader
let device = CGRect(x: 250, y: 232, width: 432, height: 590)
let devicePath = squircle(device, 64)
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: 26), blur: 44, color: rgb(0x3B2A12, 0.32))
c.addPath(devicePath); c.setFillColor(rgb(0x2A2E35)); c.fillPath()
c.restoreGState()
c.saveGState()
c.addPath(devicePath); c.clip()
c.drawLinearGradient(gradient([rgb(0x41464F), rgb(0x2A2E35), rgb(0x1D2025)], [0, 0.45, 1]),
                     start: CGPoint(x: device.minX, y: device.minY), end: CGPoint(x: device.maxX, y: device.maxY), options: [])
c.restoreGState()
// Bezel highlight.
c.addPath(squircle(device.insetBy(dx: 2, dy: 2), 62)); c.setStrokeColor(rgb(0xFFFFFF, 0.16)); c.setLineWidth(4); c.strokePath()

// E-ink screen.
let screen = CGRect(x: device.minX + 44, y: device.minY + 52, width: device.width - 88, height: device.height - 150)
let screenPath = squircle(screen, 14)
c.saveGState()
c.addPath(screenPath); c.clip()
c.drawLinearGradient(gradient([rgb(0xF2EEE4), rgb(0xE4DFD3)]),
                     start: CGPoint(x: screen.minX, y: screen.minY), end: CGPoint(x: screen.maxX, y: screen.maxY), options: [])
// Inner shadow under the bezel.
c.setShadow(offset: CGSize(width: 0, height: 6), blur: 10, color: rgb(0x000000, 0.35))
c.addRect(screen.insetBy(dx: -30, dy: -30)); c.addPath(screenPath); c.setFillColor(rgb(0x000000)); c.fillPath(using: .evenOdd)
c.restoreGState()

// Page: a title and two paragraphs of text.
let ink = rgb(0x2E2B27, 0.82), soft = rgb(0x2E2B27, 0.34)
func bar(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: CGColor) {
    c.addPath(squircle(CGRect(x: x, y: y, width: w, height: h), h / 2)); c.setFillColor(color); c.fillPath()
}
let left = screen.minX + 42
bar(left, screen.minY + 52, 170, 20, ink)
var y = screen.minY + 112
for w in [258.0, 244, 258, 150] { bar(left, y, w, 11, soft); y += 34 }
y += 26
for w in [258.0, 230, 182] { bar(left, y, w, 11, soft); y += 34 }

// Home button.
bar(device.midX - 42, device.maxY - 58, 84, 14, rgb(0xFFFFFF, 0.14))

// MARK: Trail — a dashed arc from the page out to the plane.
c.saveGState()
let trail = CGMutablePath()
trail.move(to: CGPoint(x: 760, y: 700))
trail.addCurve(to: CGPoint(x: 700, y: 430), control1: CGPoint(x: 820, y: 600), control2: CGPoint(x: 800, y: 500))
c.addPath(trail)
c.setLineWidth(13); c.setLineCap(.round); c.setLineDash(phase: 0, lengths: [1, 32])
c.setStrokeColor(accent.1.copy(alpha: 0.75)!); c.strokePath()
c.restoreGState()

// MARK: Paper plane — three facets, nose to the upper right.
func poly(_ points: [CGPoint], _ fill: CGColor) {
    c.move(to: points[0]); points.dropFirst().forEach { c.addLine(to: $0) }; c.closePath()
    c.setFillColor(fill); c.fillPath()
}
let nose = CGPoint(x: 862, y: 190), tail = CGPoint(x: 590, y: 336), fold = CGPoint(x: 700, y: 362),
    keel = CGPoint(x: 736, y: 480), wing = CGPoint(x: 664, y: 406)
c.saveGState()
c.setShadow(offset: CGSize(width: 6, height: 18), blur: 14, color: rgb(0x3B2A12, 0.30))
poly([nose, tail, wing, keel], accent.1)
c.restoreGState()
c.saveGState()
poly([nose, tail, fold], accent.0)
c.restoreGState()
poly([nose, fold, keel], accent.1)              // right wing, in shade
poly([fold, wing, keel], accent.2)              // keel fold, darkest
poly([nose, tail, fold], accent.0)              // top wing, lit
// Crease highlight.
c.move(to: nose); c.addLine(to: fold); c.setStrokeColor(rgb(0xFFFFFF, 0.55)); c.setLineWidth(4); c.setLineCap(.round); c.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)
