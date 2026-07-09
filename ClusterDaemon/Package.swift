// swift-tools-version:5.9
import PackageDescription

// Headless cluster-peer daemon for MetroSystem.
//
// A self-contained SwiftPM executable -- no external dependencies, so it
// builds offline with `swift build` / `swift run`. It is deliberately kept
// as a SEPARATE tree from the XcodeGen-driven macOS app: the app links
// SwiftUI / SceneKit / AppKit, whereas this daemon only needs Foundation
// and Network.framework.
//
// The handful of wire types it shares with the app (the peer protocol and
// the Train model) are mirrored here rather than cross-imported; keep them
// in sync with Sources/MetroSystem/Networking/Protocol.swift and
// Sources/MetroSystem/Models/{Train,Constants}.swift (the pairs are listed
// in README.md).
let package = Package(
    name: "MetroClusterDaemon",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "metro-clusterd", targets: ["MetroClusterDaemon"])
    ],
    targets: [
        .executableTarget(
            name: "MetroClusterDaemon",
            path: "Sources/MetroClusterDaemon"
        )
    ]
)
