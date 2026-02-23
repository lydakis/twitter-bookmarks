// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-argument-parser",
    products: [
        .library(
            name: "ArgumentParser",
            targets: ["ArgumentParser"]
        )
    ],
    targets: [
        .target(
            name: "ArgumentParser"
        )
    ]
)
