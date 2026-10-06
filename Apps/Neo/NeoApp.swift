import SwiftUI
import OracleKit

@main
struct NeoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .neo) }
}

extension OracleConfig {
    static let neo = OracleConfig(
        name: "Neo", tagline: "the builder", repoSlug: "laris-co/neo-oracle",
        localPath: OracleConfig.mac("/opt/Code/github.com/laris-co/neo-oracle"),
        colorHex: "#64b5f6", symbol: "chevron.left.forwardslash.chevron.right",
        extras: NeoExtras.extras)
}
