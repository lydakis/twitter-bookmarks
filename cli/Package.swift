// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "twitter-bookmarks-cli",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "twitter-bookmarks",
            targets: ["TwitterBookmarksCLI"]
        )
    ],
    dependencies: [
        .package(path: "Vendor/swift-argument-parser")
    ],
    targets: [
        .executableTarget(
            name: "TwitterBookmarksCLI",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        )
    ]
)
