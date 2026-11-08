import CoreGraphics
import XCTest
@testable import VibeKey

nonisolated final class WallpaperProcessorTests: XCTestCase {
    @MainActor func testProducesRGB565AndPreviewAtDeviceSize() throws {
        let artwork = try WallpaperProcessor.process(image: gradientImage())
        XCTAssertEqual(artwork.rgb565.count, 240 * 320 * 2)
        XCTAssertEqual(artwork.preview.width, 240)
        XCTAssertEqual(artwork.preview.height, 320)
    }

    @MainActor func testGreenTintAndDarkBands() throws {
        let artwork = try WallpaperProcessor.process(image: solidImage(value: 180))
        let top = rgb565(artwork.rgb565, x: 120, y: 5)
        let middle = rgb565(artwork.rgb565, x: 120, y: 120)
        let bottom = rgb565(artwork.rgb565, x: 120, y: 300)
        XCTAssertGreaterThan(middle.g, middle.r)
        XCTAssertGreaterThan(middle.g, middle.b)
        XCTAssertLessThan(luminance(bottom), luminance(middle))
        XCTAssertLessThan(luminance(top), luminance(middle))
    }

    @MainActor func testPixelsAreUpscaledInFourPointBlocks() throws {
        let artwork = try WallpaperProcessor.process(image: gradientImage())
        XCTAssertEqual(rgb565(artwork.rgb565, x: 0, y: 80), rgb565(artwork.rgb565, x: 3, y: 83))
        XCTAssertEqual(rgb565(artwork.rgb565, x: 4, y: 80), rgb565(artwork.rgb565, x: 7, y: 83))
    }

    @MainActor func testCRC32MatchesStandardVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: - Helpers

    private func gradientImage() -> CGImage {
        let width = 300
        let height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let value = UInt8(255 - y * 255 / max(height - 1, 1))
            for x in 0..<width {
                let offset = (y * width + x) * 4
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func solidImage(value: UInt8) -> CGImage {
        let width = 300
        let height = 400
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private struct RGB: Equatable {
        let r: UInt8
        let g: UInt8
        let b: UInt8
    }

    private func rgb565(_ data: Data, x: Int, y: Int) -> RGB {
        let offset = (y * 240 + x) * 2
        let value = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        let r = UInt8((value >> 11) & 0x1F) << 3
        let g = UInt8((value >> 5) & 0x3F) << 2
        let b = UInt8(value & 0x1F) << 3
        return RGB(r: r, g: g, b: b)
    }

    private func luminance(_ color: RGB) -> Int {
        Int(color.r) * 21 + Int(color.g) * 72 + Int(color.b) * 7
    }
}
