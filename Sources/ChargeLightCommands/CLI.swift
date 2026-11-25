import ChargeLight
import Foundation

/// Runs the `chargelight` command line and returns its exit code.
///
/// Everything the CLI touches from the outside world is injected, so it can be
/// run in-process by tests.
///
/// - Parameters:
///   - arguments: The arguments, without the program name.
///   - environment: Environment variables (`CHARGELIGHT_*`, and `PATH` for `run`).
///   - stdin: Returns all of standard input; only `hook` calls it.
///   - readLine: Returns the next line of standard input without its newline,
///     or `nil` at the end; only `pipe` calls it, as lines arrive.
///   - stdout: Receives standard output text.
///   - stderr: Receives standard error text.
///   - stamp: Claim ordering stamp; pass the process start time in nanoseconds
///     (see ``Claim/currentStamp()``) so a hook that started earlier but
///     finished later cannot override a newer one.
///   - executablePath: The `chargelight` binary, used to start the watcher and
///     to find the helper during `setup`. Defaults to the running executable.
/// - Returns: 0 ok, 1 failure, 2 usage, 3 unsupported hardware, 4 setup
///   required, 5 not privileged, 6 SMC error; for `run`, the command's status.
public func runChargeLight(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    stdin: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
    readLine: @escaping () -> String? = { Swift.readLine(strippingNewline: true) },
    stdout: @escaping (String) -> Void = { StandardOutput.shared.write($0) },
    stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
    stamp: UInt64 = Claim.currentStamp(),
    executablePath: String? = nil
) -> Int32 {
    let cli = CLI(
        environment: environment, stdin: stdin, readLine: readLine, stdout: stdout, stderr: stderr,
        stamp: stamp, executablePath: executablePath ?? CLI.currentExecutablePath(),
        outputClosed: { StandardOutput.shared.isClosed })
    return cli.run(arguments)
}

/// Standard output written with `write(2)`. Once the reader has gone away
/// (`EPIPE`, with `SIGPIPE` ignored) further output is dropped and
/// ``isClosed`` turns true, so streaming commands can stop quietly.
public final class StandardOutput {
    /// The process's standard output.
    public static let shared = StandardOutput(fd: STDOUT_FILENO)

    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    /// Whether nobody reads standard output any more: a write failed, or the
    /// pipe or socket reports that its reader has gone (checked without writing,
    /// so `chargelight watch | head -1` ends without waiting for a change).
    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        if !closed {
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pollFD, 1, 0) == 1, pollFD.revents & Int16(POLLHUP | POLLERR) != 0 { closed = true }
        }
        return closed
    }

    /// Writes `text`, unless the reader has gone away.
    public func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                closed = true
                return
            }
            offset += n
        }
    }
}

/// The parsed command line.
struct Invocation: Equatable {
    var command: String?
    var positionals: [String] = []
    var options: [String: String] = [:]
    /// Boolean options given, such as `--wait`.
    var flags: Set<String> = []
    /// For `run`: everything after the first `--`, verbatim.
    var trailing: [String]?
    var json = false
    var quiet = false
    var help = false
    var version = false

    static let valueOptions: Set<String> = [
        "--ttl", "--label", "--as", "--for", "--times", "--priority", "--color", "--unit", "--count",
        "--id", "--working", "--ok", "--fail", "--keep",
    ]
    static let flagOptions: Set<String> = ["--wait"]

