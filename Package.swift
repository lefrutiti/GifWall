// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GifWall",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GifWall",
            path: "Sources/GifWall",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
