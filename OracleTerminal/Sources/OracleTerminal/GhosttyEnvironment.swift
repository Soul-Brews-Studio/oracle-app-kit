import Darwin
import GhosttyTerminal

/// libghostty's `ghostty_init` keeps libc's `environ` array (its pointer and length) and walks it for every getenv; it
/// never copies it. libc reallocates that array whenever any code in the process adds a variable, and from then on
/// ghostty walks freed memory: Nexus crashed in `ghostty_config_finalize`, looking up GHOSTTY_MAC_LAUNCH_SOURCE in it
/// (#95). Core ML adds one: Espresso sets and unsets ESPRESSO_ENABLE_VALUE_INFERENCE while the bundled model loads.
///
/// libc only reallocates, frees or edits the array that is current. So `start`, called at launch before the model
/// load can run, makes the first TerminalController (its init runs `ghostty_init`) and then points `environ` at a copy
/// of its own: the array ghostty kept is never touched again, and every later setenv / unsetenv works on the copy.
enum GhosttyEnvironment {
    @MainActor private static var started = false

    /// Runs `ghostty_init`, then detaches `environ` from the array ghostty kept. Later calls do nothing.
    @MainActor static func start() {
        guard !started else { return }
        started = true
        _ = TerminalController()   // its init runs ghostty_init, once per process; this controller is dropped at once
        detach()
    }

    /// libSystem's `char ***_NSGetEnviron(void)`: Swift's Darwin module has `environ` read-only and no _NSGetEnviron.
    private typealias GetEnviron = @convention(c) () -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>

    /// Points `environ` at a deep copy. The strings are copied too: libc frees a string it allocated when its variable
    /// is unset or outgrows it, and the array ghostty kept points at those strings.
    private static func detach() {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_NSGetEnviron") else { return }   // RTLD_DEFAULT
        let env = unsafeBitCast(sym, to: GetEnviron.self)()
        guard let kept = env.pointee else { return }
        var count = 0
        while kept[count] != nil { count += 1 }
        let copy = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: count + 1)
        for i in 0..<count { copy[i] = strdup(kept[i]!) }
        copy[count] = nil
        env.pointee = copy   // never freed: libc treats it as not its own and copies it on the next setenv
    }
}