    static func parse(_ arguments: [String]) throws -> Invocation {
        var result = Invocation()
        var words: [String] = []
        var index = 0
        var onlyPositionals = false
        while index < arguments.count {
            let arg = arguments[index]
            index += 1
            if onlyPositionals || arg == "-" || !arg.hasPrefix("-") {
                words.append(arg)
                continue
            }
            switch arg {
            case "--":
                // `run` takes the rest as its command, options and all.
                if words.first == "run" {
                    result.trailing = Array(arguments[index...])
                    index = arguments.count
                } else {
                    onlyPositionals = true
                }
            case "--json": result.json = true
            case "--quiet", "-q": result.quiet = true
            case "--help", "-h": result.help = true
            case "--version": result.version = true
            default:
                var name = arg
                var value: String?
                if let eq = arg.firstIndex(of: "="), arg.hasPrefix("--") {
                    name = String(arg[..<eq])
                    value = String(arg[arg.index(after: eq)...])
                }
                if flagOptions.contains(name) {
                    guard value == nil else { throw ChargeLightError.invalidArgument("\(name) does not take a value") }
                    result.flags.insert(name)
                    continue
                }
                guard valueOptions.contains(name) else {
                    throw ChargeLightError.invalidArgument("unknown option \(name)")
                }
                if value == nil {
                    guard index < arguments.count else {
                        throw ChargeLightError.invalidArgument("\(name) needs a value")
                    }
                    value = arguments[index]
                    index += 1
                }
                result.options[name] = value
            }
        }
        result.command = words.first
        result.positionals = Array(words.dropFirst())
        return result
    }
}

/// The result of a successful command.
struct CommandOutput {
    /// Fields of the JSON object (`ok` is added on output).
    var fields: [String: JSON] = [:]
    /// Human-readable output; empty for none.
    var text = ""
    /// `ok` in JSON output and the exit code (0 or 1).
    var ok = true
    /// Print nothing at all: the command did its own output (`watch`, `pipe`, `run`).
    var silent = false
    /// Overrides the exit code (`run` exits with its command's status).
    var exitCode: Int32?
}

/// A command: its name, the options it takes and a one-line summary.
struct CommandSpec {
    var name: String
    var options: [String]
    var summary: String
}

/// One run of the command line.
final class CLI {
    let environment: [String: String]
    let readStdin: () -> Data
    let readLine: () -> String?
    let writeOut: (String) -> Void
    let writeErr: (String) -> Void
    let stamp: UInt64
    let executablePath: String
    /// Whether standard output has been closed by its reader.
    let outputClosed: () -> Bool
    var json = false
    var quiet = false
    /// Seconds each `demo` step is shown.
    var demoStep: TimeInterval = 2
    /// Seconds between claim renewals for `run` and `pipe`.
    var renewInterval: TimeInterval = 20
    /// Seconds between polls for `watch`.
    var watchInterval: TimeInterval = 0.2

    init(
        environment: [String: String], stdin: @escaping () -> Data,
        readLine: @escaping () -> String? = { nil }, stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void, stamp: UInt64, executablePath: String,
        outputClosed: @escaping () -> Bool = { false }
    ) {
        self.environment = environment
        self.readStdin = stdin
        self.readLine = readLine
        self.writeOut = stdout
        self.writeErr = stderr
        self.stamp = stamp
        self.executablePath = executablePath
        self.outputClosed = outputClosed
    }

