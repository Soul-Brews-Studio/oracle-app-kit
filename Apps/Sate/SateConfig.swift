import OracleKit

/// Sate's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let sate = OracleConfig(
        name: "Sate", tagline: "Prof. (Practice) Dr. Sate Sampattagul — every number traces to a file", repoSlug: "laris-co/proof-sate-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/proof-sate-oracle"),
        colorHex: "#e46b2a", symbol: "scope", key: "proof-sate")
}
