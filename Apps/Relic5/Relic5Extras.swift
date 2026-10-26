import SwiftUI
import OracleKit

/// Relic5's own panels: Jobs, what relic5's Hindsight work is doing right now on this Mac.
enum Relic5Extras {
    static let extras = Extras(sections: [
        ExtraSection(id: "jobs", title: "Jobs", symbol: "gauge.with.dots.needle.67percent") { AnyView(JobsPanel()) }
    ])
}

// MARK: - what the panel reads (all local except the hub's status)
//   ~/.cache/relic5/hindsight-job.json   the running job: {"name", "banks": {bank: items}, "started"} (embed/discord-all.sh)
//   ~/.cache/relic5/hindsight-job.tsv    "time<TAB>items done" samples `relic5 hindsight speed` keeps (the rate)
//   ~/.cache/relic5/hindsight-feeder.json the importer's own line (source, strategy, state)
//   127.0.0.1:8888                       the hindsight-embed daemon (bank stats)
//   127.0.0.1:11436/health               relic5's embed router: every worker, its utilization and speed
//   the hub's /api/status                when this Mac last pushed (machines.<host>.text); its address from
//                                        RELIC5_URL or ~/.config/relic5/hub-url

struct WorkerRow: Identifiable {
    let id: String
    let machine: String
    let role: String
    let name: String
    let model: String
    let util: Double
    let rate: String
    let busy: String
    let up: Bool
}

struct BankRow: Identifiable {
    let id: String
    let done: Double
    let total: Double
}

@MainActor
final class JobsModel: ObservableObject {
    @Published var jobName = ""
    @Published var done = 0.0
    @Published var total = 0.0
    @Published var perMin: Double? = nil
    @Published var banks: [BankRow] = []
    @Published var workers: [WorkerRow] = []
    @Published var feeder = ""
    @Published var hub = ""
    @Published var problem: String? = nil
    @Published var updated = Date.distantPast
    private var timer: Timer?
    private var hubAt = Date.distantPast

    static let home = NSHomeDirectory()
    static let hindsight = "http://127.0.0.1:8888"
    static let router = "http://127.0.0.1:11436"
    /// the hub's address: RELIC5_URL, else the first line of ~/.config/relic5/hub-url (kept off this public repo)
    static let hubURL: String? = ProcessInfo.processInfo.environment["RELIC5_URL"]
        ?? (try? String(contentsOfFile: home + "/.config/relic5/hub-url", encoding: .utf8))?
            .split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private static func json(_ path: String) -> [String: Any]? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private static func get(_ url: String, timeout: Double = 8) async -> [String: Any]? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        guard let (d, _) = try? await URLSession.shared.data(for: r) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    func refresh() {
        Task {
            let cache = Self.home + "/.cache/relic5"
            var issues: [String] = []
            // the job: items done = each bank's documents, capped at its item count
            if let job = Self.json(cache + "/hindsight-job.json"), let b = job["banks"] as? [String: Any] {
                var rows: [BankRow] = []
                for (bank, n) in b {
                    let t = (n as? NSNumber)?.doubleValue ?? 0
                    guard t > 0 else { continue }
                    let st = await Self.get("\(Self.hindsight)/v1/default/banks/\(bank)/stats", timeout: 5)
                    let d = min((st?["total_documents"] as? NSNumber)?.doubleValue ?? 0, t)
                    rows.append(BankRow(id: bank, done: d, total: t))
                }
                if rows.allSatisfy({ $0.done == 0 }) && !rows.isEmpty { issues.append("Hindsight not answering on :8888") }
                jobName = job["name"] as? String ?? "job"
                banks = rows.sorted { ($0.total - $0.done) > ($1.total - $1.done) }
                done = rows.reduce(0) { $0 + $1.done }
                total = rows.reduce(0) { $0 + $1.total }
                perMin = Self.rate(cache + "/hindsight-job.tsv", started: (job["started"] as? NSNumber)?.doubleValue ?? 0)
            }
            if let f = Self.json(cache + "/hindsight-feeder.json") {
                feeder = "\(f["source"] as? String ?? "?") · \(f["strategy"] as? String ?? "") · \(f["state"] as? String ?? "")"
            }
            // the router's workers, grouped by the machine they run on
            if let h = await Self.get("\(Self.router)/health"), let w = h["workers"] as? [String: Any] {
                var rows: [WorkerRow] = []
                for kind in ["embed", "llm", "rerank"] {
                    for x in (w[kind] as? [[String: Any]]) ?? [] {
                        let name = x["name"] as? String ?? "?"
                        let url = x["url"] as? String ?? ""
                        let machine = (name.contains("gb300") || url.contains(":11437") || url.contains(":11510")) ? "gb300" : "m5"
                        let num = { (k: String) in (x[k] as? NSNumber)?.doubleValue ?? 0 }
                        let rate = kind == "llm"
                            ? String(format: "%.0f tok/s · %.0f calls/min", num("tokens_1m") / 60, num("requests_1m"))
                            : String(format: "%.1f texts/s", num("texts_1m") / 60)
                        rows.append(WorkerRow(id: kind + name, machine: machine,
                                              role: kind == "llm" ? "summarize" : kind, name: name,
                                              model: x["model"] as? String ?? name, util: num("util"), rate: rate,
                                              busy: "\(Int(num("inflight")))/\(Int(max(num("slots"), 1)))",
                                              up: (x["up"] as? String) == "ok"))
                        if (x["up"] as? String) != "ok" { issues.append("\(name) \(kind) is DOWN") }
                    }
                }
                workers = rows
            } else {
                issues.append("embed router not up on :11436 (embed/start.sh)")
            }
            // the hub, once a minute: when this Mac last pushed
            if Self.hubURL == nil {
                hub = "hub: put its address in ~/.config/relic5/hub-url"
            } else if let hubURL = Self.hubURL, Date().timeIntervalSince(hubAt) > 60 {
                hubAt = Date()
                let host = (Host.current().localizedName ?? "").lowercased()
                if let s = await Self.get("\(hubURL)/api/status", timeout: 15), let m = s["machines"] as? [String: Any] {
                    let key = m.keys.first { host.contains($0) } ?? "m5"
                    let t = (m[key] as? [String: Any])?["text"] as? [String: Any]
                    hub = "hub · \(key) pushed \(Self.short(t?["pushed_at"] as? String)) · newest \(Self.short(t?["newest_ts"] as? String))"
                } else {
                    hub = "hub not reachable (\(hubURL))"
                }
            }
            problem = issues.isEmpty ? nil : issues.joined(separator: " · ")
            updated = Date()
        }
    }

