import SwiftUI
import Security

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
    /// The bundle-id suffix, App Group, URL scheme and portal key: co.laris.oracle.<key>. nil = name.lowercased()
    /// (Neo, Pulse, Nexus). Set for a hyphenated repo, whose key cannot be a Swift name (DustBoy-Phd → dustboy-phd).
    public var key: String?

    public init(name: String, tagline: String, repoSlug: String, localPath: String,
                colorHex: String, symbol: String, extras: Extras = Extras(), key: String? = nil) {
        self.name = name; self.tagline = tagline; self.repoSlug = repoSlug
        self.localPath = localPath; self.colorHex = colorHex; self.symbol = symbol; self.extras = extras; self.key = key
    }

    public var appKey: String { key ?? name.lowercased() }
    /// The URL scheme the app owns: oracle-<key>://
    public var scheme: String { "oracle-" + appKey }

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

    /// App Group shared by this oracle's app and its widget (team-prefixed, as macOS expects). Read from this
    /// process's own signed entitlements, so an app signed by another team finds its group; the literal is the
    /// fallback for an unsigned run.
    public var widgetGroup: String {
        #if os(iOS)
        "group.co.laris.oracle." + appKey      // iOS names a group group.<id>; there is no team prefix
        #else
        OracleConfig.signedGroups.first { $0.hasSuffix(".co.laris.oracle." + appKey) } ?? "6K28WEXX78.co.laris.oracle." + appKey
        #endif
    }
    /// The widget extension's bundle id — its sandbox container is the one path it can surely read.
    public var widgetBundleId: String { "co.laris.oracle." + appKey + ".widget" }

    /// com.apple.security.application-groups of the running process, as signed.
    static let signedGroups: [String] = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        else { return [] }
        return (v as? [String]) ?? []
        #else
        return []
        #endif
    }()

    /// The key of the app or extension this code runs in, from its bundle id (co.laris.oracle.<key>[.widget|.share]).
    public static var bundleKey: String? {
        guard let id = Bundle.main.bundleIdentifier, id.hasPrefix("co.laris.oracle.") else { return nil }
        return id.dropFirst("co.laris.oracle.".count).split(separator: ".").first.map(String.init)
    }

    /// The same identity with an app's own panels attached (the widget target uses the bare config).
    public func with(extras: Extras) -> OracleConfig { var c = self; c.extras = extras; return c }

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
