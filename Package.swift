// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "display-remember",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DisplayRememberCore", targets: ["DisplayRememberCore"]),
        .executable(name: "display-remember", targets: ["DisplayRememberCLI"]),
        .executable(name: "DisplayRemember", targets: ["DisplayRememberApp"]),
    ],
    targets: [
        .target(name: "DisplayRememberCore"),
        .executableTarget(name: "DisplayRememberCLI", dependencies: ["DisplayRememberCore"]),
        .executableTarget(name: "DisplayRememberApp", dependencies: ["DisplayRememberCore"]),
        .testTarget(name: "DisplayRememberCoreTests", dependencies: ["DisplayRememberCore"]),
    ]
)
