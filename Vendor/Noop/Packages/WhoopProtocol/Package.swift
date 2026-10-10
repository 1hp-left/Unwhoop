// swift-tools-version: 5.9
//
// Trimmed for Unwhoop's vendored copy (see Vendor/Noop/FORK_PLAN.md): the
// upstream Package.swift also declares executable and test targets, which
// Unwhoop does not build. Only the WhoopProtocol library (with its bundled
// whoop_protocol.json resource) is kept. Upstream file, verbatim, is at
// Packages/WhoopProtocol/Package.swift in the Noop repo at the pinned commit.
import PackageDescription

let package = Package(
    name: "WhoopProtocol",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "WhoopProtocol", targets: ["WhoopProtocol"]),
    ],
    targets: [
        .target(
            name: "WhoopProtocol",
            resources: [.process("Resources/whoop_protocol.json")]
        ),
    ]
)
