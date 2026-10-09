import Foundation
#if os(macOS)
import AppKit
#endif

#if os(macOS)
/// WezTerm hosts the herdr clients. Its CLI finds the pane that runs `herdr [--session S]` and brings it forward.
public enum WezTerm {
    public static let bundleId = "com.github.wez.wezterm"

    /// Bring the session to Nat: find the WezTerm window that shows it (herdr titles its client
    /// "<host>: <space>"), move it to the main display's visible space, centre it and focus it — Window
    /// Arranger's ⌘⏎ "ย้ายมา". No client yet: open one in a new WezTerm window and bring that. No yabai: the
    /// WezTerm CLI alone (activate the client pane, or spawn one) and raise WezTerm.
    public static func show(session: String, label: String? = nil) async {
        let yabai = Shell.which("yabai") != nil
        var window: Int?
        if yabai, let label {
            try? await Task.sleep(nanoseconds: 350_000_000)          // herdr retitles the client after the focus
            window = await yabaiWindow(titled: { $0 == label || $0.hasSuffix(": " + label) })
        }
        let clients = await panes(running: session)
        if window == nil, yabai, let c = clients.first {
            window = await yabaiWindow(titled: { $0 == c.windowTitle })
        }
        if window == nil {
            if let c = clients.first {
                _ = await Shell.run("wezterm", ["cli", "activate-pane", "--pane-id", String(c.pane)])
            } else {
                let before = Set(await weztermWindows())
                var args = ["cli", "spawn", "--new-window", "--", Shell.which("herdr") ?? "herdr"]
                if session != "default" { args += ["--session", session] }
                _ = await Shell.run("wezterm", args)
                for _ in 0..<12 where yabai && window == nil {          // the new window shows up within ~1 s
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    window = await weztermWindows().first { !before.contains($0) }
                }
            }
        }
        if let window { await bringToMain(window) }
        else { await MainActor.run { _ = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate() } }
    }

    /// Where the WezTerm window holding a session's herdr client is, as Nat sees it (Nat, 2026-10-08: "2 modes —
    /// active on some window, not active (behind) some window").
    public enum ClientWindow: Equatable, Sendable {
        case front(window: Int, screen: String)    // visible: on a shown space, not minimised, at most half covered
        case behind(window: Int, screen: String)   // covered by other windows, on a hidden space, or minimised
        case none                                  // no WezTerm window runs this session's client
        public var label: String {
            switch self {
            case .front(_, let s): return "front · \(s)"
            case .behind(_, let s): return "behind · \(s)"
            case .none: return "no window"
            }
        }
    }

    /// The state of `session`'s client window. "Covered" samples a 12×12 grid of the window's rectangle against
    /// the on-screen windows above it (the window list is front to back), so overlaps are not counted twice.
    public static func clientWindow(session: String) async -> ClientWindow {
        guard Shell.which("yabai") != nil else { return .none }
        var id: Int?
        for c in await panes(running: session) { if let w = await yabaiWindow(titled: { $0 == c.windowTitle }) { id = w; break } }
        guard let id, let win = await yabaiJSON(["--windows", "--window", String(id)]) as? [String: Any] else { return .none }
        let screen = await screenName(display: win["display"] as? Int)
        if (win["is-visible"] as? Bool) != true || (win["is-minimized"] as? Bool) == true { return .behind(window: id, screen: screen) }
        return covered(window: id) > 0.5 ? .behind(window: id, screen: screen) : .front(window: id, screen: screen)
    }