    /// Every public command, in help order.
    static let commands: [CommandSpec] = [
        CommandSpec(name: "get", options: [], summary: "read the LED"),
        CommandSpec(name: "set", options: ["--for"], summary: "show a state or pattern over every claim"),
        CommandSpec(name: "flash", options: ["--times", "--wait"], summary: "flash, then go back to what was showing"),
        CommandSpec(name: "morse", options: ["--color", "--unit", "--wait"], summary: "spell text in Morse code"),
        CommandSpec(name: "demo", options: [], summary: "show states and patterns, then restore"),
        CommandSpec(name: "claim", options: ["--priority", "--ttl", "--label"], summary: "claim the shared light"),
        CommandSpec(name: "release", options: [], summary: "drop a claim"),
        CommandSpec(name: "reset", options: [], summary: "drop every claim and any override"),
        CommandSpec(name: "status", options: [], summary: "LED, claims, override, watcher and helper"),
        CommandSpec(name: "list", options: [], summary: "states, presets and patterns"),
        CommandSpec(name: "watch", options: ["--count"], summary: "print a line whenever the LED changes"),
        CommandSpec(
            name: "run", options: ["--id", "--label", "--working", "--ok", "--fail", "--keep"],
            summary: "run a command with the light following it"),
        CommandSpec(name: "pipe", options: ["--id", "--priority", "--label"], summary: "claim what each stdin line says"),
        CommandSpec(name: "hook", options: ["--as"], summary: "Claude Code hook handler"),
        CommandSpec(name: "completions", options: [], summary: "print a shell completion script"),
        CommandSpec(name: "doctor", options: [], summary: "check this Mac and the installation"),
        CommandSpec(name: "setup", options: [], summary: "install the LED helper (sudo)"),
        CommandSpec(name: "uninstall", options: [], summary: "remove the LED helper (sudo)"),
        CommandSpec(name: "version", options: [], summary: "print the version"),
        CommandSpec(name: "help", options: [], summary: "show help"),
    ]

    func run(_ arguments: [String]) -> Int32 {
        // The hook must never print and never fail, whatever it is given.
        let parsed = try? Invocation.parse(arguments)
        if parsed?.command == "hook" || (parsed == nil && arguments.prefix(while: { $0 != "--" }).first(where: {
            !$0.hasPrefix("-")
        }) == "hook") {
            runHook(arguments)
            return 0
        }
        json = arguments.prefix(while: { $0 != "--" }).contains("--json")
        do {
            let invocation = try Invocation.parse(arguments)
            json = invocation.json
            quiet = invocation.quiet
            let output = try dispatch(invocation)
            emit(output)
            return output.exitCode ?? (output.ok ? 0 : 1)
        } catch {
            return fail(ChargeLightError.wrap(error))
        }
    }

    private func dispatch(_ invocation: Invocation) throws -> CommandOutput {
        if invocation.version && invocation.command == nil { return versionCommand() }
        guard var command = invocation.command, !invocation.help else { return helpCommand() }
        var args = invocation.positionals

        // Shorthand: `chargelight amber` is `chargelight set amber`. Real commands win.
        if command != "_watch", !CLI.commands.contains(where: { $0.name == command }), isShowName(command) {
            args.insert(command, at: 0)
            command = "set"
        }

        let allowed: Set<String>
        if let spec = CLI.commands.first(where: { $0.name == command }) {
            allowed = Set(spec.options)
        } else {
            allowed = []
        }
        let given = invocation.options.keys.sorted() + invocation.flags.sorted()
        if let unexpected = given.first(where: { !allowed.contains($0) }) {
            throw ChargeLightError.invalidArgument("\(command) does not take \(unexpected)")
        }
        if invocation.trailing != nil && command != "run" {
            throw ChargeLightError.invalidArgument("unexpected --")
        }
        let options = invocation.options
        let wait = invocation.flags.contains("--wait")
        switch command {
        case "get": try expect(args, 0, command); return try getCommand()
        case "set":
            try expect(args, 1, command, usage: "set <state|pattern> [--for 10m]")
            return try setCommand(args[0], options: options)
        case "flash":
            guard args.count <= 1 else {
                throw ChargeLightError.invalidArgument("usage: chargelight flash [green|amber|<pattern>] [--times 3] [--wait]")
            }
            return try flashCommand(args.first ?? "amber", options: options, wait: wait)
        case "morse":
            guard !args.isEmpty else {
                throw ChargeLightError.invalidArgument("usage: chargelight morse <text> [--color amber|green] [--unit 150] [--wait]")
            }
            return try morseCommand(args.joined(separator: " "), options: options, wait: wait)
        case "demo": try expect(args, 0, command); return try demoCommand()
        case "claim":
            try expect(args, 2, command, usage: "claim <id> <state|pattern|preset> [--priority N] [--ttl 10m] [--label text]")
            return try claimCommand(id: args[0], show: args[1], options: options)
        case "release": try expect(args, 1, command, usage: "release <id>"); return try releaseCommand(id: args[0])
        case "reset": try expect(args, 0, command); return try resetCommand()
        case "status": try expect(args, 0, command); return try statusCommand()
        case "list": try expect(args, 0, command); return try listCommand()
        case "watch": try expect(args, 0, command, usage: "watch [--count N]"); return try watchCommand(options: options)
        case "run": return try runCommand(invocation.trailing ?? args, options: options)
        case "pipe":
            try expect(args, 0, command, usage: "pipe [--id <id>] [--priority N] [--label text]")
            return try pipeCommand(options: options)
        case "completions":
            try expect(args, 1, command, usage: "completions <zsh|bash|fish>")
            return try completionsCommand(shell: args[0])
        case "doctor": try expect(args, 0, command); return doctorCommand()
        case "setup": try expect(args, 0, command); return try setupCommand()
        case "uninstall": try expect(args, 0, command); return try uninstallCommand()
        case "version": try expect(args, 0, command); return versionCommand()
        case "help": return helpCommand()
        case "_watch": try expect(args, 0, command); return try watcherCommand()
        default:
            throw ChargeLightError.invalidArgument("unknown command \"\(command)\" (see: chargelight help)")
        }
    }

