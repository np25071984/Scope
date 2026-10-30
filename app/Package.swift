// swift-tools-version:5.9
//
// Built into Scope.app by build.sh; `swift build` alone produces a bare
// executable, which runs but has no bundle to hold an Accessibility grant.

import PackageDescription

let package = Package(
    name: "Scope",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Scope",
            path: "Sources/Scope",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
    ]
)
