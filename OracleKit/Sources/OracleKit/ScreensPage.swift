#if os(macOS)
import SwiftUI
import AppKit

/// The hub's Screens page (#62): Nat's displays as macOS arranges them, where the hub itself is, and where each
/// running herdr session's WezTerm window is. Live: a display plugged, unplugged or rearranged redraws at once
/// (didChangeScreenParameters); windows are read again every 2 s. A click on a session's window runs Show in herdr.
public struct ScreensPage: View {
    @ObservedObject var store: HubStore
    let accent: Color
    @State private var displays: [ScreenMap.Display] = []
    @State private var hub: CGRect?
    @State private var windows: [Placed] = []
    // display-census's MouseWatcher / active-watch, in-process: the pointer (NSEvent.mouseLocation needs no
    // permission) and seconds since the last mouse, key or scroll input (CGEventSource, window-arranger's idle clock)
    @State private var spaces: [Space] = []
    @State private var others: [Win] = []                 // every other visible window: click to bring it forward
    @State private var lastFocus: [String: Date] = [:]    // window title → when it last had focus (heat)
    @State private var displayIndex: [Int: Int] = [:]     // CGDirectDisplayID → yabai's display index
    @State private var mouse: CGPoint?
    @State private var idle: Double = 0
    public init(store: HubStore, accent: Color) { self.store = store; self.accent = accent }

