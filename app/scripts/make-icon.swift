// 生成 App 图标:石墨色圆角方块 + 白色波形 + 输入光标(克制的单色风格)。
// 用法:swift scripts/make-icon.swift InputBetter/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = CommandLine.arguments.dropFirst().first ?? "."

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS 图标网格:内容区约 824/1024,四周留阴影空间。
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(white: 0.24, alpha: 1).cgColor,
                  NSColor(white: 0.14, alpha: 1).cgColor,
                  NSColor(white: 0.08, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // 顶部高光。
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.10).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])

    // 波形:5 根圆角竖条,中间最高。
    let heights: [CGFloat] = [0.26, 0.46, 0.62, 0.40, 0.22]
    let barW = rect.width * 0.075
    let gap = rect.width * 0.05
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2 - rect.width * 0.06
    ctx.setFillColor(NSColor.white.cgColor)
    for h in heights {
        let bh = rect.height * h
        let bar = CGRect(x: x, y: rect.midY - bh / 2, width: barW, height: bh)
        ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
        ctx.fillPath()
        x += barW + gap
    }
    // 输入光标:细竖线,表示"输入"。
    let cursor = CGRect(x: x + gap * 0.6, y: rect.midY - rect.height * 0.25, width: barW * 0.45, height: rect.height * 0.5)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.75).cgColor)
    ctx.addPath(CGPath(roundedRect: cursor, cornerWidth: cursor.width / 2, cornerHeight: cursor.width / 2, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: .prettyPrinted)
    .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("Contents.json"))
print("icons written to \(outDir)")
