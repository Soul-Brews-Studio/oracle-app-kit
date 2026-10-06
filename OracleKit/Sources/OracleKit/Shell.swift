import Foundation

#if os(macOS)
/// Runs a CLI the oracle fleet uses (herdr, gh). A GUI app gets a bare PATH, so look in the usual places.
public enum Shell {
    static let searchPaths = [NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    public static func which(_ tool: String) -> String? {
        searchPaths.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns stdout, or nil when the tool is missing, fails, or exceeds the timeout.
    public static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 10) async -> String? {
        guard let path = which(tool) else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); let out = Pipe()
                p.executableURL = URL(fileURLWithPath: path); p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPaths.joined(separator: ":")
                p.environment = env
                p.standardOutput = out; p.standardError = Pipe()
                do { try p.run() } catch { cont.resume(returning: nil); return }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}
#endif
