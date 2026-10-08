import Foundation

#if os(macOS)
/// Runs a CLI the oracle fleet uses (herdr, gh). A GUI app gets a bare PATH, so look in the usual places.
public enum Shell {
    static let searchPaths = [NSHomeDirectory() + "/.local/bin", NSHomeDirectory() + "/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func which(_ tool: String) -> String? {
        searchPaths.map { $0 + "/" + tool }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns stdout, or nil when the tool is missing, fails, exceeds the timeout, or the task is cancelled
    /// (the process is terminated then, so a Stop does not wait for a slow gh call).
    public static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 10) async -> String? {
        guard let path = which(tool) else { return nil }
        let running = Running()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    let p = Process(); let out = Pipe()
                    p.executableURL = URL(fileURLWithPath: path); p.arguments = args
                    var env = ProcessInfo.processInfo.environment
                    env["PATH"] = searchPaths.joined(separator: ":")
                    p.environment = env
                    p.standardOutput = out; p.standardError = Pipe()
                    guard running.start(p) else { cont.resume(returning: nil); return }   // cancelled before it began
                    do { try p.run() } catch { cont.resume(returning: nil); return }
                    if running.isCancelled { p.terminate() }   // cancelled while it was starting
                    let deadline = DispatchTime.now() + timeout
                    DispatchQueue.global().asyncAfter(deadline: deadline) { if p.isRunning { p.terminate() } }
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    p.waitUntilExit()
                    cont.resume(returning: p.terminationStatus == 0 && !running.isCancelled ? String(decoding: data, as: UTF8.self) : nil)
                }
            }
        } onCancel: { running.cancel() }
    }

    /// Like run, but answers when the tool fails too: its exit status and stdout (nil only when the tool is missing or
    /// would not start), for a script that explains its failure on stdout. `env` adds to the environment.
    public static func capture(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                               timeout: TimeInterval = 10) async -> (status: Int32, out: String)? {
        guard let path = which(tool) else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); let out = Pipe()
                p.executableURL = URL(fileURLWithPath: path); p.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = searchPaths.joined(separator: ":")
                for (k, v) in extra { env[k] = v }
                p.environment = env
                p.standardOutput = out; p.standardError = FileHandle.nullDevice   // an unread stderr pipe can fill and hang it
                do { try p.run() } catch { cont.resume(returning: nil); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                cont.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// The process of one run, so a cancelled task can terminate it.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        /// false when the task was already cancelled: do not start the process
        func start(_ p: Process) -> Bool { lock.withLock { if cancelled { return false }; process = p; return true } }
        func cancel() { lock.withLock { cancelled = true; if let p = process, p.isRunning { p.terminate() } } }
    }
}
#else
/// iOS runs no CLIs: every call answers nil, as a missing tool does on the Mac.
public enum Shell {
    public static func which(_ tool: String) -> String? { nil }
    public static func run(_ tool: String, _ args: [String], timeout: TimeInterval = 10) async -> String? { nil }
    public static func capture(_ tool: String, _ args: [String], env extra: [String: String] = [:],
                               timeout: TimeInterval = 10) async -> (status: Int32, out: String)? { nil }
}
#endif
