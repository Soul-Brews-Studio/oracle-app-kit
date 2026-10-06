import SwiftUI
import OracleKit
#if os(macOS)
import AppKit
#endif

/// Neo's own panels. The kit knows nothing about labs; Neo adds the section through Extras.
enum NeoExtras {
    static let extras = Extras(sections: [
        ExtraSection(id: "labs", title: "Labs (ψ/lab)", symbol: "flask") { AnyView(LabsView()) }
    ])
}

struct LabsView: View {
    @State private var labs: [(name: String, modified: Date)] = []
    var body: some View {
        List(labs, id: \.name) { lab in
            Button {
                #if os(macOS)
                NSWorkspace.shared.open(URL(fileURLWithPath: OracleConfig.neo.localPath + "/ψ/lab/" + lab.name))
                #endif
            } label: {
                VStack(alignment: .leading) {
                    Text(lab.name).font(.body.monospaced())
                    Text(lab.modified.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        }
        .overlay { if labs.isEmpty { Text("Labs are listed on the Mac.").foregroundStyle(.secondary) } }
        .navigationTitle("Labs")
        .onAppear(perform: load)
    }
    private func load() {
        let root = OracleConfig.neo.localPath + "/ψ/lab"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        labs = names.filter { !$0.hasPrefix(".") }.compactMap { n in
            let a = try? FileManager.default.attributesOfItem(atPath: root + "/" + n)
            guard (a?[.type] as? FileAttributeType) == .typeDirectory else { return nil }
            return (n, a?[.modificationDate] as? Date ?? .distantPast)
        }.sorted { $0.modified > $1.modified }
    }
}
