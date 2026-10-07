import Foundation

/// A pairing link inside pasted or scanned text, and whether it is meant for this app.
/// Not behind `#if os(iOS)`: it is plain Foundation, so the Mac's tests can run it.
enum CompanionPairLink {
    struct Found { let url: URL; let pairing: CompanionAPI.Pairing }

    /// The first `oracle-<name>://pair?host=…&port=…&token=…&name=…` in `text`: the QR code's payload, a pasted link,
    /// or a message with the link somewhere in it.
    static func find(in text: String) -> Found? {
        let wrapping = CharacterSet(charactersIn: "<>\"'`()[]“”‘’,;")
        for word in text.split(whereSeparator: \.isWhitespace) {
            if let url = URL(string: word.trimmingCharacters(in: wrapping)), let p = CompanionAPI.Pairing.parse(url) {
                return Found(url: url, pairing: p)
            }
        }
        return nil
    }

    /// Why this link must not pair THIS app (with the fix), or nil when it may. Each oracle app owns its own scheme
    /// (`oracle-pulse`), so Neo's code in the Pulse app would show Neo's work under Pulse's name.
    static func mismatch(_ f: Found, oracle: OracleConfig) -> String? {
        guard servedAddress(f.pairing.host) else {
            return "That link points at \(f.pairing.host), where no oracle app serves — the Mac's own link names its NetBird address (100.x) or, for the Simulator, 127.0.0.1. Copy it again on the Mac: \(oracle.name) → Settings → Companion → Copy link"
        }
        guard !oracle.repoSlug.isEmpty else { return nil }               // identity not set yet (previews, tests)
        guard f.url.scheme?.lowercased() != "oracle-" + oracle.name.lowercased() else { return nil }
        return "That code is for \(f.pairing.name), and this is the \(oracle.name) app — on the Mac open \(oracle.name) → Settings → Companion and use its code"
    }
}

extension CompanionPairLink {
    /// An address a companion Mac serves on: 127.0.0.0/8 or ::1 (the Mac itself, the Simulator) or the NetBird mesh,
    /// 100.64.0.0/10 — CompanionServer listens nowhere else. A link that names anything else did not come from a Mac's
    /// Settings, so the phone never sends it a token or shows what it answers (a link in a web page or a message
    /// could otherwise pair the phone with any server).
    static func servedAddress(_ host: String) -> Bool {
        if host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var ip: UInt32 = 0
        for part in parts {
            // digits only and no leading zero: "100.064.0.1" could be read as octal by whatever resolves it
            guard (1...3).contains(part.count), part.allSatisfy({ ("0"..."9").contains($0) }), part == "0" || part.first != "0",
                  let v = UInt32(part), v <= 255 else { return false }
            ip = ip << 8 | v
        }
        return ip >> 24 == 127 || ip & 0xFFC0_0000 == 0x6440_0000
    }
}

extension CompanionClient {
    /// The pairing a Mac has answered: `pair()` keeps a pairing only after its hello, and a relaunch starts from the
    /// Keychain, which holds only pairings that answered.
    var verifiedPairing: CompanionAPI.Pairing? { pairing }
}

#if os(iOS)
import SwiftUI
import AVFoundation
import Vision
import VisionKit

/// Pairing the phone with an oracle app on the Mac (issue #46): scan the QR code its Settings → Companion shows
/// (VisionKit), or paste its pairing link; CompanionClient.pair then checks /v1/hello before keeping it.
/// The camera needs NSCameraUsageDescription in the app's Info.plist; without it (or without a camera, as in the
/// Simulator) the paste field is the way in, and the card above it says why.
public struct CompanionPairView: View {
    @ObservedObject private var client = CompanionClient.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var link = ""
    @State private var camera: Camera = .checking
    @State private var phase: Phase = .idle
    @State private var note: String?                       // what is wrong, ending with what fixes it
    @State private var retry: CompanionAPI.Pairing?        // the link that reached no Mac: "Try again"
    @FocusState private var typing: Bool

    private enum Camera: Equatable { case checking, ready, unsupported, denied, noUsageText, failed(String) }
    private enum Phase: Equatable { case idle, pairing(String), paired }

    public init() {}
    /// Filled in with an opened `oracle-<name>://pair?…` link: the sheet shows its Mac, and nothing pairs until Pair is pressed.
    public init(link: String) { _link = State(initialValue: link) }

