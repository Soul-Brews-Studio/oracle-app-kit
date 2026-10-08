#if os(macOS)
import SwiftUI

/// What a Send or a Bring back did, step by step as its script printed it: where it landed, the history it carried,
/// the token it found, and on failure the command that fixes it.
struct FerryLog: View {
    let run: FerryRun
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: run.ok ? "checkmark.circle.fill" : "exclamationmark.octagon.fill")
                    .foregroundStyle(run.ok ? Color.green : Color.orange)
                Text(run.title).font(.headline)
                Spacer()
            }
            ScrollView {
                Text(run.log.split(separator: "\n").filter { !$0.hasPrefix("FERRY-FAR ") }.joined(separator: "\n"))
                    .font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 200, maxHeight: 420)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.35)))
            HStack {
                Text("Scripts: \(Ferry.dir.path)").font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 660)
    }
}
#endif