    struct Placed: Identifiable, Equatable { let id: Int; let session: String; let rect: CGRect; let front: Bool }
    struct Space: Identifiable, Equatable { let id: Int; let index: Int; let display: Int; let visible: Bool; let focused: Bool; let windows: Int }
    struct Win: Identifiable, Equatable { let id: Int; let app: String; let title: String; let rect: CGRect; let focused: Bool }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("SCREENS").font(.caption.weight(.bold)).tracking(2).foregroundStyle(accent)
                Text("Where everything is").font(.system(size: 30, weight: .bold, design: .rounded))
                Text(summary).font(.callout).foregroundStyle(.secondary)
                GeometryReader { geo in
                    let f = ScreenMap.fit(displays, into: geo.size)
                    ZStack(alignment: .topLeading) {
                        ForEach(displays) { d in
                            let r = ScreenMap.place(d.frame, scale: f.scale, origin: f.origin)
                            RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.11))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(d.main ? Color(red: 0.89, green: 0.70, blue: 0.24) : Color(white: 0.3), lineWidth: d.main ? 2 : 1))
                                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                        }
                        ForEach(others) { w in
                            let r = ScreenMap.place(w.rect, scale: f.scale, origin: f.origin)
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(w.focused ? 0.14 : 0.05))
                                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.white.opacity(w.focused ? 0.7 : 0.22), lineWidth: 1))
                                .overlay(alignment: .topLeading) { Text(w.app).font(.system(size: 9)).foregroundStyle(.secondary).padding(2) }
                                .frame(width: max(r.width, 10), height: max(r.height, 8)).offset(x: r.minX, y: r.minY)
                                .onTapGesture { Task.detached { _ = await Shell.run("yabai", ["-m", "window", String(w.id), "--focus"]) } }
                                .help("\(w.app) — \(w.title) · click to bring it forward")
                        }
                        ForEach(windows) { w in
                            let r = ScreenMap.place(w.rect, scale: f.scale, origin: f.origin)
                            RoundedRectangle(cornerRadius: 3).fill((w.front ? Color.green : Color.secondary).opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(w.front ? Color.green : Color.secondary, lineWidth: 1.5))
                                .overlay { Text("herdr \(w.session)\(w.front ? "" : " · behind")").font(.caption2.weight(.semibold)).padding(3) }
                                .frame(width: max(r.width, 24), height: max(r.height, 14)).offset(x: r.minX, y: r.minY)
                                .onTapGesture { store.openSession(w.session) }
                                .help("Show \(w.session) in herdr")
                        }
                        ForEach(displays) { d in   // names and Space numbers above every window box
                            let r = ScreenMap.place(d.frame, scale: f.scale, origin: f.origin)
                            Color.clear
                                .overlay(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(d.name).font(.caption.weight(.semibold))
                                        HStack(spacing: 3) {
                                            ForEach(spaces.filter { $0.display == (displayIndex[d.id] ?? -1) }) { sp in
                                                Text(verbatim: "\(sp.index)").font(.caption2.monospacedDigit().weight(.bold))
                                                    .frame(minWidth: 16).padding(.vertical, 1)
                                                    .background(RoundedRectangle(cornerRadius: 3).fill(sp.visible ? accent.opacity(sp.focused ? 0.9 : 0.5) : Color(white: 0.2)))
                                                    .foregroundStyle(sp.visible ? Color.white : Color.secondary)
                                                    .onTapGesture { focusSpace(sp.index) }
                                                    .help("Space \(sp.index) · \(sp.windows) window\(sp.windows == 1 ? "" : "s")\(sp.visible ? " · showing" : "") — click to switch to it")
                                            }
                                        }
                                        Text(verbatim: "\(Int(d.frame.width))×\(Int(d.frame.height))\(d.main ? " · main" : "")").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                    }.padding(6)
                                }
                                .frame(width: r.width, height: r.height, alignment: .topLeading).offset(x: r.minX, y: r.minY)
                        }
                        // the pointer on every display frame, and only this dot redraws (the rest of the page does not)
                        MouseDot(scale: f.scale, origin: f.origin)
                        if let hub {
                            let r = ScreenMap.place(hub, scale: f.scale, origin: f.origin)
                            RoundedRectangle(cornerRadius: 3).fill(accent.opacity(0.28))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(accent, lineWidth: 2))
                                .overlay { Text("ARRA Oracles (here)").font(.caption2.weight(.bold)).padding(3) }
                                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .frame(height: 360)
                if !heat.isEmpty {
                    HStack(spacing: 6) {
                        Text("🔥 Heat").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        ForEach(heat, id: \.title) { h in
                            let c: Color = h.tier == "hot" ? Color(red: 0.97, green: 0.44, blue: 0.44) : h.tier == "warm" ? Color(red: 0.98, green: 0.75, blue: 0.14) : Color(white: 0.45)
                            Text(h.title).font(.caption.weight(.medium)).foregroundStyle(c)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(c.opacity(0.12))).overlay(Capsule().strokeBorder(c.opacity(0.3)))
                                .help("\(h.tier) · focused \(Int(h.ago)) s ago — hot within 5 min, warm within 60 (display-census's tiers)")
                        }
                    }
                    Text("Heat counts focus seen while this page is open.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Screens")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in readDisplays() }
        .task {   // the summary's "mouse on …" and idle time: once a second is plenty for words
            while !Task.isCancelled {
                let p = MouseDot.pointer()
                if p != mouse { mouse = p }
                let i = Self.idleSeconds().rounded()
                if i != idle { idle = i }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            readDisplays()
            while !Task.isCancelled { await readWindows(); try? await Task.sleep(for: .seconds(2)) }
        }
    }

    /// display-census's Oracle Heat tiers by last focus: hot within 5 min, warm within 60, cold after; newest first.
    private var heat: [(title: String, tier: String, ago: Double)] {
        let now = Date()
        return lastFocus.map { (title: $0.key, ago: now.timeIntervalSince($0.value)) }
            .sorted { $0.ago < $1.ago }.prefix(12)
            .map { (title: $0.title, tier: $0.ago <= 300 ? "hot" : $0.ago <= 3600 ? "warm" : "cold", ago: $0.ago) }
    }

    /// Switch a display to a Space. window-arranger's server does it without yabai's scripting addition; yabai's own
    /// space --focus is the fallback (it needs the addition).
    private func focusSpace(_ index: Int) {
        Task.detached {
            if let out = await Shell.run("curl", ["-s", "-m", "3", "-X", "POST", "-H", "Content-Type: application/json", "-d", "{}",
                                                  "http://127.0.0.1:8900/api/space/\(index)/focus"]), out.contains("\"ok\":true") { return }
            _ = await Shell.run("yabai", ["-m", "space", "--focus", String(index)])
        }
    }

    /// Idle = no mouse, key or scroll input for this long (display-census's active-watch and window-arranger agree).
    static let idleAfter: Double = 300
    /// Seconds since the last human input, the smallest over mouse, key and scroll (window-arranger's lib/idle.ts).
    static func idleSeconds() -> Double {
        [CGEventType.mouseMoved, .leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
    }

    /// "The hub is on DELL U2719DC · laris-co's herdr window is on DELL S2725QS (front)".
    private var summary: String {
        var parts: [String] = []
        if let hub, let d = ScreenMap.display(of: hub, in: displays) { parts.append("The hub is on \(d.name)") }
        for w in windows {
            parts.append("\(w.session)'s herdr window is on \(ScreenMap.display(of: w.rect, in: displays)?.name ?? "no screen") (\(w.front ? "front" : "behind"))")
        }
        if let m = mouse {
            let on = ScreenMap.display(of: CGRect(origin: m, size: .zero), in: displays)?.name ?? "no screen"
            parts.append("mouse on \(on)" + (idle >= Self.idleAfter ? " · idle \(Int(idle / 60)) min" : idle >= 5 ? " · still \(Int(idle)) s" : ""))
        }
        return parts.isEmpty ? "Reading the screens…" : parts.joined(separator: " · ")
    }

    private func readDisplays() {
        let screens = NSScreen.screens
        let mainH = screens.first?.frame.height ?? 0
        displays = screens.enumerated().map { i, s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? i
            return ScreenMap.Display(id: id, name: s.localizedName, frame: ScreenMap.topLeft(s.frame, mainHeight: mainH), main: i == 0)
        }
        if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { hub = ScreenMap.topLeft(w.frame, mainHeight: mainH) }
    }

    private func readWindows() async {
        readDisplays()   // the hub window may have moved
        var out: [Placed] = []
        for s in store.sessions where s.running {
            switch await WezTerm.clientWindow(session: s.name) {
            case .front(let id, _), .behind(let id, _):
                guard let w = await WezTerm.yabaiJSON(["--windows", "--window", String(id)]) as? [String: Any],
                      let f = w["frame"] as? [String: Double] else { continue }
                let rect = CGRect(x: f["x"] ?? 0, y: f["y"] ?? 0, width: f["w"] ?? 0, height: f["h"] ?? 0)
                if case .front = await WezTerm.clientWindow(session: s.name) { out.append(.init(id: id, session: s.name, rect: rect, front: true)) }
                else { out.append(.init(id: id, session: s.name, rect: rect, front: false)) }
            case .none:
                continue
            }
        }
        if out != windows { windows = out }
        if let ds = await WezTerm.yabaiJSON(["--displays"]) as? [[String: Any]] {
            var m: [Int: Int] = [:]
            for d in ds { if let id = d["id"] as? Int, let i = d["index"] as? Int { m[id] = i } }
            if m != displayIndex { displayIndex = m }
        }
        if let ss = await WezTerm.yabaiJSON(["--spaces"]) as? [[String: Any]] {
            let next = ss.compactMap { s -> Space? in
                guard let id = s["id"] as? Int, let i = s["index"] as? Int, let d = s["display"] as? Int else { return nil }
                return Space(id: id, index: i, display: d, visible: (s["is-visible"] as? Bool) == true,
                             focused: (s["has-focus"] as? Bool) == true, windows: (s["windows"] as? [Any])?.count ?? 0)
            }
            if next != spaces { spaces = next }
        }
        if let ws = await WezTerm.yabaiJSON(["--windows"]) as? [[String: Any]] {
            let herdr = Set(out.map(\.id))
            var next: [Win] = []
            for w in ws where (w["is-visible"] as? Bool) == true && (w["is-minimized"] as? Bool) != true {
                guard let id = w["id"] as? Int, !herdr.contains(id), let f = w["frame"] as? [String: Double] else { continue }
                let app = w["app"] as? String ?? "", title = w["title"] as? String ?? ""
                if app == "ARRA Oracles" { continue }   // the hub draws itself
                next.append(Win(id: id, app: app, title: title, rect: CGRect(x: f["x"] ?? 0, y: f["y"] ?? 0, width: f["w"] ?? 0, height: f["h"] ?? 0),
                                focused: (w["has-focus"] as? Bool) == true))
            }
            if next != others { others = next }
            // heat: the focused window's name — a herdr client is titled "m5: <space>", so it reads as the space
            if let f = ws.first(where: { ($0["has-focus"] as? Bool) == true }) {
                let title = (f["title"] as? String ?? "").replacingOccurrences(of: #"^[^:]{1,20}: "#, with: "", options: .regularExpression)
                let name = (f["app"] as? String) == "WezTerm" ? title : (f["app"] as? String ?? title)
                if !name.isEmpty, name != "zsh" { lastFocus[name] = Date() }
            }
        }
    }
}
#endif


#if os(macOS)
/// The mouse as a dot on the Screens map, read on every display frame (TimelineView .animation): the pointer moves
/// as smoothly as the screen refreshes, and only this view redraws. NSEvent.mouseLocation needs no permission.
struct MouseDot: View {
    let scale: CGFloat
    let origin: CGPoint
    static func pointer() -> CGPoint {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        let m = NSEvent.mouseLocation   // AppKit: bottom-left origin, y up
        return CGPoint(x: m.x, y: mainH - m.y)
    }
    var body: some View {
        TimelineView(.animation) { _ in
            let p = ScreenMap.place(CGRect(origin: Self.pointer(), size: .zero), scale: scale, origin: origin)
            Circle().fill(Color.white).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                .shadow(color: .white.opacity(0.6), radius: 4)
                .offset(x: p.minX - 4.5, y: p.minY - 4.5)
        }
        .allowsHitTesting(false)
    }
}
#endif
