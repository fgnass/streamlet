// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Streamlet",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "Streamlet",
            targets: ["Streamlet"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/will-lumley/FaviconFinder.git", from: "5.1.4")
    ],
    targets: [
        .executableTarget(
            name: "Streamlet",
            dependencies: ["FaviconFinder"],
            path: "Streamlet/Sources"
        )
    ]
)