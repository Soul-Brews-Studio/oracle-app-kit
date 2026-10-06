import OracleKit

/// Neo's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let neo = OracleConfig(
        name: "Neo", tagline: "the builder", repoSlug: "laris-co/neo-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/neo-oracle"),
        colorHex: "#64b5f6", symbol: "chevron.left.forwardslash.chevron.right")
}
