import AppKit

/// 保存最后一次成功应用到 Passport 的预览，重启 App 后还能显示；
/// 只存 240×320 的预览 PNG，不保存用户原图。
@MainActor
enum WallpaperStore {
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FoloButtonDev/wallpaper-preview.png")
    }

    static func load() -> NSImage? {
        NSImage(contentsOf: url)
    }

    static func save(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
