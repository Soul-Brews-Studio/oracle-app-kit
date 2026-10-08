import SwiftUI
import OracleKit
#if os(macOS)
import OracleTerminal
#endif

@main
struct MaeonApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .maeon.with(extras: MaeonExtras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        OracleTerminal.install()   // the Work drawer draws panes live; Type to control them
        MCPServer.serve(name: "maeon-memory", port: 4795) { GHIndex.history(OracleConfig.maeon.repoSlug) }   // agents search Maeon's memory
        CompanionServer.serve(name: "Maeon", mcpPort: 4795) { GHIndex.history(OracleConfig.maeon.repoSlug) }   // its iPhone/iPad app reads this Mac (Settings → Companion)
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
