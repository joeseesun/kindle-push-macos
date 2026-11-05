// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "KindlePush",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "KindlePush", targets: ["KindlePush"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")],
    targets: [
        .executableTarget(name: "KindlePush", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "KindlePushTests", dependencies: ["KindlePush"]),
    ],
    swiftLanguageModes: [.v5]
)
