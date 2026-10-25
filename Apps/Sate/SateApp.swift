import SwiftUI
import OracleKit
#if os(macOS)
import OracleTerminal
#endif

@main
struct SateApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .sate.with(extras: SateExtras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        OracleTerminal.install()   // the Work drawer draws panes live; Type to control them
        MCPServer.serve(name: "sate-memory", port: 4797) { GHIndex.history(OracleConfig.sate.repoSlug) }   // agents search Sate's memory
        CompanionServer.serve(name: "Sate", mcpPort: 4797) { GHIndex.history(OracleConfig.sate.repoSlug) }   // its iPhone/iPad app reads this Mac (Settings → Companion)
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
