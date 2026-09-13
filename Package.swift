// swift-tools-version: 6.0
import PackageDescription

// Swift Testing ships with the Command Line Tools, but its framework is only on
// the search path for `testTarget`s — and a testTarget is useless on this
// machine, because running one requires Xcode's `xctest` binary. Test targets
// are therefore plain executables with an @main entry point, and they need
// these flags to find Swift Testing at compile time and load it at run time.
// Defined once here; every runner target reuses them.
let testingFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testingInteropLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let testRunnerSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-F", testingFrameworks])
]

let testRunnerLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-F", testingFrameworks,
        "-framework", "Testing",
        "-Xlinker", "-rpath", "-Xlinker", testingFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", testingInteropLibs,
    ])
]

let package = Package(
    name: "Cicero",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(name: "CiceroKit"),
        .executableTarget(
            name: "CiceroKitTests",
            dependencies: ["CiceroKit"],
            path: "Tests/CiceroKitTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
        .target(name: "CiceroAudio", dependencies: ["CiceroKit"]),
        .executableTarget(
            name: "CiceroAudioTests",
            dependencies: ["CiceroAudio", "CiceroKit"],
            path: "Tests/CiceroAudioTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
        .target(name: "CiceroWhisper", dependencies: [
            "CiceroKit",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .executableTarget(
            name: "CiceroWhisperTests",
            dependencies: ["CiceroWhisper", "CiceroKit"],
            path: "Tests/CiceroWhisperTests",
            swiftSettings: testRunnerSwiftSettings,
            linkerSettings: testRunnerLinkerSettings
        ),
    ]
)
