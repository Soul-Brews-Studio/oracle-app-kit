import SwiftUI

/// Everything that makes one oracle's app different from another's.
/// The library never names a specific oracle; each thin app passes one of these.
public struct OracleConfig: Sendable {
    public var name: String            // "Neo"
    public var tagline: String         // "the builder"
    public var repoSlug: String        // "laris-co/neo-oracle"
    public var localPath: String       // checkout on the Mac; "" on iPad
    public var colorHex: String        // "#64b5f6"
    public var symbol: String          // SF Symbol name
    public var extras: Extras

    public init(name: String, tagline: String, repoSlug: String, localPath: String,
                colorHex: String, symbol: String, extras: Extras = Extras()) {
        self.name = name; self.tagline = tagline; self.repoSlug = repoSlug
        self.localPath = localPath; self.colorHex = colorHex; self.symbol = symbol; self.extras = extras
    }

    public var color: Color { Color(hex: colorHex) }

    /// A Mac checkout path; empty on iPad, where there is no local repo.
    public static func mac(_ path: String) -> String {
        #if os(macOS)
        return path
        #else
        return ""
        #endif
    }
    public var inboxPath: String { localPath.isEmpty ? "" : localPath + "/ψ/inbox" }

    /// Set once by the app before its scene is built (the delegate reads it).
    nonisolated(unsafe) public static var current = OracleConfig(
        name: "Oracle", tagline: "", repoSlug: "", localPath: "", colorHex: "#64b5f6", symbol: "circle")
}

/// View slots an app may fill — the FloodBoyKit pattern: the app plugs in, the library has no #if per oracle.
public struct Extras: Sendable {
    public var sections: [ExtraSection]
    public init(sections: [ExtraSection] = []) { self.sections = sections }
}

public struct ExtraSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let view: @Sendable @MainActor () -> AnyView
    public init(id: String, title: String, symbol: String, view: @escaping @Sendable @MainActor () -> AnyView) {
        self.id = id; self.title = title; self.symbol = symbol; self.view = view
    }
}

public extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x64b5f6
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
