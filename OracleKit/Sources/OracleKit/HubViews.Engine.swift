#if os(macOS)
import SwiftUI
import AppKit

/// The coverage ring of Relic Studio's Embedding screen, alive: a glowing sweep spins while it works, the arc fills
/// with the current phase (reading repos → embedding texts), and settles on coverage when done.
struct CoverageRing: View {
    let ready: Int, pending: Int, running: Bool
    var progress: Double? = nil
    var phase = "idle"
    var readingLabel = "READING REPOS"
    @State private var spin = false
    @State private var pulse = false
    var body: some View {
        let total = max(1, ready + pending)
        let cover = Double(ready) / Double(total)
        let shown = progress ?? cover
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<60, id: \.self) { i in   // tick marks
                    Capsule().fill(Color.primary.opacity(i % 5 == 0 ? 0.28 : 0.1)).frame(width: 1.5, height: i % 5 == 0 ? 9 : 5)
                        .offset(y: -108).rotationEffect(.degrees(Double(i) * 6))
                }
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 14).frame(width: 182, height: 182)
                Circle().trim(from: 0, to: shown)
                    .stroke(AngularGradient(colors: [HubStyle.accent.opacity(0.35), HubStyle.accent, Color.cyan], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 182, height: 182)
                    .shadow(color: HubStyle.accent.opacity(running ? 0.9 : 0.45), radius: running ? 16 : 8)
                    .animation(.easeOut(duration: 0.4), value: shown)
                if running {   // the scanning sweep
                    Circle().trim(from: 0, to: 0.12)
                        .stroke(LinearGradient(colors: [.clear, Color.cyan], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 212, height: 212)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }.onDisappear { spin = false }
                }
                VStack(spacing: 4) {
                    Text(ready == 0 && pending == 0 && !running ? "—" : String(format: "%.0f%%", shown * 100))
                        .font(.system(size: 38, weight: .heavy, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText()).animation(.easeOut, value: Int(shown * 100))
                    Text(running ? (phase == "reading" ? readingLabel : "EMBEDDING") : (ready == 0 ? "AWAITING FIRST BATCH" : "COVERAGE"))
                        .font(.caption2.weight(.semibold)).tracking(1.8).foregroundStyle(running ? Color.cyan : .secondary)
                        .opacity(running && pulse ? 0.45 : 1)
                        .animation(running ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                        .onAppear { pulse = true }
                }
            }
            .frame(width: 230, height: 230)
            HStack(spacing: 26) {
                VStack(spacing: 3) { Text("\(ready)").font(.headline.monospacedDigit()).foregroundStyle(.green).contentTransition(.numericText()); Text("READY").font(.caption2).tracking(1.5).foregroundStyle(.secondary) }
                VStack(spacing: 3) { Text("\(pending)").font(.headline.monospacedDigit()).foregroundStyle(.orange).contentTransition(.numericText()); Text("PENDING").font(.caption2).tracking(1.5).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Live telemetry while a batch runs: the repo being read, texts done, and a throughput sparkline (texts/s per batch).
struct LiveTelemetry: View {
    @ObservedObject var index: GHIndex
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(index.rateHistory.last.map { "\(Int($0))" } ?? "—").font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.cyan).contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 1) {
                    Text(index.via.isEmpty ? "texts/s" : "texts/s · \(index.via)").font(.caption).foregroundStyle(.secondary)
                    if let c = index.lastCall {
                        Text(c.tokens > 0 ? "last call \(c.texts) texts · \(grouped(c.tokens)) tok · \(Int(c.ms)) ms · \(short(Double(c.tokens) * 1000 / max(c.ms, 1))) tok/s"
                                          : "last call \(c.texts) texts · \(Int(c.ms)) ms")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if index.phase == "reading" {
                    Text(index.currentRepo.isEmpty ? "\(grouped(index.repoDone))/\(grouped(index.repoTotal)) transcripts" : "repo \(index.repoDone + 1)/\(index.repoTotal) · \(index.currentRepo)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if index.textTotal > 0 {
                    Text("\(index.textDone)/\(index.textTotal) texts").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Sparkline(values: index.rateHistory).frame(height: 34)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let top = max(1, values.max() ?? 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: values.count < 2 ? 0 : g.size.width * CGFloat(i) / CGFloat(values.count - 1), y: g.size.height * (1 - CGFloat(v / top)))
            }
            ZStack {
                Path { p in guard let f = pts.first else { return }; p.move(to: CGPoint(x: f.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)) }
                    .fill(LinearGradient(colors: [Color.cyan.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { p in guard let f = pts.first else { return }; p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) } }
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).shadow(color: Color.cyan.opacity(0.8), radius: 4)
            }
        }
    }
}

struct EngineRow: View {
    let name: String, value: String
    var good: Bool? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).foregroundStyle(good == false ? Color.orange : (good == true ? Color.green : Color.primary)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout).padding(.vertical, 3)
    }
}

/// The bundled model loading: which part loads now, compiled or from the cache, elapsed, time left, and why the
/// first launch takes minutes.
struct ModelLoadRow: View {
    @ObservedObject var load: ModelLoad
    var fallback = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Bundled model").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    if let f = load.failed {
                        Text("did not load — \(f)").foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                        if let retry = load.retry { Button("Retry") { retry() }.controlSize(.small).handCursor() }
                    } else if load.absent {
                        Text("not in this build — embedding goes through 127.0.0.1:11435").foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        let secs = Int(ctx.date.timeIntervalSince(load.started ?? ctx.date))
                        let now = load.next.map { "worker \($0.worker + 1) · bucket \($0.bucket)" } ?? "warm-up"
                        let left = load.eta.map { eta -> String in   // counts down between parts
                            let m = max(0, eta - ctx.date.timeIntervalSince(load.lastStepAt ?? ctx.date))
                            return m >= 90 ? " · ~\(Int(m / 60 + 0.5)) min left" : " · ~\(Int(m)) s left"
                        } ?? ""
                        Text("part \(min(load.done + 1, max(load.total, 1)))/\(max(load.total, 1)) · \(now) · \(secs / 60)m \(String(format: "%02d", secs % 60))s\(left)")
                            .monospacedDigit().foregroundStyle(Color.cyan).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                if load.loading {
                    ProgressView(value: Double(load.done), total: Double(max(load.total, 1))).tint(.cyan)
                    Text((load.steps.contains { $0.seconds >= 2 }
                          ? "First launch: the Neural Engine compiles each bucket once for this app (~30 s each), then caches it — later launches take seconds. "
                          : "Loading from the Neural Engine cache. ") +
                         (fallback ? "Meanwhile search goes through the ANE service on 127.0.0.1:11435." : "Search and batches wait for it."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The in-process Neural Engine, live — the "power up" you can watch: one light per worker, lit while its model runs,
/// texts/s and tokens/s over the last 10 s, the last call; under it the ANE itself, for the whole Mac (IOReport).
struct NeuralEngineRow: View {
    @ObservedObject private var meter = ANEMeter.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let a = GHIndex.loaded?.activity() ?? EmbedActivity()
            let live = a.textsPerSecond > 0 || a.busy.contains(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    Text(a.devices.allSatisfy { $0 == "ANE" } ? "Neural Engine" : "Workers").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(Array(a.busy.enumerated()), id: \.offset) { i, on in
                            let tint: Color = i < a.devices.count && a.devices[i] == "GPU" ? .orange : .cyan
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(on ? tint : Color.primary.opacity(0.12))
                                .frame(width: 30, height: 13)
                                .overlay(Text(i < a.devices.count ? a.devices[i] : "\(i + 1)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(on ? Color.black : tint.opacity(0.8)))
                                .shadow(color: on ? tint : .clear, radius: on ? 6 : 0)
                        }
                    }
                    .help("This app's workers and where each runs (ANE or GPU): lit while its model runs")
                    if live {
                        Text("\(short(a.textsPerSecond)) texts/s · \(short(a.tokensPerSecond)) tok/s").monospacedDigit().foregroundStyle(Color.cyan)
                    } else {
                        Text("idle").foregroundStyle(.secondary)
                    }
                    if let c = a.last.first {
                        Text("· last \(c.texts) texts in \(Int(c.ms)) ms").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("\(grouped(a.texts)) texts").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("embedded in this app since launch")
                }
                if let u = meter.utilization, let g = meter.gbs {
                    HStack(spacing: 10) {
                        Spacer().frame(width: 110)
                        Text(String(format: "ANE %.0f%% · %.1f GB/s", u, g)).font(.caption.monospacedDigit())
                            .foregroundStyle(g > 1 ? Color.cyan : .secondary)
                        Sparkline(values: meter.history).frame(width: 110, height: 14)
                        Text("whole Mac").font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .help("The Neural Engine itself, read from IOReport once a second: time out of its idle state, and memory bandwidth. Counts every app using it.")
                }
            }
            .font(.callout).padding(.vertical, 3)
        }
        .onAppear { meter.watch() }
        .onDisappear { meter.unwatch() }
    }
}

/// The debug log, like a console: every model part, repo read, embed call and search, with its speed.
/// Also written to ~/Library/Logs/ARRA Oracles/embed.log.
struct DebugLogView: View {
    @ObservedObject private var log = HubLog.shared
    @AppStorage("hub.debugLog") private var open = true
    @AppStorage("hub.verboseLog") private var verbose = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(.caption.weight(.bold))
                        Label("Debug log", systemImage: "terminal").font(.headline)
                    }
                    .foregroundStyle(Color.cyan)
                }
                .buttonStyle(.plain).handCursor()
                Text("\(log.lines.count) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Toggle("Verbose", isOn: $verbose).toggleStyle(.checkbox).font(.caption)
                    .help("A scan logs one line per transcript: size, lines, prose, tools, thinking, milliseconds")
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log.text, forType: .string) }
                    .buttonStyle(.borderless).handCursor()
                Button { NSWorkspace.shared.open(HubLog.file) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless).handCursor().help(HubLog.file.path)
            }
            if open {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log.lines) { l in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(HubLog.clock(l.at)).foregroundStyle(.tertiary)
                                    Text(l.kind.rawValue.uppercased()).foregroundStyle(Self.color(l.kind)).frame(width: 50, alignment: .leading)
                                    Text(l.text).foregroundStyle(l.kind == .error ? Color.orange : Color.primary.opacity(0.85))
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 11, design: .monospaced)).id(l.id)
                            }
                            if log.lines.isEmpty { Text("nothing yet").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cyan.opacity(0.15)))
                    .onAppear { if let id = log.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    .onChange(of: log.lines.last?.id) { if let id = log.lines.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } } }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    static func color(_ k: HubLog.Kind) -> Color {
        switch k {
        case .load: return .cyan
        case .read: return .secondary
        case .embed: return .green
        case .search: return HubStyle.accent
        case .info: return .secondary
        case .error: return .orange
        }
    }
}

/// Where the bundled model runs: both workers on the Neural Engine (low power), both on the GPU, or one on each
/// (fastest). Saved per Mac; a change reloads the model while the running engine keeps answering. The GPU's first
/// load compiles too, then comes from the cache like the ANE's.
struct EnginePicker: View {
    @ObservedObject var load: ModelLoad
    @AppStorage("hub.engineMode") private var mode = "ane"
    var body: some View {
        HStack(alignment: .center) {
            Text("Run on").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Picker("", selection: $mode) {
                Text("ANE").tag("ane"); Text("GPU").tag("gpu"); Text("Both").tag("both")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            .help("ANE: two Neural Engine workers, low power. GPU: two GPU workers, ~5× faster. Both: two GPU workers plus one ANE worker.")
            if load.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .font(.callout).padding(.vertical, 3)
        .onChange(of: mode) {
            HubLog.shared.add(.load, "engine picker: \(mode.uppercased()) — loading the model there; the current engine answers meanwhile")
            load.reload?(mode)
        }
    }
}
#endif
