import ChargeLight
import Foundation

/// Runs the `chargelight` command line and returns its exit code.
///
/// Everything the CLI touches from the outside world is injected, so it can be
/// run in-process by tests.
///
/// - Parameters:
///   - arguments: The arguments, without the program name.
///   - environment: Environment variables (`CHARGELIGHT_*`).
///   - stdin: Returns all of standard input; only `hook` calls it.
///   - stdout: Receives standard output text.
///   - stderr: Receives standard error text.
///   - stamp: Claim ordering stamp; pass the process start time in nanoseconds
///     (see ``Claim/currentStamp()``) so a hook that started earlier but
///     finished later cannot override a newer one.
///   - executablePath: The `chargelight` binary, used to start the watcher and
///     to find the helper during `setup`. Defaults to the running executable.
/// - Returns: 0 ok, 1 failure, 2 usage, 3 unsupported hardware, 4 setup
///   required, 5 not privileged, 6 SMC error.
public func runChargeLight(
    arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment,
    stdin: @escaping () -> Data = { FileHandle.standardInput.readDataToEndOfFile() },
    stdout: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data($0.utf8)) },
    stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data($0.utf8)) },
    stamp: UInt64 = Claim.currentStamp(),
    executablePath: String? = nil
) -> Int32 {
    let cli = CLI(
        environment: environment, stdin: stdin, stdout: stdout, stderr: stderr, stamp: stamp,
        executablePath: executablePath ?? CLI.currentExecutablePath())
    return cli.run(arguments)
}

/// The parsed command line.
struct Invocation: Equatable {
    var command: String?
    var positionals: [String] = []
    var options: [String: String] = [:]
    var json = false
    var quiet = false
    var help = false
    var version = false

    static let valueOptions: Set<String> = ["--ttl", "--label", "--as", "--for"]

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
            case "--": onlyPositionals = true
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
}

/// One run of the command line.
final class CLI {
    let environment: [String: String]
    let readStdin: () -> Data
    let writeOut: (String) -> Void
    let writeErr: (String) -> Void
    let stamp: UInt64
    let executablePath: String
    var json = false
    var quiet = false
    /// Seconds each `demo` state is shown.
    var demoStep: TimeInterval = 2

    init(
        environment: [String: String], stdin: @escaping () -> Data, stdout: @escaping (String) -> Void,
        stderr: @escaping (String) -> Void, stamp: UInt64, executablePath: String
    ) {
        self.environment = environment
        self.readStdin = stdin
        self.writeOut = stdout
        self.writeErr = stderr
        self.stamp = stamp
        self.executablePath = executablePath
    }

    func run(_ arguments: [String]) -> Int32 {
        // The hook must never print and never fail, whatever it is given.
        let parsed = try? Invocation.parse(arguments)
        if parsed?.command == "hook" || (parsed == nil && arguments.contains("hook")) {
            runHook(arguments)
            return 0
        }
        json = arguments.contains("--json")
        do {
            let invocation = try Invocation.parse(arguments)
            json = invocation.json
            quiet = invocation.quiet
            let output = try dispatch(invocation)
            emit(output)
            return output.ok ? 0 : 1
        } catch {
            return fail(ChargeLightError.wrap(error))
        }
    }

    private func dispatch(_ invocation: Invocation) throws -> CommandOutput {
        if invocation.version && invocation.command == nil { return versionCommand() }
        guard let command = invocation.command, !invocation.help else { return helpCommand() }

        let allowedOptions: Set<String>
        switch command {
        case "claim": allowedOptions = ["--ttl", "--label"]
        case "set": allowedOptions = ["--for"]
        default: allowedOptions = []
        }
        if let unexpected = invocation.options.keys.sorted().first(where: { !allowedOptions.contains($0) }) {
            throw ChargeLightError.invalidArgument("\(command) does not take \(unexpected)")
        }
        let args = invocation.positionals
        switch command {
        case "get": try expect(args, 0, command); return try getCommand()
        case "set":
            try expect(args, 1, command, usage: "set <state> [--for 10m]")
            return try setCommand(args[0], options: invocation.options)
        case "claim":
            try expect(args, 2, command, usage: "claim <id> <working|attention|ready> [--ttl 10m] [--label text]")
            return try claimCommand(id: args[0], status: args[1], options: invocation.options)
        case "release": try expect(args, 1, command, usage: "release <id>"); return try releaseCommand(id: args[0])
        case "reset": try expect(args, 0, command); return try resetCommand()
        case "status": try expect(args, 0, command); return try statusCommand()
        case "doctor": try expect(args, 0, command); return doctorCommand()
        case "setup": try expect(args, 0, command); return try setupCommand()
        case "uninstall": try expect(args, 0, command); return try uninstallCommand()
        case "demo": try expect(args, 0, command); return try demoCommand()
        case "version": try expect(args, 0, command); return versionCommand()
        case "help": return helpCommand()
        case "_watch": try expect(args, 0, command); return try watchCommand()
        default:
            throw ChargeLightError.invalidArgument("unknown command \"\(command)\" (see: chargelight help)")
        }
    }

    private func expect(_ args: [String], _ count: Int, _ command: String, usage: String? = nil) throws {
        guard args.count == count else {
            throw ChargeLightError.invalidArgument("usage: chargelight \(usage ?? command)")
        }
    }

    // MARK: - Output

    func emit(_ output: CommandOutput) {
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
            let body: JSON = .object([
                "ok": .bool(false),
                "error": .object(["code": .string(error.code), "message": .string(error.message)]),
            ])
            writeOut(body.serialized + "\n")
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

    static let helpText = """
        chargelight \(ChargeLight.version) - the MagSafe charger LED as a status light for AI coding agents

        usage: chargelight <command> [options]

        LED
          get                            read the LED
          set <state>                    show a state, overriding agents, until `set system`  [--for 10m]
          demo                           show every state for ~2 s each, then restore

        Agent status
          claim <id> <status>            claim the LED for an agent  [--ttl 10m] [--label text]
          release <id>                   drop a claim
          reset                          drop every claim and any override
          status                         LED, claims, override, watcher and helper
          hook [--as <status|release>]   for Claude Code hooks: reads the event JSON on stdin,
                                         never prints, always exits 0

        Setup
          setup                          install the passwordless LED helper (run with sudo)
          uninstall                      remove it (run with sudo)
          doctor                         check this Mac and the installation
          version, help

        States     system, off, green, amber, blink-slow, blink-fast
        Statuses   attention (blink-fast) > working (amber) > ready (green); no claims: system
        Durations  90, 90s, 10m, 2h   (defaults: working 30m, attention 2h, ready 10m)

        Options    --json         print one JSON object on stdout
                   -q, --quiet    print nothing on success
                   -h, --help     --version

        Exit codes 0 ok, 1 failure, 2 usage, 3 unsupported hardware, 4 setup required,
                   5 not privileged, 6 SMC error

        Environment
          CHARGELIGHT_HOME            state directory (~/Library/Application Support/chargelight)
          CHARGELIGHT_LED_WORKING     LED for a status; also _ATTENTION, _READY and _IDLE
          CHARGELIGHT_BACKEND=file    simulate the LED in $CHARGELIGHT_HOME/led (no hardware, no root)
          CHARGELIGHT_HELPER          helper path (/Library/PrivilegedHelperTools/chargelight-helper)
          CHARGELIGHT_NO_WATCHER=1    do not start the background watcher
          CHARGELIGHT_DEBUG=1         log hook errors to $CHARGELIGHT_HOME/hook.log
        """
}
