import OracleKit

/// Transcriber's identity — compiled into both the app and its widget.
extension OracleConfig {
    static let transcriber = OracleConfig(
        name: "Transcriber", tagline: "the ear — voice to text", repoSlug: "laris-co/transcriber-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/transcriber-oracle"),
        colorHex: "#26a69a", symbol: "waveform.and.mic")
}