    /// Whether `word` names a state or a pattern, for the `chargelight <name>` shorthand.
    private func isShowName(_ word: String) -> Bool {
        if LEDState(rawValue: word) != nil || Pattern.builtIn[word] != nil { return true }
        let configuration = try? Configuration.load(paths: paths, environment: environment)
        return configuration?.patterns[word] != nil
    }

    private func expect(_ args: [String], _ count: Int, _ command: String, usage: String? = nil) throws {
        guard args.count == count else {
            throw ChargeLightError.invalidArgument("usage: chargelight \(usage ?? command)")
        }
    }

    // MARK: - Output

    func emit(_ output: CommandOutput) {
        if output.silent { return }
        if json {
            var fields = output.fields
            fields["ok"] = .bool(output.ok)
            writeOut(JSON.object(fields).serialized + "\n")
        } else if !quiet && !output.text.isEmpty {
            writeOut(output.text.hasSuffix("\n") ? output.text : output.text + "\n")
        }
    }

    func fail(_ error: ChargeLightError) -> Int32 {
        if json {
            writeOut(JSON.error(error).serialized + "\n")
        } else {
            writeErr("chargelight: \(error.message)\n")
        }
        return error.exitCode
    }

    /// Prints a warning on stderr in human mode (not with `--json` or `--quiet`).
    func warn(_ message: String) {
        if !json && !quiet { writeErr("chargelight: warning: \(message)\n") }
    }

    // MARK: - Environment

    var paths: Paths { Paths(environment: environment) }

    func makeBackend() throws -> LEDBackend {
        try ChargeLight.backend(environment: environment, paths: paths)
    }

    func makeLight() throws -> StatusLight {
        try StatusLight(environment: environment)
    }

