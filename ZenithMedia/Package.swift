// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZenithMedia",
    platforms: [.tvOS(.v17), .iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ZenithMedia", targets: ["ZenithMedia"])],
    targets: [
        // C view of the Rust static library. The app links libzenith_media.a
        // through LIBRARY_SEARCH_PATHS set per SDK (see Task 11); swift test
        // passes -L (scripts/test-zenith-media.sh).
        .target(
            name: "ZenithMediaFFI",
            path: "Sources/ZenithMediaFFI",
            linkerSettings: [.linkedLibrary("zenith_media")]
        ),
        .target(
            name: "ZenithMedia",
            dependencies: ["ZenithMediaFFI"],
            path: "Sources/ZenithMedia",
            resources: [.process("Shaders")]
        ),
        .testTarget(
            name: "ZenithMediaTests",
            dependencies: ["ZenithMedia"],
            path: "Tests/ZenithMediaTests"
        ),
    ]
)
