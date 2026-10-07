import SwiftUI
import OracleKit

@main
struct NexusApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .nexus.with(extras: NexusExtras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        MCPServer.serve(name: "nexus-memory", port: 4793) { GHIndex.history(OracleConfig.nexus.repoSlug) }   // agents search Nexus's memory
        CompanionServer.serve(name: "Nexus", mcpPort: 4793) { GHIndex.history(OracleConfig.nexus.repoSlug) }   // its iPhone/iPad app reads this Mac (Settings → Companion)
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
