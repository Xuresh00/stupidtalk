// swift-tools-version: 6.0
import PackageDescription

// StupidTalkCore is plain Foundation, so its tests also run on Linux.
// The app itself needs macOS 26 or newer (on-device speech and on-device AI).
var products: [Product] = [
    .library(name: "StupidTalkCore", targets: ["StupidTalkCore"])
]
var targets: [Target] = [
    .target(name: "StupidTalkCore"),
    .testTarget(name: "StupidTalkCoreTests", dependencies: ["StupidTalkCore"])
]

#if os(macOS)
products.append(.executable(name: "StupidTalk", targets: ["StupidTalk"]))
targets.append(
    .executableTarget(
        name: "StupidTalk",
        dependencies: ["StupidTalkCore"],
        resources: [.copy("Resources")]
    )
)
#endif

let package = Package(
    name: "StupidTalk",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
