import SwiftUI
import OracleKit

@main
struct PulseApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    var body: some Scene { OracleScene(config: .pulse.with(extras: PulseExtras.extras)) }
}
