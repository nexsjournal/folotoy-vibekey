import AppKit
import CoreGraphics
import ImageIO

/// 处理好的 Passport 离线页背景：RGB565 小端数据 + 240×320 预览。
nonisolated struct WallpaperArtwork: @unchecked Sendable {
    let rgb565: Data
    let preview: CGImage
}

/// 把用户照片处理成 Passport 的像素风背景：
/// 3:4 居中裁切 → 60×80 像素化 → 绿色单色 + 有序抖动 → 顶部 / 底部暗带 → 240×320 RGB565。
/// 全部用 CoreGraphics 完成，不调用生图模型，也不需要联网。
@MainActor
enum WallpaperProcessor {
    static let width = 240
    static let height = 320
    static let block = 4
    static let pixelWidth = width / block
    static let pixelHeight = height / block
    static let byteCount = width * height * 2

    /// 图片最多保留 24 级绿色，配合 Bayer 抖动形成像素画的色阶。
    private static let levels = 24
    private static let bayer: [[Int]] = [
        [0, 8, 2, 10],
        [12, 4, 14, 6],
        [3, 11, 1, 9],
        [15, 7, 13, 5],
    ]

    static func process(url: URL) throws -> WallpaperArtwork {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure.unreadable
        }
        // 手机照片常带 EXIF 方向；thumbnail 选项会应用旋转 / 镜像，避免竖拍图进来变成横的。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadable
        }
        return try process(image: image)
    }

    static func process(image: CGImage) throws -> WallpaperArtwork {
        guard image.width >= 32, image.height >= 32 else { throw Failure.tooSmall }
        guard let cropped = cropToFill(image) else { throw Failure.unreadable }

        var source = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        source.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .high
            // CGContext 原点在左下；翻转后让第 0 行对应图片顶部，暗带方向才正确。
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: 1, y: -1)
            context.draw(cropped, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        }

        var colors = [(r: UInt8, g: UInt8, b: UInt8)](repeating: (0, 0, 0), count: pixelWidth * pixelHeight)
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let offset = (y * pixelWidth + x) * 4
                let r = Double(source[offset]) / 255
                let g = Double(source[offset + 1]) / 255
                let b = Double(source[offset + 2]) / 255
                let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let dither = (Double(bayer[y % 4][x % 4]) / 16 - 0.5) * 0.10
                let value = min(max(luminance + dither, 0), 1)
                let quantized = (pow(value, 0.85) * Double(levels - 1)).rounded() / Double(levels - 1)
                var color = green(quantized)
                let dark = bandAlpha(y)
                if dark > 0 {
                    color = (
                        UInt8(Double(color.0) * (1 - dark) + 2 * dark),
                        UInt8(Double(color.1) * (1 - dark) + 6 * dark),
                        UInt8(Double(color.2) * (1 - dark) + 4 * dark))
                }
                colors[y * pixelWidth + x] = color
            }
        }

        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let color = colors[y * pixelWidth + x]
                for by in 0..<block {
                    for bx in 0..<block {
                        let offset = ((y * block + by) * width + x * block + bx) * 4
                        pixels[offset] = color.r
                        pixels[offset + 1] = color.g
                        pixels[offset + 2] = color.b
                    }
                }
            }
        }

        let rgb565 = encodeRGB565(colors)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let preview = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent) else {
            throw Failure.unreadable
        }
        return WallpaperArtwork(rgb565: rgb565, preview: preview)
    }

    private static func cropToFill(_ image: CGImage) -> CGImage? {
        let target = CGFloat(pixelWidth) / CGFloat(pixelHeight)
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        if width / height > target {
            rect.size.width = height * target
            rect.origin.x = (width - rect.width) / 2
        } else {
            rect.size.height = width / target
            rect.origin.y = (height - rect.height) / 2
        }
        return image.cropping(to: rect)
    }

    /// 暗带：顶部 40 px 压暗，底部从 200 px 开始加深，保证状态栏、时钟和日期可读。
    private static func bandAlpha(_ row: Int) -> Double {
        if row < 10 { return 0.55 - 0.02 * Double(row) }
        if row < 50 { return 0 }
        if row < 61 { return 0.55 * Double(row - 50) / 11 }
        return 0.78
    }

    private static func green(_ value: Double) -> (UInt8, UInt8, UInt8) {
        let r = 3 + value * 122
        let g = 8 + value * 242
        let b = 6 + value * 156
        return (UInt8(min(r, 255)), UInt8(min(g, 255)), UInt8(min(b, 255)))
    }

    private static func encodeRGB565(_ colors: [(r: UInt8, g: UInt8, b: UInt8)]) -> Data {
        var data = Data(capacity: byteCount)
        // 按最终 240×320 的行优先顺序输出；不能按 60×80 的小图顺序直接写，
        // 否则每个 4×4 块会连续排在一起，LVGL 看到的是错位的图。
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[(y / block) * pixelWidth + (x / block)]
                let value = UInt16(color.r >> 3) << 11
                    | UInt16(color.g >> 2) << 5
                    | UInt16(color.b >> 3)
                data.append(UInt8(value & 0xFF))
                data.append(UInt8(value >> 8))
            }
        }
        return data
    }

    enum Failure: LocalizedError {
        case unreadable
        case tooSmall

        var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "无法读取这张图片，请换一张 PNG / JPEG / HEIC。", bundle: .l10n)
            case .tooSmall: String(localized: "图片太小，至少需要 32×32 像素。", bundle: .l10n)
            }
        }
    }
}
