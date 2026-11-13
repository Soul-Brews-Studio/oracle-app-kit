import SwiftUI
import OracleKit
#if os(macOS)
import OracleTerminal
#endif

@main
struct Relic5App: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .relic5.with(extras: Relic5Extras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        OracleTerminal.install()   // the Work drawer draws panes live; Type to control them
        MCPServer.serve(name: "relic5-memory", port: 4797) { GHIndex.history(OracleConfig.relic5.repoSlug) }   // agents search Relic5's memory
        CompanionServer.serve(name: "Relic5", mcpPort: 4797) { GHIndex.history(OracleConfig.relic5.repoSlug) }   // its iPhone/iPad app reads this Mac (Settings → Companion)
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
