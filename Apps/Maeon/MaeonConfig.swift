import OracleKit

/// Maeon's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let maeon = OracleConfig(
        name: "Maeon", tagline: "Flow like the river, stand like the mountain, craft with data", repoSlug: "MaeOn-Lab/maeon-craft-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/maeon-craft-oracle"),
        colorHex: "#F4B33A", symbol: "mug.fill", key: "maeon-craft")
}
