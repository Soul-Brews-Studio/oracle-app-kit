// swift-tools-version:5.9
import PackageDescription

// The hub's live terminal: Ghostty (libghostty), the engine Heeler (herdr's iOS companion) draws herdr panes
// with, fed by OracleKit's HerdrStream. Only the hub links it: the oracle apps and their widgets stay without
// Ghostty's 77 MB framework.
let package = Package(
    name: "OracleTerminal",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OracleTerminal", targets: ["OracleTerminal"])],
    dependencies: [
        .package(path: "../OracleKit"),
        // Heeler's pin (its project.yml): libghostty-spm 1.6.20260909, prebuilt libghostty 82938b633ba6
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", revision: "7e45d27160f9b34aca9ca5c9820e9207482f9f04"),
    ],
    targets: [
        .target(name: "OracleTerminal", dependencies: [
            .product(name: "OracleKit", package: "OracleKit"),
            .product(name: "GhosttyTerminal", package: "libghostty-spm"),
        ]),
    ]
)
