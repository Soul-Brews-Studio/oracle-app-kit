import OracleKit

/// Nexus's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let nexus = OracleConfig(
        name: "Nexus", tagline: "the telescope — research", repoSlug: "laris-co/nexus-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/nexus-oracle"),
        colorHex: "#ab47bc", symbol: "scope")
}
