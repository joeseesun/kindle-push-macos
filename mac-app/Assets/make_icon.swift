// Draws the app icon: Vercel-style black tile, Lucide "tablet" and "send" glyphs in white.
// Lucide (ISC license, https://lucide.dev): 24-unit grid, 2-unit stroke, round caps and joins.
// Usage: swift make_icon.swift <out.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-source.png"
let size: CGFloat = 1024

func gray(_ white: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(gray: white, alpha: a) }
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let c = NSGraphicsContext.current!.cgContext
c.translateBy(x: 0, y: size); c.scaleBy(x: 1, y: -1)   // top-left origin, like SVG

// MARK: Tile — Apple grid: 824 body, 100 margin, ~186 radius.
let tile = CGRect(x: 100, y: 92, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
c.saveGState()
c.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: gray(0, 0.35))
c.addPath(tilePath); c.setFillColor(gray(0)); c.fillPath()
c.restoreGState()
c.saveGState()
c.addPath(tilePath); c.clip()
c.drawLinearGradient(gradient([gray(0.13), gray(0.02)]),
                     start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
c.restoreGState()
// Vercel-like hairline: brighter at the top edge.
c.saveGState()
c.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
c.setLineWidth(4); c.replacePathWithStrokedPath(); c.clip()
c.drawLinearGradient(gradient([gray(1, 0.28), gray(1, 0.04)]),
                     start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.midY), options: [])
c.restoreGState()

// MARK: Glyphs on Lucide's 24-unit grid, mapped onto the tile.
let unit: CGFloat = 24            // 24 units ≈ 576 px
let weight: CGFloat = 1.75        // Lucide stroke-width
let origin = CGPoint(x: 512 - 12 * unit, y: 504 - 12 * unit)
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }
func stroke(_ path: CGPath, width: CGFloat = weight, color: CGColor) {
    c.addPath(path); c.setLineWidth(width * unit); c.setLineCap(.round); c.setLineJoin(.round)
    c.setStrokeColor(color); c.strokePath()
}
let white = gray(0.98)

// Lucide "tablet": rect x=4 y=2 w=16 h=20 rx=2, home dot at (12,18). Shifted left to leave room for the plane.
let dx: CGFloat = -1.6, dy: CGFloat = 0.6
let tablet = CGPath(roundedRect: CGRect(origin: p(4 + dx, 2 + dy), size: CGSize(width: 16 * unit, height: 20 * unit)),
                    cornerWidth: 2 * unit, cornerHeight: 2 * unit, transform: nil)
stroke(tablet, color: white)
let dot = CGMutablePath(); dot.move(to: p(12 + dx, 18 + dy)); dot.addLine(to: p(12.01 + dx, 18 + dy))
stroke(dot, color: white)
// Reading lines, as in Lucide "book-open-text".
let lines = CGMutablePath()
for (y, w) in [(7.5, 3.5), (11.0, 8.0), (14.5, 5.5)] as [(CGFloat, CGFloat)] {
    lines.move(to: p(8 + dx, y + dy)); lines.addLine(to: p(8 + dx + w, y + dy))
}
stroke(lines, width: 1.5, color: gray(0.98, 0.5))

// Lucide "send", scaled and moved so it flies out of the tablet's top-right corner.
// Path: M14.536 21.686a.5.5 0 0 0 .937-.024l6.5-19a.496.496 0 0 0-.635-.635l-19 6.5
//       a.5.5 0 0 0-.024.937l7.93 3.18a2 2 0 0 1 1.112 1.11z  M21.854 2.147 10.914 13.086
let s: CGFloat = 0.6, sx: CGFloat = 10.4, sy: CGFloat = -0.6
func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { p(sx + x * s, sy + y * s) }
let plane = CGMutablePath()
plane.move(to: q(15.0, 21.75))
plane.addLine(to: q(21.86, 2.14))
plane.addLine(to: q(2.25, 8.95))
plane.addLine(to: q(10.25, 12.65))
plane.addQuadCurve(to: q(11.36, 13.76), control: q(11.0, 12.95))
plane.closeSubpath()
let crease = CGMutablePath(); crease.move(to: q(21.854, 2.147)); crease.addLine(to: q(10.914, 13.086))
// Knockout: repaint the tile gradient under and around the plane, so it reads as cut out.
c.saveGState()
c.addPath(plane); c.setLineWidth((weight + 2.4) * unit); c.setLineJoin(.round)
c.replacePathWithStrokedPath(); c.addPath(plane); c.clip()
c.drawLinearGradient(gradient([gray(0.13), gray(0.02)]),
                     start: CGPoint(x: 0, y: tile.minY), end: CGPoint(x: 0, y: tile.maxY), options: [])
c.restoreGState()
stroke(plane, color: white)
stroke(crease, color: white)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)