    /// The share of a window hidden by the normal windows above it (0…1).
    static func covered(window id: Int) -> Double {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return 0 }
        func rect(_ w: [String: Any]) -> CGRect? {
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        }
        let normal = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        guard let i = normal.firstIndex(where: { ($0[kCGWindowNumber as String] as? Int) == id }), let r = rect(normal[i]), r.width > 0, r.height > 0 else { return 0 }
        let above = normal[..<i].compactMap(rect)
        var hit = 0, n = 12
        for a in 0..<n { for b in 0..<n {
            let p = CGPoint(x: r.minX + (CGFloat(a) + 0.5) * r.width / CGFloat(n), y: r.minY + (CGFloat(b) + 0.5) * r.height / CGFloat(n))
            if above.contains(where: { $0.contains(p) }) { hit += 1 }
        } }
        return Double(hit) / Double(n * n)
    }

    /// A display's name ("DELL S2725QS") from yabai's display index; "screen #n" when macOS does not say.
    static func screenName(display index: Int?) async -> String {
        guard let index, let displays = await yabaiJSON(["--displays"]) as? [[String: Any]],
              let d = displays.first(where: { ($0["index"] as? Int) == index }), let cg = d["id"] as? Int else { return "screen #\(index ?? 0)" }
        return await MainActor.run {
            NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue == cg }?.localizedName
        } ?? "screen #\(index)"
    }

    /// The yabai display index of the screen the hub's own window is on (nil: no window).
    @MainActor static func hubDisplayID() -> Int? {
        (NSApp.mainWindow?.screen ?? NSApp.windows.first(where: \.isVisible)?.screen)?
            .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")].flatMap { ($0 as? NSNumber)?.intValue }
    }

    /// The CGDirectDisplayID of the screen a yabai window is on.
    static func displayID(window id: Int) async -> Int? {
        guard let win = await yabaiJSON(["--windows", "--window", String(id)]) as? [String: Any], let index = win["display"] as? Int,
              let displays = await yabaiJSON(["--displays"]) as? [[String: Any]] else { return nil }
        return displays.first { ($0["index"] as? Int) == index }?["id"] as? Int
    }

    /// Move a window to the display THIS app's window is on — "bring here" means here (Nat, 2026-10-09: "it should
    /// same the display of app") — centred on that display's visible space, and focus it. With no app window on screen,
    /// the main display (the one at the origin).
    static func bringToMain(_ id: Int) async {
        let appDisplay = await MainActor.run { hubDisplayID() }
        guard let displays = await yabaiJSON(["--displays"]) as? [[String: Any]],
              let main = Self.target(displays, appDisplay: appDisplay),
              let index = main["index"] as? Int, let frame = main["frame"] as? [String: Double],
              let spaces = await yabaiJSON(["--spaces", "--display", String(index)]) as? [[String: Any]],
              let here = spaces.first(where: { ($0["is-visible"] as? Bool) == true })?["index"] as? Int,
              let win = await yabaiJSON(["--windows", "--window", String(id)]) as? [String: Any] else {
            _ = await Shell.run("yabai", ["-m", "window", String(id), "--focus"]); return
        }
        if (win["space"] as? Int) != here {
            _ = await Shell.run("yabai", ["-m", "window", String(id), "--space", String(here)])
            let wf = win["frame"] as? [String: Double] ?? [:]
            if let w = wf["w"], let h = wf["h"], let x = frame["x"], let y = frame["y"], let W = frame["w"], let H = frame["h"] {
                _ = await Shell.run("yabai", ["-m", "window", String(id), "--move", "abs:\(Int(x + (W - w) / 2)):\(Int(y + (H - h) / 2))"])
            }
        }
        _ = await Shell.run("yabai", ["-m", "window", String(id), "--focus"])
    }

    /// Which yabai display "bring here" aims at: the one whose CGDirectDisplayID (`id`) is the app window's screen,
    /// else the main display (frame at the origin), else display 1.
    static func target(_ displays: [[String: Any]], appDisplay: Int?) -> [String: Any]? {
        if let appDisplay, let d = displays.first(where: { ($0["id"] as? Int) == appDisplay }) { return d }
        return displays.first(where: { d in let f = d["frame"] as? [String: Double]; return f?["x"] == 0 && f?["y"] == 0 })
            ?? displays.first(where: { ($0["index"] as? Int) == 1 })
    }

    static func yabaiJSON(_ query: [String]) async -> Any? {
        guard let out = await Shell.run("yabai", ["-m", "query"] + query) else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(out.utf8))
    }

    static func weztermWindows() async -> [Int] {
        (await yabaiJSON(["--windows"]) as? [[String: Any]] ?? [])
            .filter { ($0["app"] as? String) == "WezTerm" }.compactMap { $0["id"] as? Int }
    }

    static func yabaiWindow(titled match: (String) -> Bool) async -> Int? {
        (await yabaiJSON(["--windows"]) as? [[String: Any]] ?? []).first { w in
            (w["app"] as? String) == "WezTerm" && (w["title"] as? String).map(match) == true
        }?["id"] as? Int
    }

    /// WezTerm panes whose terminal runs a local herdr client attached to `session`, with their window's title.
    public static func panes(running session: String) async -> [(pane: Int, windowTitle: String)] {
        await panes { herdrSession(of: $0) == session }
    }

    /// WezTerm panes running a process whose command line passes `match`.
    static func panes(where match: (String) -> Bool) async -> [(pane: Int, windowTitle: String)] {
        guard let json = await Shell.run("wezterm", ["cli", "list", "--format", "json"]),
              let list = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] else { return [] }
        var out: [(pane: Int, windowTitle: String)] = []
        for p in list {
            guard let id = p["pane_id"] as? Int, let tty = (p["tty_name"] as? String)?.replacingOccurrences(of: "/dev/", with: "") else { continue }
            let ps = await Shell.run("ps", ["-o", "args=", "-t", tty]) ?? ""
            if ps.split(separator: "\n").contains(where: { match(String($0)) }) {
                out.append((id, p["window_title"] as? String ?? ""))
            }
        }
        return out
    }

    /// A remote session to Nat: the WezTerm window already attached to it, or a new one running
    /// `herdr --remote <target> --session <s>`; moved to the main display and focused, as `show(session:)` does.
    /// A new WezTerm window running `herdr <args>`, for a herdr command that may ask something (`herdr machine add`).
    public static func run(_ args: [String]) async {
        _ = await Shell.run("wezterm", ["cli", "spawn", "--new-window", "--", Shell.which("herdr") ?? "herdr"] + args)
        await MainActor.run { _ = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate() }
    }

    public static func show(remote r: RemoteSession) async {
        let yabai = Shell.which("yabai") != nil
        var window: Int?
        let clients = await panes { RemoteParse.remote(of: $0)?.id == r.id }
        if let c = clients.first {
            if yabai { window = await yabaiWindow(titled: { $0 == c.windowTitle }) }
            if window == nil { _ = await Shell.run("wezterm", ["cli", "activate-pane", "--pane-id", String(c.pane)]) }
        } else {
            let before = Set(await weztermWindows())
            _ = await Shell.run("wezterm", ["cli", "spawn", "--new-window", "--", Shell.which("herdr") ?? "herdr"] + r.arguments)
            for _ in 0..<12 where yabai && window == nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                window = await weztermWindows().first { !before.contains($0) }
            }
        }
        if let window { await bringToMain(window) }
        else { await MainActor.run { _ = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first?.activate() } }
    }

    /// "herdr --session ccdc" → "ccdc", a bare "herdr" → "default"; remote clients and one-shot CLI calls → nil.
    public static func herdrSession(of args: String) -> String? {
        let f = args.split(separator: " ").map(String.init)
        guard let first = f.first, (first as NSString).lastPathComponent == "herdr", !f.contains("--remote") else { return nil }
        if let i = f.firstIndex(of: "--session"), i + 1 < f.count { return f.count == i + 2 ? f[i + 1] : nil }
        return f.count == 1 ? "default" : nil
    }
}
#endif
