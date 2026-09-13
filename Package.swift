// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Workaround for this machine's Command Line Tools-only toolchain (no Xcode installed):
// SwiftPM adds the Swift Testing framework's directory as a module search path (-I) instead
// of a framework search path (-F), so `import Testing` fails to resolve with "no such module
// 'Testing'". Testing.framework only exists there in this configuration, so pass it explicitly
// as a framework search path for the test target. No-op if the path is absent (e.g. on a
// machine with full Xcode, where Swift Testing resolves normally).
let clTestingFrameworksDir = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let clTestingInteropLibDir = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let clTestingFrameworkExists = FileManager.default.fileExists(atPath: "\(clTestingFrameworksDir)/Testing.framework")
let testSwiftSettings: [SwiftSetting] = clTestingFrameworkExists
    ? [.unsafeFlags(["-F", clTestingFrameworksDir])]
    : []
let testLinkerSettings: [LinkerSetting] = clTestingFrameworkExists
    ? [.unsafeFlags([
        "-F", clTestingFrameworksDir,
        "-Xlinker", "-rpath", "-Xlinker", clTestingFrameworksDir,
        "-Xlinker", "-rpath", "-Xlinker", clTestingInteropLibDir,
      ])]
    : []

let package = Package(
    name: "Cicero",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "CiceroKit"),
        .testTarget(
            name: "CiceroKitTests",
            dependencies: ["CiceroKit"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