    /// items/min over this job's samples of the last 10 minutes, after the newest drop (a recount); nil: measuring
    static func rate(_ path: String, started: Double) -> Double? {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let now = Date().timeIntervalSince1970
        var pts: [(Double, Double)] = s.split(separator: "\n").compactMap { l in
            let f = l.split(separator: "\t").compactMap { Double($0) }
            return f.count == 2 && f[0] >= started && now - f[0] <= 600 ? (f[0], f[1]) : nil
        }
        if let cut = pts.indices.dropFirst().last(where: { pts[$0].1 < pts[$0 - 1].1 }) { pts = Array(pts[cut...]) }
        guard let a = pts.first, let b = pts.last, b.0 - a.0 >= 60, b.1 >= a.1 else { return nil }
        return (b.1 - a.1) / (b.0 - a.0) * 60
    }

    static func short(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso.replacingOccurrences(of: "+0000", with: "Z")) else { return "?" }
        return d.formatted(date: .omitted, time: .shortened)
    }
}

struct JobsPanel: View {
    @StateObject private var m = JobsModel()
    private let pink = Color(red: 1, green: 0.235, blue: 0.675)
    private let cyan = Color(red: 0, green: 0.84, blue: 1)
    private let amber = Color(red: 0.96, green: 0.72, blue: 0.23)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let p = m.problem {
                    Label(p, systemImage: "exclamationmark.triangle.fill").foregroundStyle(amber).font(.callout)
                }
                job
                machines
                Text([m.feeder, m.hub, "updated \(m.updated.formatted(date: .omitted, time: .standard))"]
                    .filter { !$0.isEmpty }.joined(separator: "   ·   "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Jobs")
        .onAppear { m.start() }
        .onDisappear { m.stop() }
    }

    private var job: some View {
        let share = m.total > 0 ? m.done / m.total : 0
        let left = max(m.total - m.done, 0)
        let eta: String = {
            guard left > 0 else { return "done" }
            guard let r = m.perMin, r > 0 else { return "measuring" }
            let mins = Int((left / r).rounded())
            let end = Date().addingTimeInterval(Double(mins) * 60).formatted(date: .omitted, time: .shortened)
            return (mins >= 60 ? "\(mins / 60)h \(String(format: "%02d", mins % 60))m" : "\(mins)m") + " · ends \(end)"
        }()
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.jobName.isEmpty ? "No job running" : m.jobName).font(.title3.bold())
                Spacer()
                Text(String(format: "%.1f%%", share * 100)).font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(pink)
            }
            ProgressView(value: share).tint(pink)
            Text("\(Int(m.done).formatted()) / \(Int(m.total).formatted()) items · "
                 + (m.perMin.map { String(format: "%.0f items/min", $0) } ?? "rate: measuring") + " · ETA \(eta)")
                .font(.callout.monospaced()).foregroundStyle(.secondary)
            if !m.banks.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(m.banks.filter { $0.done < $0.total }.prefix(6)) { b in
                        GridRow {
                            Text(b.id.replacingOccurrences(of: "discord-", with: "")).font(.caption.monospaced()).lineLimit(1)
                            ProgressView(value: b.done / b.total).tint(cyan).frame(width: 140)
                            Text("\(Int(b.done).formatted())/\(Int(b.total).formatted())").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private var machines: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(["m5", "gb300"], id: \.self) { mach in
                let rows = m.workers.filter { $0.machine == mach }
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(mach == "m5" ? "m5 · ANE + GPU" : "gb300 · shared GPU, through the tunnel").font(.headline).foregroundStyle(cyan)
                        ForEach(rows) { w in
                            HStack(spacing: 10) {
                                Text(w.role).font(.caption.monospaced()).foregroundStyle(pink).frame(width: 72, alignment: .leading)
                                Text(w.name).font(.caption.monospaced()).frame(width: 64, alignment: .leading)
                                ProgressView(value: min(max(w.util, 0), 1)).tint(w.util > 0.9 ? amber : cyan).frame(width: 120)
                                Text(String(format: "%3.0f%%", w.util * 100)).font(.caption.monospaced().bold()).frame(width: 40, alignment: .trailing)
                                Text(w.rate).font(.caption.monospaced())
                                Text("\(w.busy) busy · \(w.model)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                if !w.up { Text("DOWN").font(.caption.bold()).foregroundStyle(amber) }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
