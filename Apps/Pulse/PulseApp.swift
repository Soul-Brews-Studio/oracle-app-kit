import SwiftUI
import OracleKit
#if os(macOS)
import OracleTerminal
#endif

@main
struct PulseApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .pulse.with(extras: PulseExtras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        OracleTerminal.install()   // the Work drawer draws panes live; Type to control them
        MCPServer.serve(name: "pulse-memory", port: 4792) { GHIndex.history(OracleConfig.pulse.repoSlug) }   // agents search Pulse's memory
        CompanionServer.serve(name: "Pulse", mcpPort: 4792) { GHIndex.history(OracleConfig.pulse.repoSlug) }   // its iPhone/iPad app reads this Mac (Settings → Companion)
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
