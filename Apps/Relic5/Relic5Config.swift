import OracleKit

/// Relic5's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let relic5 = OracleConfig(
        name: "Relic5", tagline: "Every machine's Claude Code and Codex history, and what Hindsight learned from it", repoSlug: "Soul-Brews-Studio/relic5",
        localPath: OracleConfig.mac("/opt/Code/github.com/Soul-Brews-Studio/relic5"),
        colorHex: "#FF3CAC", symbol: "clock.arrow.circlepath")
}
