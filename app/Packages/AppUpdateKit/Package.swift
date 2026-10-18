// swift-tools-version: 6.0
// AppUpdateKit:与具体 app 无关的检查更新组件,可以原样拷到其他 macOS app 复用。
// - AppUpdateKit:版本比较、检查调度、跳过 / 稍后提醒 / 强制更新的判断、JSON 更新数据源(无第三方依赖);
// - AppUpdateInstaller:用 Sparkle 2(业内标准:EdDSA 签名校验、下载、替换、重启)安装更新,
//   以自定义 UserDriver 的方式把进度交给 app 自己的界面显示。
// 数据源和界面由 app 注入 / 自己画。
import PackageDescription

let package = Package(
    name: "AppUpdateKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppUpdateKit", targets: ["AppUpdateKit"]),
        .library(name: "AppUpdateInstaller", targets: ["AppUpdateInstaller"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .target(name: "AppUpdateKit"),
        .target(name: "AppUpdateInstaller", dependencies: ["AppUpdateKit", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "AppUpdateKitTests", dependencies: ["AppUpdateKit"]),
    ]
)
