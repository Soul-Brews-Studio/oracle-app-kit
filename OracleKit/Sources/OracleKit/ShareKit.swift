#if os(macOS)
import AppKit
import SwiftUI

/// The macOS Share menu's entry for an oracle (Chrome's Share button, File ▸ Share, Safari, Finder, Notes …):
/// a small panel with the same three actions as the right-click Services and the Chrome menu. It hands the shared
/// page, text or file to the oracle app through oracle-<name>://issue|inbox|message — the app shows the editable
/// issue draft, saves the inbox note, or fills the message box. Nothing is posted or sent from here.
open class OracleShareViewController: NSViewController {
    /// Each app's tiny ShareViewController overrides this with its OracleConfig.
    open var config: OracleConfig { fatalError("override config in the app's ShareViewController") }
    private let model = ShareModel()

    open override func loadView() {
        let panel = SharePanel(name: config.name, color: config.color, model: model,
                               onPick: { [weak self] in self?.send($0) }, onCancel: { [weak self] in self?.cancel() })
        view = NSHostingView(rootView: panel.tint(config.color))
        preferredContentSize = NSSize(width: 460, height: 160)
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            if let t = item.attributedTitle?.string, !t.isEmpty { model.title = t }
            if let t = item.attributedContentText?.string, !t.isEmpty, model.text.isEmpty { model.text = t }
            for p in item.attachments ?? [] {
                if p.hasItemConformingToTypeIdentifier("public.url") {
                    p.loadItem(forTypeIdentifier: "public.url") { [model] value, _ in
                        let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                        Task { @MainActor in if model.url == nil { model.url = url } }
                    }
                } else if p.hasItemConformingToTypeIdentifier("public.plain-text") {
                    p.loadItem(forTypeIdentifier: "public.plain-text") { [model] value, _ in
                        let s = (value as? String) ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
                        Task { @MainActor in if let s, model.text.isEmpty { model.text = s } }
                    }
                }
            }
        }
    }

    private func send(_ action: String) {
        var c = URLComponents()
        c.scheme = config.scheme; c.host = action
        c.queryItems = [URLQueryItem(name: "url", value: model.url?.absoluteString ?? ""),
                        URLQueryItem(name: "title", value: model.title),
                        URLQueryItem(name: "text", value: model.text)]
        if let link = c.url { NSWorkspace.shared.open(link) }
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }
}

@MainActor final class ShareModel: ObservableObject {
    @Published var url: URL?
    @Published var title = ""
    @Published var text = ""
}

struct SharePanel: View {
    let name: String
    let color: Color
    @ObservedObject var model: ShareModel
    let onPick: (String) -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(color.gradient).frame(width: 22, height: 22)
                Text("Send to \(name) Oracle").font(.custom("Avenir Next", size: 16).weight(.semibold))
            }
            Text(preview).font(.callout).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            HStack(spacing: 8) {
                Button("New issue") { onPick("issue") }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Send to inbox") { onPick("inbox") }
                Button("Message") { onPick("message") }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 460, alignment: .leading)
    }
    private var preview: String {
        [model.title, model.url.map { $0.isFileURL ? $0.lastPathComponent : $0.absoluteString } ?? "", model.text]
            .first { !$0.isEmpty } ?? "…"
    }
}
#endif
