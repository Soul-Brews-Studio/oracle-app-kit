import OracleKit

/// Athena's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let athena = OracleConfig(
        name: "Athena", tagline: "The Loom of Wisdom", repoSlug: "laris-co/athena-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/athena-oracle"),
        colorHex: "#d4a72c", symbol: "building.columns")
}
