#if os(iOS)
import SwiftUI

/// Pairing the phone with an oracle app on the Mac (issue #46). STUB — the client builder replaces these bodies:
/// scan the Mac's QR code (VisionKit) or paste its pairing link, then CompanionClient.pair checks /v1/hello.
public struct CompanionPairView: View {
    public init() {}
    public var body: some View { Text("Pair with your Mac: on the Mac, Settings → Companion, then scan its code.").padding() }
}

/// The pairing, as a Settings section: which Mac, its app version, Unpair, Pair again. STUB.
public struct CompanionSettingsSection: View {
    public init() {}
    public var body: some View { Section("Companion") { Text("not paired") } }
}

extension CompanionClient {
    /// An opened pairing link (oracle-<name>://pair?…). STUB: true when it paired.
    public func handle(url: URL) async -> Bool {
        guard let p = CompanionAPI.Pairing.parse(url) else { return false }
        return await pair(p)
    }
}
#endif
