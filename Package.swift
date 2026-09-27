// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "display-remember",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DisplayRememberCore", targets: ["DisplayRememberCore"]),
        .executable(name: "display-remember", targets: ["DisplayRememberCLI"]),
        .executable(name: "DisplayRemember", targets: ["DisplayRememberApp"]),
    ],
    targets: [
        .target(name: "DisplayRememberCore"),
        .target(name: "DisplayRememberAppSupport", resources: [.process("Resources")]),
        .executableTarget(name: "DisplayRememberCLI", dependencies: ["DisplayRememberCore"]),
        .executableTarget(name: "DisplayRememberApp", dependencies: ["DisplayRememberCore", "DisplayRememberAppSupport"]),
        .testTarget(name: "DisplayRememberCoreTests", dependencies: ["DisplayRememberCore"]),
        .testTarget(name: "DisplayRememberAppSupportTests", dependencies: ["DisplayRememberAppSupport"]),
        .testTarget(name: "DisplayRememberAppTests", dependencies: ["DisplayRememberApp"]),
    ]
)
