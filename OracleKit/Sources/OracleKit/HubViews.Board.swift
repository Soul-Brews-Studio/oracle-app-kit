#if os(macOS)
import SwiftUI
import WebKit

// MARK: - The herdr board inside the hub (Nat, 2026-10-10: "build to start by clicking and serve this server")
//
// The board is neo-oracle's tools/herdr-board: a Bun server on 127.0.0.1:4330 with a React page. This page starts it
// when it is down (`herdr-board`, detached, so it outlives the hub) and shows it in a web view.

public enum HerdrBoard {
    public static let url = URL(string: "http://127.0.0.1:" + (ProcessInfo.processInfo.environment["HERDR_BOARD_PORT"] ?? "4330"))!
    static var log: String { NSHomeDirectory() + "/Library/Logs/ARRA Oracles/herdr-board.log" }

    /// Whether the board answers now.
    public static func up() async -> Bool {
        var r = URLRequest(url: url); r.timeoutInterval = 1.5
        return (try? await URLSession.shared.data(for: r)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    /// Start the board when it is down and wait until it answers (≤ 45 s: the first start bundles the page).
    /// nil once it answers, else what failed with the command to run.
    public static func ensure() async -> String? {
        if await up() { return nil }
        guard let tool = Shell.which("herdr-board") else {
            return "herdr-board is not installed — run:  ln -s <neo-oracle>/tools/herdr-board/bin/herdr-board ~/.local/bin/herdr-board"
        }
        let path = Shell.searchPaths.joined(separator: ":")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // detached, without the hub's HERDR_* (a socket path there would point the board at one session)
        _ = await Shell.run("sh", ["-c", "env -u HERDR_SOCKET_PATH -u HERDR_PANE_ID -u HERDR_SESSION PATH=\(q(path)) nohup \(q(tool)) >>\(q(log)) 2>&1 &"])
        for _ in 0..<90 {
            if await up() { return nil }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return "the board did not answer on \(url.absoluteString) within 45 s — see \(log), or run:  herdr-board"
    }
}

struct BoardPage: View {
    @State private var ready = false
    @State private var problem: String?
    @State private var reloadTick = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("herdr board").font(.custom("Avenir Next", size: 15).weight(.semibold))
                Text(HerdrBoard.url.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { reloadTick += 1 }.controlSize(.small).handCursor()
                Button("Open in browser") { NSWorkspace.shared.open(HerdrBoard.url) }.controlSize(.small).handCursor()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if ready {
                BoardWeb(url: HerdrBoard.url, tick: reloadTick)
            } else {
                VStack(spacing: 10) {
                    if let problem {
                        Text(problem).font(.callout).foregroundStyle(.orange).textSelection(.enabled).multilineTextAlignment(.center)
                        Button("Try again") { Task { await start() } }.handCursor()
                    } else {
                        ProgressView(); Text("starting the herdr board…").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            }
        }
        .navigationTitle("Board")
        .task { await start() }
    }

    private func start() async {
        problem = nil
        problem = await HerdrBoard.ensure()
        ready = problem == nil
    }
}

/// The board's page in a WKWebView; `tick` changes reload it.
struct BoardWeb: NSViewRepresentable {
    let url: URL
    let tick: Int
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.setValue(false, forKey: "drawsBackground")   // the board's own dark background, no white flash
        v.load(URLRequest(url: url))
        context.coordinator.tick = tick
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        if context.coordinator.tick != tick { context.coordinator.tick = tick; v.reload() }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var tick = 0 }
}
#endif
