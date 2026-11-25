import ChargeLight
import Foundation

extension CLI {
    /// `chargelight run [options] -- <command> [args...]`: claims the light
    /// while the command runs and shows how it ended. Prints nothing of its
    /// own on stdout and exits with the command's status.
    func runCommand(_ command: [String], options: [String: String]) throws -> CommandOutput {
        guard let name = command.first, !name.isEmpty else {
            throw ChargeLightError.invalidArgument("usage: chargelight run [options] -- <command> [args...]")
        }
        let light = try makeWritableLight()
        let working = options["--working"] ?? AgentStatus.working.rawValue
        let succeeded = options["--ok"] ?? AgentStatus.ready.rawValue
        let failed = options["--fail"] ?? AgentStatus.attention.rawValue
        for (option, show) in [("--working", working), ("--ok", succeeded), ("--fail", failed)] {
            do {
                _ = try light.configuration.resolve(show)
            } catch {
                throw ChargeLightError.invalidArgument("\(option): \(ChargeLightError.wrap(error).message)")
            }
        }
        let keep = try options["--keep"].map { text -> TimeInterval in
            // Unlike other durations, zero is allowed: release at once.
            var number = text.trimmingCharacters(in: .whitespaces).lowercased()
            if let last = number.last, "smh".contains(last) { number.removeLast() }
            if !number.isEmpty, number.allSatisfy({ $0 == "0" || $0 == "." }), number.contains("0") { return 0 }
            return try duration(text, option: "--keep")
        }
        let id = options["--id"] ?? "run:\(getpid())"
        guard !id.isEmpty else { throw ChargeLightError.invalidArgument("--id must not be empty") }
        let label = options["--label"] ?? URL(fileURLWithPath: name).lastPathComponent

        guard let path = ChildProcess.resolve(name, searchPath: environment["PATH"]) else {
            writeErr("chargelight: run: \(name): command not found\n")
            return CommandOutput(silent: true, exitCode: 127)
        }

        let keeper = ClaimKeeper(
            light: light, id: id, priority: nil, label: label, interval: renewInterval,
            apply: { [unowned self] in try self.applyChange($0) })
        try keeper.claim(working)

        // Pass signals on to the command; chargelight itself stays to report how it ended.
        let child = ChildProcess()
        let trap = SignalTrap { sig in child.forward(sig) }
        defer { trap.remove() }

        do {
            try child.start(path: path, arguments: command, environment: environment, resetSignals: trap.signals)
        } catch {
            try? keeper.finish()
            writeErr("chargelight: run: \(ChargeLightError.wrap(error).message)\n")
            return CommandOutput(silent: true, exitCode: 127)
        }
        let status = child.wait()

        let ok = status == 0
        do {
            try keeper.finish(show: ok ? succeeded : failed, ttl: keep ?? (ok ? 10 : 60))
        } catch {
            writeErr("chargelight: run: \(ChargeLightError.wrap(error).message)\n")
        }
        return CommandOutput(silent: true, exitCode: status)
    }
}

/// A command started by `chargelight run`, sharing chargelight's standard
/// input, output and error.
final class ChildProcess {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var pending: Int32?

    /// Finds `name` like a shell does: as given if it contains a slash, else
    /// in `searchPath` (default `/usr/bin:/bin:/usr/sbin:/sbin`).
    static func resolve(_ name: String, searchPath: String?) -> String? {
        if name.contains("/") { return name }
        let directories = (searchPath ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "." : String($0) }
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Starts the process. `resetSignals` go back to their default action in
    /// the child (chargelight ignores them while it forwards them).
    func start(path: String, arguments: [String], environment: [String: String], resetSignals: [Int32]) throws {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in resetSignals { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        // Only standard input, output and error are passed on.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in 0...2 where fcntl(fd, F_GETFD) != -1 {
            posix_spawn_file_actions_addinherit_np(&actions, fd)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        lock.lock()
        defer { lock.unlock() }
        var child: pid_t = 0
        let code = posix_spawn(&child, path, &actions, &attributes, &argv, &envp)
        guard code == 0 else {
            throw ChargeLightError.io("cannot run \(path): \(String(cString: strerror(code)))")
        }
        pid = child
        if let pending { kill(child, pending) }
    }

    /// Sends `sig` to the process (or once it has started). A SIGINT is not
    /// sent when chargelight runs in the terminal's foreground: the terminal
    /// has already sent it to the whole process group, command included, and
    /// a second one can mean "force quit".
    func forward(_ sig: Int32) {
        if sig == SIGINT && ChildProcess.isTerminalForeground() { return }
        lock.lock()
        defer { lock.unlock() }
        if pid > 0 { kill(pid, sig) } else { pending = sig }
    }

    /// Waits for the process to exit and returns its exit status, or 128 plus
    /// the signal that killed it.
    func wait() -> Int32 {
        lock.lock()
        let child = pid
        lock.unlock()
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 {
            guard errno == EINTR else { return 1 }
        }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func isTerminalForeground() -> Bool {
        for fd: Int32 in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] where isatty(fd) == 1 {
            return tcgetpgrp(fd) == getpgrp()
        }
        return false
    }
}
