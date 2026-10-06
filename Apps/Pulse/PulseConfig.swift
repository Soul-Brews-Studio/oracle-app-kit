import OracleKit

/// Pulse's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let pulse = OracleConfig(
        name: "Pulse", tagline: "the heartbeat — PM", repoSlug: "laris-co/pulse",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/pulse"),
        colorHex: "#ef5350", symbol: "waveform.path.ecg")
}
