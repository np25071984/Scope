// swift-tools-version:5.9
//
// build.sh builds and signs the `scope` binary. Signing matters: macOS ties
// the Accessibility permission to the binary's path and signature.

import PackageDescription

let package = Package(
    name: "scope",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "scope",
            path: "Sources/Scope",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(
            name: "scopeTests",
            dependencies: ["scope"],
            path: "Tests/scopeTests"
        ),
    ]
)
