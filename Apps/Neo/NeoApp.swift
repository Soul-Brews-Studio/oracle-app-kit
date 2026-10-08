import SwiftUI
import OracleKit
#if os(macOS)
import OracleTerminal
#endif

@main
struct NeoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .neo.with(extras: NeoExtras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        OracleTerminal.install()   // the Work drawer draws panes live; Type to control them
        MCPServer.serve(name: "neo-memory", port: 4791) { GHIndex.history(OracleConfig.neo.repoSlug) }   // agents search Neo's memory
        CompanionServer.serve(name: "Neo", mcpPort: 4791) { GHIndex.history(OracleConfig.neo.repoSlug) }   // its iPhone/iPad app reads this Mac (Settings → Companion)
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
