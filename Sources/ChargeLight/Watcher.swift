import CChargeLightSMC
import Foundation

/// A short-lived background process that owns the LED while anything asks for it.
///
/// It is started on demand by `chargelight claim`, `chargelight set` and the
/// hook, needs no installation, and exits by itself once no claims and no
/// override remain. While it runs it:
///
/// - **holds** the LED: macOS can take the LED back within seconds of a write
///   and always does on replug, so the watcher keeps one privileged helper
///   running that puts the state back within a few hundredths of a second
///   (see ``LEDHold``);
/// - **reacts** at once when a claim changes (it watches the claims directory);
/// - **expires** stale claims, so an agent that crashed never leaves the light stuck.
///
/// Only one watcher runs per state directory: it holds an exclusive lock on
/// ``Paths/watcherLockFile`` for its whole life.
public enum Watcher {
    /// Seconds between ticks when nothing changes; claim changes wake it sooner.
    public static let defaultInterval: TimeInterval = 1

    /// Seconds after a write before a readback is trusted (for backends
    /// without a hold); the SMC can report the previous value for a moment.
    public static let settleTime: TimeInterval = 3

    /// What one tick did.
    public struct Tick: Equatable, Sendable {
        /// The sync performed by the tick.
        public var result: SyncResult
        /// Whether the LED was re-written because the hardware had drifted.
        public var reasserted: Bool
        /// Whether the watcher should keep running (something still asks for the LED).
        public var shouldContinue: Bool { !result.isIdle }
    }

    /// Runs one watcher iteration: sync, then drift recovery.
    public static func tick(light: StatusLight, now: Date = Date()) throws -> Tick {
        let (result, reasserted) = try light.syncAndReassert(now: now, settle: settleTime)
        return Tick(result: result, reasserted: reasserted)
    }

    /// Runs the watch loop until nothing asks for the LED, ticking every
    /// `interval` seconds and whenever the claims change. Returns immediately
    /// if another watcher holds the lock.
    ///
    /// - Returns: `false` if another watcher was already running.
    @discardableResult
    public static func run(light: StatusLight, interval: TimeInterval = defaultInterval) -> Bool {
        guard let lock = try? FileLock.tryExclusive(light.paths.watcherLockFile, create: true) else { return false }
        defer { lock.unlock() }

        // With a hold, every write goes to one long-running helper that also
        // keeps the state; without one, ticks re-write on drift.
        var hold: LEDHolding?
        var active = light
        if let holding = light.backend as? HoldingLEDBackend, let started = try? holding.makeHold() {
            hold = started
            active = light.using(backend: HeldBackend(base: light.backend, hold: started))
        }
        let changes = DirectoryWatch(light.paths.claimsDirectory)

        var idleExit = false
        while true {
            do {
                _ = try tick(light: active)
            } catch ChargeLightError.setupRequired {
                break  // nothing can be written until `sudo chargelight setup`
            } catch {
                // A failed write. Keep going while claims remain; they expire on their own.
            }
            // Decide to leave under the claims lock and give up the watcher
            // lock inside it: a claim stored after this sees no watcher and
            // starts a new one.
            if (try? active.ifIdle({ lock.unlock() })) == true {
                idleExit = true
                break
            }
            changes.wait(timeout: interval)
        }
        // Idle: the idle state is already applied, leave it. Otherwise hand
        // the LED back to macOS rather than leave a state nobody is keeping.
        hold?.stop(restoreSystem: !idleExit)
        return true
    }

    /// Whether a watcher currently holds the lock for `paths`.
    public static func isRunning(paths: Paths) -> Bool {
        do {
            guard FileIO.exists(paths.watcherLockFile.path) else { return false }
            guard let lock = try FileLock.tryExclusive(paths.watcherLockFile, create: false) else { return true }
            lock.unlock()
            return false
        } catch {
            return false
        }
    }

    /// Makes the LED follow what `light` now calls for, after a change made
    /// with `apply: false`.
    ///
    /// If something asks for the LED, a watcher is started (or already runs
    /// and has noticed). If nothing does, a running watcher restores the idle
    /// state and exits; with none running the idle state is written directly.
    /// With `CHARGELIGHT_NO_WATCHER=1` the LED is written once, in-process.
    ///
    /// - Parameters:
    ///   - executablePath: The `chargelight` binary that runs the watcher.
    ///     Defaults to the one found by ``locateCLI(environment:)``.
    ///   - force: When idle with no watcher, write the idle state even if it
    ///     is believed to be showing already.
    public static func apply(
        light: StatusLight, executablePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment, force: Bool = false
    ) throws {
        if environment["CHARGELIGHT_NO_WATCHER"] == "1" {
            _ = try light.sync(force: force)
        } else if light.snapshot().isIdle {
            if !isRunning(paths: light.paths) { _ = try light.sync(force: force) }
        } else if !isRunning(paths: light.paths) {
            guard let path = executablePath ?? locateCLI(environment: environment) else {
                throw ChargeLightError.setupRequired(
                    "the chargelight command was not found; install it with Homebrew (see the README)")
            }
            try ensureRunning(paths: light.paths, executablePath: path, environment: environment)
        }
    }

    /// Finds the `chargelight` command: on `PATH`, then in the usual Homebrew
    /// locations (an app started from the Dock has a minimal `PATH`).
    public static func locateCLI(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        return directories
            .map { ($0 as NSString).appendingPathComponent("chargelight") }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts `<executablePath> _watch` as a detached process unless a watcher
    /// is already running or `CHARGELIGHT_NO_WATCHER=1` is set. The child gets
    /// its own session, so it survives the calling hook being killed.
    ///
    /// - Returns: The new process id, or `nil` if nothing was started.
    @discardableResult
    public static func ensureRunning(
        paths: Paths, executablePath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> pid_t? {
        if environment["CHARGELIGHT_NO_WATCHER"] == "1" || isRunning(paths: paths) { return nil }
        let arguments = [executablePath, "_watch"]
        let env = environment.map { "\($0.key)=\($0.value)" }
        let pid = withCStrings(arguments) { argv in
            withCStrings(env) { envp in cl_spawn_detached(executablePath, argv, envp) }
        }
        guard pid > 0 else { throw ChargeLightError.posix("cannot start watcher", executablePath) }
        return pid
    }

    /// Calls `body` with a NULL-terminated C array of the strings.
    private static func withCStrings<R>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> R) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}

/// Wakes a waiting thread when entries are added to, removed from or replaced
/// in a directory. Falls back to plain timed waits if the directory cannot be
/// watched.
final class DirectoryWatch {
    private let semaphore = DispatchSemaphore(value: 0)
    private var source: DispatchSourceFileSystemObject?

    init(_ directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: DispatchQueue(label: "chargelight.watch"))
        let semaphore = self.semaphore
        source.setEventHandler { semaphore.signal() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }

    /// Returns when the directory changes or after `timeout` seconds. Changes
    /// that pile up while the caller is busy are delivered as one.
    func wait(timeout: TimeInterval) {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return }
        while semaphore.wait(timeout: .now()) == .success {}
    }
}
