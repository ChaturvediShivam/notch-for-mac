// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Notch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Notch", targets: ["Notch"]),
        // Loaded at runtime by /usr/bin/perl for Now Playing (see MediaService), never linked.
        .library(name: "NotchMediaRemote", type: .dynamic, targets: ["NotchMediaRemote"]),
    ],
    targets: [
        .executableTarget(name: "Notch", path: "Sources/Notch"),
        .target(name: "NotchMediaRemote", path: "Sources/NotchMediaRemote",
                cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Foundation")]),
    ]
)
