import SwiftUI
import OracleKit

@main
struct NexusApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .nexus.with(extras: NexusExtras.extras)) }
}
