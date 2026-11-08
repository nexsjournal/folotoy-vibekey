import SwiftUI
import UniformTypeIdentifiers

/// Passport 离线页背景：上传照片 → 本地处理成绿色像素风 → 分块写入设备。
struct WallpaperSection: View {
    let link: DeviceLink

    @State private var importing = false
    @State private var artwork: WallpaperArtwork?
    @State private var preview: NSImage?
    @State private var selectedName = ""
    @State private var selectedURL: URL?
    @State private var fit: WallpaperFit = .fill
    @State private var busy = false
    @State private var progress = 0.0
    @State private var notice: String?
    @State private var error: String?

    private var canUpload: Bool {
        (link.connection == .usb || link.connection == .wifi) && firmwareSupportsWallpaper
    }

    /// 壁纸协议从 0.1.4 开始支持；旧固件收到命令后只能超时。
    private var firmwareSupportsWallpaper: Bool {
        guard let version = link.firmwareVersion else { return false }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 3 else { return false }
        if parts[0] != 0 { return parts[0] > 0 }
        if parts[1] != 1 { return parts[1] > 1 }
        return parts[2] >= 4
    }

    var body: some View {
        SettingsSection(title: "离线页背景", footer: "上传一张照片，Mac 会把它裁成 240×320、像素化、转成绿色单色，并把顶部和底部压暗，保证状态栏、时钟和日期可读。原图只在内存里处理；应用后设备会重启一次。") {
            Card {
                HStack(alignment: .top, spacing: DS.Space.l) {
                    previewCard
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        Text(selectedName.isEmpty
                             ? String(localized: "默认：内置像素猫", bundle: .l10n)
                             : selectedName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text("建议选主体居中、明暗反差大的照片；会自动裁成 3:4。")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DS.Space.s) {
                            Text("适配").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Picker("", selection: $fit) {
                                ForEach(WallpaperFit.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 120)
                            Text(fit == .fill
                                 ? String(localized: "裁切铺满", bundle: .l10n)
                                 : String(localized: "完整留边", bundle: .l10n))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        HStack(spacing: DS.Space.s) {
                            Button("选择图片…") { importing = true }
                                .buttonStyle(SecondaryButtonStyle())
                            Button("应用到 Passport") { apply() }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(artwork == nil || !canUpload || busy)
                            Button("恢复默认") { restoreDefault() }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(!canUpload || busy)
                        }
                        if busy {
                            ProgressView(value: progress) {
                                Text("正在写入设备 \(Int(progress * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let notice {
                            Text(notice).font(.caption).foregroundStyle(DS.success)
                        }
                        if let error {
                            Text(error).font(.caption).foregroundStyle(DS.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(canUpload
                             ? String(localized: "上传走当前 USB / Wi-Fi 链路，完成后设备自动重启。", bundle: .l10n)
                             : unsupportedMessage)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                load(url)
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
        .onAppear {
            if preview == nil { preview = WallpaperStore.load() }
        }
        .onChange(of: fit) { _, _ in
            guard let selectedURL else { return }
            load(selectedURL)
        }
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black)
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "cat.fill").font(.system(size: 24))
                    Text("默认猫图").font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.55))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("> OFFLINE_")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.top, 6)
                    .padding(.leading, 6)
                Spacer()
                VStack(spacing: 1) {
                    Text("23:48")
                        .font(.system(size: 22, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 0.50, green: 0.91, blue: 0.63))
                    Text("2026-11-08")
                        .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("WAITING FOR MAC")
                        .font(.system(size: 5.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
            }
        }
        .frame(width: 150, height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try WallpaperProcessor.process(url: url, fit: fit)
            artwork = result
            preview = NSImage(cgImage: result.preview, size: NSSize(width: 240, height: 320))
            selectedName = url.lastPathComponent
            selectedURL = url
            error = nil
            notice = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply() {
        guard let artwork else { return }
        busy = true
        progress = 0
        notice = nil
        error = nil
        Task {
            do {
                try await link.uploadWallpaper(artwork.rgb565) { value in
                    progress = value
                }
                WallpaperStore.save(artwork.preview)
                notice = "已应用；设备重启后显示新背景。"
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func restoreDefault() {
        busy = true
        notice = nil
        error = nil
        Task {
            do {
                try await link.clearWallpaper()
                WallpaperStore.clear()
                artwork = nil
                preview = nil
                selectedName = ""
                notice = "已恢复默认背景；设备重启后生效。"
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private var unsupportedMessage: String {
        if link.connection == .usb || link.connection == .wifi, !firmwareSupportsWallpaper {
            let version = link.firmwareVersion ?? String(localized: "未知", bundle: .l10n)
            return String(localized: "当前固件 \(version) 不支持自定义背景，请先更新到 0.1.4 或更高版本。", bundle: .l10n)
        }
        return String(localized: "需要先用 USB 或 Wi-Fi 连接 Passport；蓝牙传图片太慢。", bundle: .l10n)
    }
}
