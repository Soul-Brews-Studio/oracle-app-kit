// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OracleKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "OracleKit", targets: ["OracleKit"])],
    targets: [
        .target(name: "OracleKit"),
        .testTarget(name: "OracleKitTests", dependencies: ["OracleKit"]),
    ]
)
