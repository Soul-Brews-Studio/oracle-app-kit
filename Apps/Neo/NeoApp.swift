import SwiftUI
import OracleKit

@main
struct NeoApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .neo.with(extras: NeoExtras.extras)) }
}
