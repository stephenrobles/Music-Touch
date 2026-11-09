// Draws the Music Touch app icon (flat piano keys on a red gradient) at every size the app and
// the website need. Run from the repo root:
//     swift Tools/make-icon.swift
// Writes Music Touch/Assets.xcassets/AppIcon.appiconset/icon_*.png (macOS template: the rounded
// square at 824/1024 of the canvas with a soft shadow) and, when the beardfm.app checkout exists,
// its 320 px full-bleed icon.
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
}

/// Apple's continuous-corner icon shape, approximated.
func squircle(_ rect: CGRect) -> CGPath {
    let r = rect.width * 0.2237
    let k: CGFloat = 0.62
    let p = CGMutablePath()
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    p.move(to: CGPoint(x: minX + r, y: maxY))
    p.addLine(to: CGPoint(x: maxX - r, y: maxY))
    p.addCurve(to: CGPoint(x: maxX, y: maxY - r), control1: CGPoint(x: maxX - r + r * k, y: maxY), control2: CGPoint(x: maxX, y: maxY - r + r * k))
    p.addLine(to: CGPoint(x: maxX, y: minY + r))
    p.addCurve(to: CGPoint(x: maxX - r, y: minY), control1: CGPoint(x: maxX, y: minY + r - r * k), control2: CGPoint(x: maxX - r + r * k, y: minY))
    p.addLine(to: CGPoint(x: minX + r, y: minY))
    p.addCurve(to: CGPoint(x: minX, y: minY + r), control1: CGPoint(x: minX + r - r * k, y: minY), control2: CGPoint(x: minX, y: minY + r - r * k))
    p.addLine(to: CGPoint(x: minX, y: maxY - r))
    p.addCurve(to: CGPoint(x: minX + r, y: maxY), control1: CGPoint(x: minX, y: maxY - r + r * k), control2: CGPoint(x: minX + r - r * k, y: maxY))
    p.closeSubpath()
    return p
}

/// Draws the icon artwork into `rect`, designed on a 1024-point grid.
func drawIcon(_ ctx: CGContext, in rect: CGRect, shadow: Bool) {
    let s = rect.width / 1024
    let shape = squircle(rect)
    if shadow {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 22 * s, color: rgb(0x000000, 0.32))
        ctx.setFillColor(rgb(0xD5141F))
        ctx.addPath(shape)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let g = CGGradient(colorsSpace: cs, colors: [rgb(0xFF5257), rgb(0xD5141F)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // Five white keys with three short dark keys.
    let keyW = 112 * s, gap = 30 * s, keyH = 560 * s
    let total = 5 * keyW + 4 * gap
    let x0 = rect.minX + (rect.width - total) / 2, y0 = rect.minY + (rect.height - keyH) / 2
    let keys = CGMutablePath()
    for i in 0..<5 {
        keys.addPath(rounded(CGRect(x: x0 + CGFloat(i) * (keyW + gap), y: y0, width: keyW, height: keyH), 40 * s))
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 34 * s, color: rgb(0x000000, 0.22))
    ctx.addPath(keys)
    ctx.setFillColor(rgb(0xFFF4F4))
    ctx.fillPath()
    ctx.restoreGState()
    let bw = 76 * s, bh = 300 * s
    for i in [0, 1, 3] {
        let cx = x0 + CGFloat(i + 1) * (keyW + gap) - gap / 2
        ctx.addPath(rounded(CGRect(x: cx - bw / 2, y: y0 + keyH - bh, width: bw, height: bh), 30 * s))
        ctx.setFillColor(rgb(0x8F0B15, 0.92))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func render(size: Int, inset: CGFloat, shadow: Bool) -> CGImage {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    drawIcon(ctx, in: canvas.insetBy(dx: canvas.width * inset, dy: canvas.height * inset), shadow: shadow)
    return ctx.makeImage()!
}

func write(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(url.path)")
}

// macOS icon template: artwork at 824/1024 of the canvas, shadow included.
let iconset = root.appendingPathComponent("Music Touch/Assets.xcassets/AppIcon.appiconset")
let macInset = (1 - 824.0 / 1024.0) / 2
for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(render(size: size, inset: macInset, shadow: true), to: iconset.appendingPathComponent("icon_\(size).png"))
}
let contents = """
{
  "images" : [
    { "idiom" : "mac", "size" : "16x16", "scale" : "1x", "filename" : "icon_16.png" },
    { "idiom" : "mac", "size" : "16x16", "scale" : "2x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "1x", "filename" : "icon_32.png" },
    { "idiom" : "mac", "size" : "32x32", "scale" : "2x", "filename" : "icon_64.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "1x", "filename" : "icon_128.png" },
    { "idiom" : "mac", "size" : "128x128", "scale" : "2x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "1x", "filename" : "icon_256.png" },
    { "idiom" : "mac", "size" : "256x256", "scale" : "2x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "1x", "filename" : "icon_512.png" },
    { "idiom" : "mac", "size" : "512x512", "scale" : "2x", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try! contents.write(to: iconset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

// Full-bleed icons: the website's 320 px icon and a 1024 px version for the README and listings.
write(render(size: 1024, inset: 0, shadow: false), to: root.appendingPathComponent("Design/icon-1024.png"))
let site = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies/Apps/beardfm.app/site/static/assets/icons")
if FileManager.default.fileExists(atPath: site.path) {
    write(render(size: 320, inset: 0, shadow: false), to: site.appendingPathComponent("music-touch.png"))
}
