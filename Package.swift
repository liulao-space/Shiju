// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Shiju",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Shiju", targets: ["Shiju"])
    ],
    dependencies: [
        // 在任意应用获取选中文本（MIT）。自带剪贴板备份还原与提示音静音。
        .package(url: "https://github.com/tisfeng/SelectedTextKit.git", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "Shiju",
            dependencies: [
                .product(name: "SelectedTextKit", package: "SelectedTextKit"),
            ],
            path: "Sources/Shiju",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("WebKit"),
                .linkedLibrary("sqlite3"),
            ]
        )
    ]
)
