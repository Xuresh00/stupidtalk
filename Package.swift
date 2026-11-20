// swift-tools-version: 6.0
import PackageDescription

// StupidTalkCore is plain Foundation, so its tests also run on Linux.
// The app itself needs macOS 26 or newer on Apple silicon.
var products: [Product] = [
    .library(name: "StupidTalkCore", targets: ["StupidTalkCore"])
]
var targets: [Target] = [
    .target(name: "StupidTalkCore"),
    .testTarget(name: "StupidTalkCoreTests", dependencies: ["StupidTalkCore"])
]

#if os(macOS)
products.append(.executable(name: "StupidTalk", targets: ["StupidTalk"]))
targets.append(contentsOf: [
    // transcribe.cpp, the open-source speech engine the Handy app runs on (MIT).
    // scripts/fetch-engine.sh downloads the prebuilt framework and checks its SHA-256.
    .binaryTarget(
        name: "CTranscribe",
        path: "Vendor/TranscribeCpp.xcframework"
    ),
    // Its Swift wrapper, copied unchanged from transcribe.cpp 0.4.2 (bindings/swift). MIT.
    .target(
        name: "TranscribeCpp",
        dependencies: ["CTranscribe"],
        path: "Vendor/TranscribeCpp",
        exclude: ["LICENSE", "THIRD-PARTY-LICENSES.md", "README.md"],
        linkerSettings: [
            .linkedLibrary("c++"),
            .linkedLibrary("z"),
            .linkedFramework("Accelerate"),
            .linkedFramework("Foundation"),
            .linkedFramework("Metal"),
            .linkedFramework("MetalKit")
        ]
    ),
    .executableTarget(
        name: "StupidTalk",
        dependencies: ["StupidTalkCore", "TranscribeCpp"],
        resources: [.copy("Resources")]
    )
])
#endif

let package = Package(
    name: "StupidTalk",
    platforms: [.macOS("26.0")],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
