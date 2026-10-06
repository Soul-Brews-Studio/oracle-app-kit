import SwiftUI
import OracleKit

@main
struct NexusApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .nexus) }
}

extension OracleConfig {
    static let nexus = OracleConfig(
        name: "Nexus", tagline: "the telescope — research", repoSlug: "laris-co/nexus-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/nexus-oracle"),
        colorHex: "#ab47bc", symbol: "scope",
        extras: NexusExtras.extras)
}
