import SwiftUI
import OracleKit

@main
struct PulseApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .pulse) }
}

extension OracleConfig {
    static let pulse = OracleConfig(
        name: "Pulse", tagline: "the heartbeat — PM", repoSlug: "laris-co/pulse",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/pulse"),
        colorHex: "#ef5350", symbol: "waveform.path.ecg",
        extras: PulseExtras.extras)
}
