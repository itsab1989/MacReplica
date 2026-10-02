// Renders the MacReplica app icon and builds Resources/AppIcon.icns.
// Usage: swift tools/make-icon.swift <output-folder>
//
// Motif: two Mac screens — a faded original behind and its solid copy in
// front — with a circular "restore" arrow on the copy. Drawn on the macOS
// icon grid (824 pt body on a 1024 pt canvas) so it sits well in the Dock.

import AppKit
import CoreGraphics

let outputFolder = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon")
try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(size) / 1024
    ctx.scaleBy(x: s, y: s)

    // Body with drop shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x2B3A8F))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x3A4BD6), color(0x1FA9B8)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])
    // Subtle top highlight.
    let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    func screen(_ rect: CGRect, fill: CGColor, stand: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: 34, cornerHeight: 34, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
        // Stand
        let neck = CGRect(x: rect.midX - 34, y: rect.minY - 46, width: 68, height: 50)
        ctx.setFillColor(stand)
        ctx.fill(neck)
        let foot = CGPath(roundedRect: CGRect(x: rect.midX - 92, y: rect.minY - 62, width: 184, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil)
        ctx.addPath(foot)
        ctx.fillPath()
    }

    // Original (behind, faded)
    screen(CGRect(x: 196, y: 470, width: 420, height: 296), fill: color(0xFFFFFF, 0.30), stand: color(0xFFFFFF, 0.30))

    // Copy (front, solid, with shadow)
    let front = CGRect(x: 388, y: 324, width: 440, height: 310)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x0B1550, 0.35))
    screen(front, fill: color(0xFFFFFF), stand: color(0xF2F5FF))
    ctx.restoreGState()

    // Circular restore arrow on the copy.
    let center = CGPoint(x: front.midX, y: front.midY)
    let radius: CGFloat = 92
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color(0x2F57D0))
    let start = CGFloat.pi * 0.95
    let end = CGFloat.pi * 2.40
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
    ctx.strokePath()
    // Arrow head at the end of the arc, pointing along the direction of travel.
    let tip = CGPoint(x: center.x + radius * cos(end), y: center.y + radius * sin(end))
    let tangent = CGFloat(end + .pi / 2)
    let headLength: CGFloat = 74
    let headWidth: CGFloat = 52
    let forward = CGPoint(x: cos(tangent), y: sin(tangent))
    let side = CGPoint(x: -forward.y, y: forward.x)
    let apex = CGPoint(x: tip.x + forward.x * headLength, y: tip.y + forward.y * headLength)
    let baseCenter = CGPoint(x: tip.x - forward.x * 6, y: tip.y - forward.y * 6)
    ctx.move(to: apex)
    ctx.addLine(to: CGPoint(x: baseCenter.x + side.x * headWidth, y: baseCenter.y + side.y * headWidth))
    ctx.addLine(to: CGPoint(x: baseCenter.x - side.x * headWidth, y: baseCenter.y - side.y * headWidth))
    ctx.closePath()
    ctx.setFillColor(color(0x2F57D0))
    ctx.fillPath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try data.write(to: url)
}

let iconset = outputFolder.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(render(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(render(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try writePNG(render(size: 1024), to: outputFolder.appendingPathComponent("AppIcon-1024.png"))
print(iconset.path)
