// 生成 DMG 安装窗口的背景图(release.sh 调用):
//   swift scripts/dmg/background.swift <输出目录>
// 输出 background.png(600×360)和 background@2x.png(1200×720),再由 release.sh 用 tiffutil 合成 Retina 的 background.tiff。
//
// 极简:浅色底 + 两个图标位之间一条细箭头,不放文字。用浅色是因为 Finder 在自定义背景图上总是用深色画文件名
// (深色模式下也一样),深色底会看不清。图标和文件名由 Finder 按 dmg/settings.py 的 icon_locations 摆放,
// 这里的箭头坐标必须与它一致。
import AppKit

let size = NSSize(width: 600, height: 360)
/// 图标中心(左上角为原点,与 Finder / dmgbuild 的坐标一致)。
let appCenter = CGPoint(x: 160, y: 160)
let applicationsCenter = CGPoint(x: 440, y: 160)

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    // 换成左上角为原点,和 Finder 的图标坐标一致。
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    draw(in: cg)
    return rep.representation(using: .png, properties: [:])!
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(in cg: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    // 底色:极浅的上白下灰,几乎看不出渐变,只让画面不死板。
    let base = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xF2F2F5)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])

    // 箭头:细线 + 圆角尖头,中性灰,从 app 指向「应用程序」。
    let from = CGPoint(x: appCenter.x + 88, y: appCenter.y), to = CGPoint(x: applicationsCenter.x - 88, y: applicationsCenter.y)
    let arrow = CGMutablePath()
    arrow.move(to: from)
    arrow.addLine(to: CGPoint(x: to.x - 1, y: to.y))
    arrow.move(to: CGPoint(x: to.x - 9, y: to.y - 8))
    arrow.addLine(to: to)
    arrow.addLine(to: CGPoint(x: to.x - 9, y: to.y + 8))
    cg.addPath(arrow)
    cg.setStrokeColor(color(0x8E8E93, 0.55))
    cg.setLineWidth(2)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.strokePath()
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try render(scale: 1).write(to: output.appendingPathComponent("background.png"))
try render(scale: 2).write(to: output.appendingPathComponent("background@2x.png"))
print("DMG background → \(output.path)")
