import SwiftUI
import OracleKit
#if os(macOS)
import OracleTerminal
#endif

@main
struct TranscriberApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .transcriber.with(extras: TranscriberExtras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        OracleTerminal.install()   // the Work drawer draws panes live; Type to control them
        MCPServer.serve(name: "transcriber-memory", port: 4796) { GHIndex.history(OracleConfig.transcriber.repoSlug) }   // agents search Transcriber's memory
        CompanionServer.serve(name: "Transcriber", mcpPort: 4796) { GHIndex.history(OracleConfig.transcriber.repoSlug) }   // its iPhone/iPad app reads this Mac (Settings → Companion)
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