    private var oracle: OracleConfig { OracleConfig.current }
    private var accent: Color { oracle.color }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("PAIR").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(accent)
                    Text("Pair with your Mac.").font(.custom("Avenir Next", size: 30).weight(.bold)).tracking(-0.5)
                    Text("On the Mac, open \(oracle.name) → Settings → Companion, switch it on, and scan its code.")
                        .font(.callout).foregroundStyle(.secondary)
                    scanCard
                    pasteCard
                    statusCard.id("status")
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            // the answer must be seen: on a small phone it sits below the fold, behind the keyboard
            .onChange(of: phase) { withAnimation { proxy.scrollTo("status", anchor: .bottom) } }
            .onChange(of: note) { withAnimation { proxy.scrollTo("status", anchor: .bottom) } }
        }
        .tint(accent)
        .task { await prepareCamera() }
        // back from Settings → Camera: look again instead of keeping the "turn it on" card
        .onChange(of: scenePhase) { if scenePhase == .active, camera == .denied { Task { await prepareCamera() } } }
    }

    // MARK: the camera

    @ViewBuilder private var scanCard: some View {
        switch camera {
        case .ready:
            CompanionQRScanner(active: phase == .idle, found: { take($0, scanned: true) }, failed: { camera = .failed($0) })
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        case .checking:
            card { HStack(spacing: 10) { ProgressView(); Text("Starting the camera…").foregroundStyle(.secondary) } }
        case .unsupported, .denied, .noUsageText, .failed:
            card {
                Label(cameraNote, systemImage: "camera.fill").font(.callout).foregroundStyle(.secondary)
                if camera == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") { openURL(settings) }.buttonStyle(.bordered)
                }
            }
        }
    }

    private var cameraNote: String {
        switch camera {
        case .unsupported: return "This device cannot scan codes (the Simulator has no camera) — paste the link below."
        case .denied: return "Camera access is off for \(oracle.name) — turn it on in Settings → \(oracle.name) → Camera, or paste the link below."
        case .noUsageText: return "This build has no camera usage text — add NSCameraUsageDescription to the app's Info.plist, or paste the link below."
        case .failed(let why): return "The camera could not start (\(why)) — paste the link below."
        case .checking, .ready: return ""
        }
    }

    /// `isSupported && isAvailable` decide; asking for access first (only when undecided) is what turns the second true.
    @MainActor private func prepareCamera() async {
        guard DataScannerViewController.isSupported else { camera = .unsupported; return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            // the system kills an app that asks without its usage text — say so instead
            guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else { camera = .noUsageText; return }
            guard await AVCaptureDevice.requestAccess(for: .video) else { camera = .denied; return }
        default: camera = .denied; return
        }
        camera = DataScannerViewController.isAvailable ? .ready : .denied
    }

    // MARK: the link

    private var pasteCard: some View {
        card {
            Text("Or paste the pairing link").font(.callout.weight(.semibold))
            TextField("oracle-\(oracle.name.lowercased())://pair?host=…", text: $link)
                .font(.callout.monospaced()).lineLimit(1)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.go)
                .focused($typing)
                .onSubmit { take(link, scanned: false) }
            if let f = CompanionPairLink.find(in: link) {
                // verbatim: a port through LocalizedStringKey prints 4,899
                Text(verbatim: "Pairs with \(f.pairing.name) at \(f.pairing.host):\(f.pairing.port)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                PasteButton(payloadType: String.self) { link = $0.first ?? link }      // no "Allow paste" alert
                Spacer()
                Button("Pair") { take(link, scanned: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase != .idle)
            }
        }
    }

    /// A scanned code or a pasted text: find the link, refuse another oracle's, pair.
    private func take(_ text: String, scanned: Bool) {
        guard phase == .idle else { return }                   // a second sighting of the same code while pairing
        typing = false                                         // the keyboard would cover the answer
        guard let found = CompanionPairLink.find(in: text) else {
            retry = nil
            note = scanned ? "That is not an oracle pairing code — the right one is on the Mac: \(oracle.name) → Settings → Companion"
                           : "That is not a pairing link — copy it on the Mac: \(oracle.name) → Settings → Companion → Copy link"
            return
        }
        if let why = CompanionPairLink.mismatch(found, oracle: oracle) { retry = nil; note = why; return }
        begin(found.pairing)
    }

    private func begin(_ p: CompanionAPI.Pairing) {
        phase = .pairing("\(p.host):\(p.port)"); note = nil; retry = nil    // set now, not in the Task: the camera may see the code twice
        Task {
            if await client.pair(p) {
                link = ""                                      // the token must not linger in a text field
                phase = .paired
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            } else {
                phase = .idle; retry = p
                note = client.problem ?? "Could not pair — on the Mac, check that Companion is on: \(oracle.name) → Settings → Companion"
            }
        }
    }

    // MARK: the answer

    @ViewBuilder private var statusCard: some View {
        switch phase {
        case .idle:
            if let note {
                card {
                    Label { Text(note).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .font(.callout)
                    if let retry { Button("Try again") { begin(retry) }.buttonStyle(.bordered) }
                }
            }
        case .pairing(let to):
            card { HStack(spacing: 10) { ProgressView(); Text("Reaching the Mac at \(to)…").foregroundStyle(.secondary) } }
        case .paired:
            card {
                Label { Text("Paired with \(client.hello?.host ?? "the Mac")").font(.custom("Avenir Next", size: 17).weight(.semibold)) }
                    icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                if let h = client.hello, let p = client.pairing {
                    // verbatim: Text("…\(p.port)…") would run the port through LocalizedStringKey and print 4,899
                    Text(verbatim: "\(h.name) · \(p.host):\(p.port) · app \(h.appVersion)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// The camera, looking for QR codes. Built only once `DataScannerViewController.isSupported && isAvailable`.
private struct CompanionQRScanner: UIViewControllerRepresentable {
    let active: Bool                       // false while a pairing is in flight: codes seen then are ignored
    let found: (String) -> Void
    let failed: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController { QRScannerController() }
    func updateUIViewController(_ c: QRScannerController, context: Context) { c.active = active; c.found = found; c.failed = failed }
}

/// Holds the scanner as a child so it can start in viewDidAppear — startScanning() fails before the view is on screen.
private final class QRScannerController: UIViewController, DataScannerViewControllerDelegate {
    var active = true
    var found: (String) -> Void = { _ in }
    var failed: (String) -> Void = { _ in }
    private let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                    recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                    isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        scanner.delegate = self
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        do { try scanner.startScanning() } catch { failed(error.localizedDescription) }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) { take(addedItems) }
    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) { take([item]) }
    func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
        failed("\(error)")
    }
    private func take(_ items: [RecognizedItem]) {
        guard active else { return }
        for case .barcode(let b) in items { if let text = b.payloadStringValue { found(text); return } }
    }
}

/// The pairing, as a Settings section: which Mac, its app version, whether it answers — and Pair…, Check, Unpair.
/// Goes inside a Form: `Form { CompanionSettingsSection() }`.
public struct CompanionSettingsSection: View {
    @ObservedObject private var client = CompanionClient.shared
    @State private var pairing = false
    @State private var confirmUnpair = false
    @State private var checking = false

    public init() {}

    private var oracle: OracleConfig { OracleConfig.current }
    private var dot: Color { client.refused || client.reachable == false ? .orange : client.reachable == true ? .green : Color.secondary.opacity(0.45) }
    private var reach: String {
        client.refused ? "refused this phone" : client.reachable == true ? "reachable" : client.reachable == false ? "not reachable" : "not checked"
    }

    public var body: some View {
        SwiftUI.Section {
            if let p = client.pairing {
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(dot).frame(width: 10, height: 10).padding(.top, 6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(client.hello?.name ?? p.name) on \(client.hello?.host ?? "your Mac")")
                            .font(.custom("Avenir Next", size: 17).weight(.semibold))
                        Text(verbatim: "\(p.host):\(p.port)" + (client.hello.map { " · app \($0.appVersion)" } ?? " · not checked yet"))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    Text(reach).font(.caption).foregroundStyle(.secondary)
                }
                // only for a pairing that is already kept: one pair() is still checking is not in the Keychain yet, and
                // asking for its hello too would race it — and leave "can't reach the Mac at ?" in the problem
                .task { if client.hello == nil, PairingStore.read() == client.pairing { await client.refreshHello() } }
            } else {
                Text("Not paired. On the Mac open \(oracle.name) → Settings → Companion, then scan its code here.").foregroundStyle(.secondary)
            }
            if let problem = client.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange).textSelection(.enabled)
            }
            Button("Pair…") { pairing = true }
                .sheet(isPresented: $pairing) {
                    NavigationStack {
                        CompanionPairView()
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { pairing = false } } }
                    }
                }
            if client.isPaired {
                Button {
                    Task { checking = true; await client.refreshHello(); checking = false }
                } label: {
                    HStack { Text("Check"); Spacer(); if checking { ProgressView() } }
                }
                .disabled(checking)
                Button("Unpair", role: .destructive) { confirmUnpair = true }
                    .confirmationDialog("Unpair from \(client.hello?.host ?? "this Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                        Button("Unpair", role: .destructive) { client.unpair() }
                    } message: {
                        Text("This phone forgets the code and stops showing the Mac's pages. To pair again, scan the code at \(oracle.name) → Settings → Companion.")
                    }
            }
        } header: {
            Text("Companion")
        } footer: {
            Text("The \(oracle.name) app on your Mac serves its pages to this phone, read-only, to a phone that holds its code. The code is kept in this device's Keychain.")
        }
    }
}

/// An opened pairing link, as a sheet item.
struct PhonePairLink: Identifiable { let id = UUID(); let url: URL }

extension CompanionClient {
    /// An opened pairing link (`oracle-<name>://pair?…`, from the Camera app, a note, a message): true when it paired.
    /// Any other link — a widget tap, `oracle-<name>://open` — is not ours to pair with, and answers false.
    /// It pairs only when the link is for this app and names an address a Mac serves on (`CompanionPairLink.mismatch`),
    /// and only once that Mac answers. The app's own onOpenURL shows the pairing sheet, naming the Mac first.
    public func handle(url: URL) async -> Bool {
        guard let p = CompanionAPI.Pairing.parse(url),
              CompanionPairLink.mismatch(.init(url: url, pairing: p), oracle: OracleConfig.current) == nil else { return false }
        return await pair(p)
    }
}
#endif
