// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "gazectl",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "gazectl",
            path: "Sources",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Info.plist",
                ]),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Vision"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
