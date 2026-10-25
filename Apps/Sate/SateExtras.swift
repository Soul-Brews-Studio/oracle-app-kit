import SwiftUI
import OracleKit
import WebKit

/// Sate's own panels: the proof site (Scene, Analysis, Terrain, Volume, Graph) inside the app.
enum SateExtras {
    static let extras = Extras(sections: [
        ExtraSection(id: "proof", title: "Proof", symbol: "scope") { AnyView(ProofSiteView()) }
    ])
}

/// The proof site's pages. The full site lives on the tailnet; when that address does not answer, the scrubbed
/// public copy is shown instead and the toolbar says so.
struct ProofSiteView: View {
    static let tailnet = URL(string: "http://100.111.101.21:8790/site/")!
    static let publicCopy = URL(string: "https://proof-sate-oracle.laris.workers.dev/site/")!
    static let pages: [(id: String, title: String, file: String)] = [
        ("scene", "Scene", ""), ("analysis", "Analysis", "insight.html"), ("terrain", "Terrain", "terrain.html"),
        ("volume", "Volume", "space.html"), ("graph", "Graph", "graph.html"),
    ]
    @State private var page = "scene"
    @State private var base: URL? = nil
    @State private var reload = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Page", selection: $page) {
                    ForEach(Self.pages, id: \.id) { Text($0.title).tag($0.id) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
                Spacer()
                if let base {
                    Text(base == Self.tailnet ? "tailnet · full site" : "public copy · tailnet not reachable")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                    Link(destination: url(base)) { Image(systemName: "safari") }.help("Open in the browser")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if let base {
                WebPage(url: url(base), reload: reload)
            } else {
                ProgressView("Finding the proof site…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Proof")
        .task { base = await Self.reachable() }
    }

    private func url(_ base: URL) -> URL {
        let file = Self.pages.first { $0.id == page }?.file ?? ""
        return file.isEmpty ? base : base.appendingPathComponent(file)
    }

    /// Tailnet first (one short HEAD), the public copy otherwise.
    static func reachable() async -> URL {
        var req = URLRequest(url: tailnet, timeoutInterval: 2.5)
        req.httpMethod = "HEAD"
        if let (_, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 { return tailnet }
        return publicCopy
    }
}

#if os(macOS)
struct WebPage: NSViewRepresentable {
    let url: URL
    let reload: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.setValue(false, forKey: "drawsBackground")   // the page paints its own slate ground; no white flash
        v.load(URLRequest(url: url))
        context.coordinator.last = (url, reload)
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        guard context.coordinator.last.url != url || context.coordinator.last.reload != reload else { return }
        context.coordinator.last = (url, reload)
        v.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }
    final class Coordinator { var last: (url: URL?, reload: Int) = (nil, 0) }
}
#else
struct WebPage: UIViewRepresentable {
    let url: URL
    let reload: Int
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView()
        v.isOpaque = false
        v.load(URLRequest(url: url))
        context.coordinator.last = (url, reload)
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {
        guard context.coordinator.last.url != url || context.coordinator.last.reload != reload else { return }
        context.coordinator.last = (url, reload)
        v.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }
    final class Coordinator { var last: (url: URL?, reload: Int) = (nil, 0) }
}
#endif