    /// The real path of the running executable.
    static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments.first ?? "chargelight" }
        let path = String(cString: buffer)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - Help

    func versionCommand() -> CommandOutput {
        CommandOutput(fields: ["version": .string(ChargeLight.version)], text: "chargelight \(ChargeLight.version)")
    }

    func helpCommand() -> CommandOutput {
        CommandOutput(fields: ["help": .string(CLI.helpText)], text: CLI.helpText)
    }

    static let helpText: String = {
        let patterns = Pattern.builtIn.keys.sorted().joined(separator: ", ")
        let presets = Configuration.builtInPresets
            .sorted { $0.value.priority > $1.value.priority }
            .map { "\($0.key) (\($0.value.led), \($0.value.priority))" }
            .joined(separator: " > ")
        return """
            chargelight \(ChargeLight.version) - program the LED on your MagSafe charger

            Try it
              chargelight amber              solid amber, until you change it
              chargelight flash green        flash green three times, then back to what it was
              chargelight morse hi           spell "hi" in Morse code
              chargelight run -- sleep 5     amber while a command runs, then green (blinks on failure)
              chargelight system             hand the LED back to macOS

            usage: chargelight <command> [options]
                   chargelight <state|pattern> [--for 10m]     same as: chargelight set <state|pattern>

            LED
              get                            read the LED
              set <show> [--for 10m]         show a state or pattern over every claim, until `set system`
              flash [<what>] [--times 3] [--wait]
                                             flash amber (default), green or a pattern, then go back
              morse <text> [--color amber|green] [--unit 150] [--wait]
                                             spell text once in Morse code (unit in ms, 50 to 1000)
              demo                           show states and patterns for ~2 s each, then restore

            Shared light: anything can claim the LED; the highest priority wins, claims expire
              claim <id> <show|preset> [--priority N] [--ttl 10m] [--label text]
                                             claim (or renew) the LED under your own id
              release <id>                   drop a claim
              reset                          drop every claim and any override
              status                         LED, claims, override, watcher and helper
              list                           every state, preset and pattern you can use
              watch [--count N]              print a line now and whenever the LED or claims change
              run [options] -- <command> [args...]
                                             light follows a command; exits with its status
                --working <show|preset>      while it runs (default: working)
                --ok, --fail <show|preset>   after it exits 0 / non-zero (default: ready / attention)
                --keep <dur>                 how long to show --ok/--fail (default 10s / 60s; 0: release)
                --id <id>, --label <text>    claim id (default run:<pid>) and label (command name)
              pipe [--id <id>] [--priority N] [--label text]
                                             claim what each line of stdin says; `release` or `-`
                                             drops it; end of input releases. e.g. my-tool | chargelight pipe

            Integrations
              hook [--as <preset|release>]   for Claude Code hooks: reads the event JSON on stdin,
                                             never prints, always exits 0
              completions <zsh|bash|fish>    print a shell completion script

            Setup
              setup                          install the passwordless LED helper (run with sudo)
              uninstall                      remove it (run with sudo)
              doctor                         check this Mac and the installation
              version, help

            <show>     a state, a pattern name, or a pattern written out
            States     \(LEDState.namesList)  (system: macOS decides)
            Patterns   \(patterns)
                       or write one as state:ms,...  e.g. green:300,off:300 (steps 50 ms to 60 s)
            Presets    \(presets)
                       claims that name no preset: priority \(Configuration.defaultPriority), ttl 30m;
                       flash and morse: priority \(Configuration.noticePriority)
            Durations  90, 90s, 10m, 2h  (preset ttl: working 30m, attention 2h, ready 10m)
            Config     $CHARGELIGHT_HOME/config.json: "idle", "presets", "patterns"

            Options    --json         print one JSON object on stdout (watch, pipe: one per line)
                       -q, --quiet    print nothing on success
                       -h, --help     --version

            Exit codes 0 ok, 1 failure, 2 usage, 3 unsupported hardware, 4 setup required,
                       5 not privileged, 6 SMC error; run exits with its command's status

            Environment
              CHARGELIGHT_HOME            state directory (~/Library/Application Support/chargelight)
              CHARGELIGHT_LED_WORKING     what a built-in preset shows; also _ATTENTION, _READY and _IDLE
              CHARGELIGHT_BACKEND=file    simulate the LED in $CHARGELIGHT_HOME/led (no hardware, no root)
              CHARGELIGHT_HELPER          helper path (/Library/PrivilegedHelperTools/chargelight-helper)
              CHARGELIGHT_NO_WATCHER=1    do not start the background watcher (patterns show one step)
              CHARGELIGHT_DEBUG=1         log hook errors to $CHARGELIGHT_HOME/hook.log
            """
    }()
}
