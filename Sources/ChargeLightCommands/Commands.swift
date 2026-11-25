import ChargeLight
import Foundation

extension CLI {
    // MARK: - LED

    func getCommand() throws -> CommandOutput {
        let reading = try makeBackend().read()
        let name = reading.state?.rawValue
        let text = name ?? "unknown (0x\(String(format: "%02x", reading.raw)))"
        return CommandOutput(
            fields: ["led": .string(name), "raw": .int(Int64(reading.raw))],
            text: fancy ? fancyGet(reading.state, text: text) : text)
    }

    func setCommand(_ show: String, options: [String: String]) throws -> CommandOutput {
        let ending = show == LEDState.system.rawValue
        var ttl: TimeInterval?
        if let text = options["--for"] {
            ttl = try duration(text, option: "--for")
            guard !ending else {
                throw ChargeLightError.invalidArgument("--for does not apply to system, which ends the override")
            }
        }
        let light = try makeWritableLight()
        try validateLED(show, light.configuration)
        let result = try light.setOverride(show: show, ttl: ttl, apply: false)
        try applyChange(light, force: ending)
        let led = result.led.description
        if ending {
            return CommandOutput(
                fields: ["led": .string(led), "override": .null],
                text: fancy ? fancySet(result, ttl: nil, ending: true)
                    : result.claims.isEmpty ? led : "\(led) (\(result.claims.count) claim(s) decide the LED again)")
        }
        if !result.claims.isEmpty {
            warn("this overrides \(result.claims.count) claim(s) until: chargelight set system")
        }
        return CommandOutput(
            fields: ["led": .string(led), "override": .override(result.override)],
            text: fancy ? fancySet(result, ttl: ttl, ending: false)
                : ttl.map { "\(show) for \(formatDuration($0))" } ?? "\(show) (until: chargelight set system)")
    }

    func flashCommand(_ what: String, options: [String: String], wait: Bool) throws -> CommandOutput {
        let times = try integer(options["--times"] ?? "3", option: "--times", in: 1...100)
        let light = try makeWritableLight()
        let pattern = try flashPattern(what, configuration: light.configuration)
        let length = Double(times) * pattern.duration
        let claim = try notice(
            kind: "flash", pattern: pattern, length: length, label: what, light: light, wait: wait && !fancy)
        let text = "flash \(pattern.name ?? pattern.literal) \(times) time(s) (\(formatSeconds(length)))"
        var output = CommandOutput(
            fields: [
                "flash": .object([
                    "id": .string(claim.id), "show": .string(claim.show), "times": .int(Int64(times)),
                    "duration": .seconds(length),
                ]),
            ],
            text: text)
        if fancy {
            let name = LEDState(rawValue: what) != nil ? what : pattern.name ?? pattern.literal
            animateFlash(pattern: pattern, name: name, times: times, claim: claim, light: light, into: &output)
        }
        return output
    }

    /// What `flash` shows once: `green`/`amber` blink 150 ms on, 150 ms off; or a pattern.
    func flashPattern(_ what: String, configuration: Configuration) throws -> Pattern {
        switch LEDState(rawValue: what) {
        case .green?, .amber?:
            return try Pattern(parsing: "\(what):150,off:150")
        case .some:
            throw ChargeLightError.invalidArgument(
                "flash takes green, amber, a pattern name or a pattern such as green:100,off:100, not \(what)")
        case nil:
            guard case .pattern(let named) = try configuration.resolveLED(what) else {
                throw ChargeLightError.invalidArgument("flash takes green, amber or a pattern")
            }
            return named
        }
    }

    func morseCommand(_ text: String, options: [String: String], wait: Bool) throws -> CommandOutput {
        let colour: LEDState
        switch options["--color"] ?? "amber" {
        case "amber": colour = .amber
        case "green": colour = .green
        case let other: throw ChargeLightError.invalidArgument("invalid --color \"\(other)\" (expected amber or green)")
        }
        var unitText = options["--unit"] ?? "150"
        if unitText.hasSuffix("ms") { unitText.removeLast(2) }
        let unit = try integer(unitText, option: "--unit", in: 50...1000)
        let light = try makeWritableLight()
        let pattern = try Pattern.morse(text, lit: colour, unit: Double(unit) / 1000)
        let claim = try notice(
            kind: "morse", pattern: pattern, length: pattern.duration, label: "morse: \(text)", light: light,
            wait: wait && !fancy)
        var output = CommandOutput(
            fields: [
                "morse": .object([
                    "id": .string(claim.id), "text": .string(text), "duration": .seconds(pattern.duration),
                    "pattern": .string(claim.show),
                ]),
            ],
            text: "morse \"\(text)\" (\(formatSeconds(pattern.duration)))")
        if fancy { animateMorse(text: text, pattern: pattern, claim: claim, light: light, into: &output) }
        return output
    }

    /// Shows `pattern` for `length` seconds over every claim, then lets the LED
    /// go back: a short-lived claim at ``Configuration/noticePriority`` that
    /// the watcher ends on time.
    func notice(
        kind: String, pattern: Pattern, length: TimeInterval, label: String?, light: StatusLight, wait: Bool,
        warnings: Bool = true
    ) throws -> Claim {
        let id = "\(kind):\(getpid())-\(String(UInt32.random(in: 0 ... .max), radix: 16))"
        // End just before the next pass would start, so its first step never shows.
        let result = try light.claim(
            id: id, show: pattern.literal, priority: Configuration.noticePriority, ttl: max(0.01, length - 0.02),
            label: label, stamp: Claim.currentStamp(), apply: false)
        try applyChange(light)
        guard let claim = result.claim else { throw ChargeLightError.io("the \(kind) claim was not stored") }
        if warnings, let override = result.override {
            warn("the override \(override.show) hides this \(kind); end it with: chargelight set system")
        }
        if wait {
            // A little extra, so the watcher has put the LED back before we return.
            Thread.sleep(forTimeInterval: max(0, claim.expiresAt.timeIntervalSinceNow + 0.03))
        }
        return claim
    }

    /// What `demo` shows, in order, with what each is for.
    static let demoSequence: [(show: String, purpose: String)] = [
        ("amber", "solid amber: busy, something is running"),
        ("green", "solid green: done, ready for you"),
        ("blink-slow", "the hardware's slow amber blink: waiting on something"),
        ("blink-fast", "the hardware's fast amber blink: needs you now"),
        ("alternate", "amber and green in turn, played in software"),
        ("heartbeat", "a double pulse: alive and ticking over"),
        ("blink-green", "green on and off: finished, come and look"),
    ]

    func demoCommand() throws -> CommandOutput {
        let light = try makeWritableLight()
        let before = light.snapshot().override
        let sequence = CLI.demoSequence.map(\.show)
        if fancy { return try fancyDemo(light: light, before: before) }
        for show in sequence {
            _ = try light.setOverride(show: show, apply: false)
            try applyChange(light)
            if !json && !quiet { writeOut("\(show)\n") }
            if demoStep > 0 { Thread.sleep(forTimeInterval: demoStep) }
        }
        let restored = try restoreOverride(before, light: light)
        return CommandOutput(
            fields: ["shown": .array(sequence.map { .string($0) }), "led": .string(restored.led.description)],
            text: "restored: \(restored.led.description)")
    }

    /// Puts back the override that was in force before `demo` or `play`
    /// (with what was left of its time), or clears the override.
    func restoreOverride(_ before: Override?, light: StatusLight) throws -> SyncResult {
        let remaining = before?.expiresAt.map { $0.timeIntervalSinceNow }
        let restored: SyncResult
        if let before, remaining.map({ $0 > 0 }) ?? true {
            restored = try light.setOverride(show: before.show, ttl: remaining, apply: false)
        } else {
            restored = try light.setOverride(show: nil, apply: false)
        }
        try applyChange(light, force: true)
        return restored
    }

    /// A status light that can actually change the LED. Changes are applied by
    /// a background watcher, which cannot report back, so a missing helper is
    /// caught here before anything is recorded.
    func makeWritableLight() throws -> StatusLight {
        let light = try makeLight()
        if let smc = light.backend as? SMCBackend, !smc.isHelperInstalled, geteuid() != 0 {
            throw ChargeLightError.setupRequired(SMCBackend.setupHint)
        }
        return light
    }

    /// Makes the LED follow a change that was recorded with `apply: false`.
    func applyChange(_ light: StatusLight, force: Bool = false) throws {
        try Watcher.apply(light: light, executablePath: executablePath, environment: environment, force: force)
    }

    // MARK: - Claims

    func claimCommand(id: String, show: String, options: [String: String]) throws -> CommandOutput {
        let ttl = try options["--ttl"].map { try duration($0, option: "--ttl") }
        let priority = try options["--priority"].map { try integer($0, option: "--priority", in: -1_000_000...1_000_000) }
        let light = try makeWritableLight()
        let result = try light.claim(
            id: id, show: show, priority: priority, ttl: ttl, label: options["--label"], stamp: stamp, apply: false)
        try applyChange(light)
        let led = result.led.description
        guard let claim = result.claim else {
            // Only when this request is older than a release of the same id.
            let text = "ignored: \(id) was released after this request started; LED \(led)"
            return CommandOutput(
                fields: ["claim": .null, "accepted": .bool(false), "led": .string(led)],
                text: fancy ? fancyLEDLine(result.led, Line([.dim(text)])) : text)
        }
        var text: String
        if result.accepted {
            text = "\(led) (\(claim.id) \(claim.show), priority \(claim.priority), "
                + "expires in \(formatDuration(claim.expiresAt.timeIntervalSinceNow)))"
            if result.override != nil {
                text += "; an override decides the LED until: chargelight set system"
            } else if let winner = winningClaim(result.claims, light.configuration), winner.id != claim.id {
                text += "; \(winner.id) wins with priority \(winner.priority)"
            }
        } else {
            text = "ignored: a newer claim for \(claim.id) exists; LED \(led)"
        }
        if fancy { text = fancyClaim(result, claim: claim, configuration: light.configuration, plain: text) }
        return CommandOutput(
            fields: [
                "claim": .claim(claim, configuration: light.configuration),
                "accepted": .bool(result.accepted),
                "led": .string(led),
            ],
            text: text)
    }

    func releaseCommand(id: String) throws -> CommandOutput {
        let light = try makeWritableLight()
        let result = try light.release(id: id, stamp: stamp, apply: false)
        try applyChange(light)
        let released = result.released > 0
        return CommandOutput(
            fields: ["released": .bool(released), "led": .string(result.led.description)],
            text: fancy ? fancyRelease(result, id: id)
                : "\(released ? "released" : "no claim") \(id); LED \(result.led.description)")
    }

    func resetCommand() throws -> CommandOutput {
        let light = try makeWritableLight()
        let result = try light.reset(apply: false)
        try applyChange(light, force: true)
        return CommandOutput(
            fields: ["released": .int(Int64(result.released)), "led": .string(result.led.description)],
            text: fancy
                ? fancyLEDLine(result.led, Line([Span("released \(result.released) claim(s), cleared any override")]))
                : "released \(result.released) claim(s), cleared any override; LED \(result.led.description)")
    }

    func statusCommand() throws -> CommandOutput {
        let light = try makeLight()
        let configuration = light.configuration
        let snapshot = light.snapshot()
        var reading: LEDReading?
        var readError: ChargeLightError?
        do { reading = try light.backend.read() } catch { readError = ChargeLightError.wrap(error) }
        let watcherRunning = Watcher.isRunning(paths: light.paths)
        let helperPath = ChargeLight.helperPath(environment: environment)
        let helperInstalled = FileManager.default.fileExists(atPath: helperPath)
        let backendName = light.backend is FileBackend ? "file" : "smc"

        var led: [String: JSON] = [
            "desired": .string(snapshot.desired.description),
            "actual": .string(reading?.state?.rawValue),
            "raw": reading.map { .int(Int64($0.raw)) } ?? .null,
        ]
        if let readError {
            led["error"] = .object(["code": .string(readError.code), "message": .string(readError.message)])
        }
        let fields: [String: JSON] = [
            "led": .object(led),
            "claims": .array(snapshot.claims.map { .claim($0, configuration: configuration) }),
            "override": .override(snapshot.override),
            "watcher": .object(["running": .bool(watcherRunning)]),
            "helper": .object(["installed": .bool(helperInstalled), "path": .string(helperPath)]),
            "backend": .string(backendName),
            "home": .string(light.paths.root.path),
        ]

        let actual: String
        if let reading {
            actual = reading.state?.rawValue ?? "unknown (0x\(String(format: "%02x", reading.raw)))"
        } else {
            actual = "unreadable (\(readError?.message ?? "unknown error"))"
        }
        if fancy {
            return CommandOutput(fields: fields, text: fancyStatus(
                snapshot: snapshot, configuration: configuration, actual: actual, backendName: backendName,
                watcherRunning: watcherRunning, helperInstalled: helperInstalled, helperPath: helperPath))
        }
        // The hardware shows a pattern one step at a time.
        let desired = snapshot.desired.pattern == nil
            ? snapshot.desired.description : "\(snapshot.desired.description) (pattern)"
        var lines = [
            "led      \(actual), desired \(abbreviate(desired, 60))" + (backendName == "file" ? " [file backend]" : ""),
            "watcher  \(watcherRunning ? "running" : "not running")",
            "helper   \(helperInstalled ? "installed" : "not installed (run: sudo chargelight setup)") \(helperPath)",
        ]
        if let override = snapshot.override {
            let until = override.expiresAt.map { "for \(formatDuration($0.timeIntervalSinceNow))" }
                ?? "until: chargelight set system"
            lines.append("override \(abbreviate(override.show, 60)) (\(until))")
        }
        if snapshot.claims.isEmpty {
            lines.append("claims   none")
        } else {
            lines.append("claims   \(snapshot.claims.count)")
            let rows = snapshot.claims.map { claim in
                [
                    abbreviate(claim.show), abbreviate((try? configuration.resolve(claim.show))?.description ?? "? (unknown)"),
                    String(claim.priority), formatDuration(claim.expiresAt.timeIntervalSinceNow), claim.label ?? "-",
                    claim.id,
                ]
            }
            lines += table([["SHOW", "LED", "PRI", "EXPIRES", "LABEL", "ID"]] + rows).map { "  " + $0 }
        }
        return CommandOutput(fields: fields, text: lines.joined(separator: "\n"))
    }

    func listCommand() throws -> CommandOutput {
        let configuration = try makeLight().configuration
        let presets = configuration.presets.sorted {
            $0.value.priority != $1.value.priority ? $0.value.priority > $1.value.priority : $0.key < $1.key
        }
        let patterns = configuration.patterns.sorted { $0.key < $1.key }
        let states = LEDState.allCases.map(\.rawValue)

        var lines = fancy ? [] : ["States (idle: \(configuration.idle.rawValue))"]
        if fancy {
            lines = [fancyList(configuration: configuration, presets: presets, patterns: patterns)]
        } else {
            lines += states.map { "  " + $0 }
            lines += ["", "Presets"]
            lines += table([["NAME", "LED", "PRI", "TTL"]] + presets.map {
                [$0.key, $0.value.led, String($0.value.priority), formatDuration($0.value.ttl)]
            }).map { "  " + $0 }
            lines += ["", "Patterns"]
            lines += table(patterns.map { [$0.key, $0.value.literal] }).map { "  " + $0 }
        }
        return CommandOutput(
            fields: [
                "states": .array(states.map { .string($0) }),
                "idle": .string(configuration.idle.rawValue),
                "presets": .object(Dictionary(uniqueKeysWithValues: presets.map {
                    ($0.key, JSON.object([
                        "led": .string($0.value.led), "priority": .int(Int64($0.value.priority)),
                        "ttl": .seconds($0.value.ttl),
                    ]))
                })),
                "patterns": .object(Dictionary(uniqueKeysWithValues: patterns.map { ($0.key, JSON.string($0.value.literal)) })),
            ],
            text: lines.joined(separator: "\n"))
    }

    // MARK: - Setup

    func setupCommand() throws -> CommandOutput {
        guard geteuid() == 0 else { throw ChargeLightError.notPrivileged(SMCBackend.setupHint) }
        guard let source = Installer.locateHelper(executablePath: executablePath) else {
            let dir = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent().path
            throw ChargeLightError.io(
                "cannot find chargelight-helper in \(dir) or \(dir)/../libexec; reinstall chargelight")
        }
        let installer = Installer()
        let report = try installer.install(helperSource: source)
        guard let version = report.helperVersion else {
            throw ChargeLightError.io("installed \(report.helperDestination.path) but it does not run")
        }
        if version != ChargeLight.helperVersion {
            warn("installed helper reports version \(version), expected \(ChargeLight.helperVersion)")
        }
        return CommandOutput(
            fields: [
                "helper": .object([
                    "source": .string(report.helperSource.path),
                    "path": .string(report.helperDestination.path),
                    "version": .string(version),
                ]),
                "sudoers": .string(report.sudoersFile.path),
            ],
            text: fancy
                ? fancyChecks([
                    "installed \(report.helperDestination.path) (version \(version), from \(report.helperSource.path))",
                    "installed \(report.sudoersFile.path) (passwordless: chargelight-helper only)",
                ], footer: "try: chargelight flash green")
                : """
                installed \(report.helperDestination.path) (version \(version), from \(report.helperSource.path))
                installed \(report.sudoersFile.path) (passwordless: chargelight-helper only)
                try: chargelight flash green
                """)
    }

    func uninstallCommand() throws -> CommandOutput {
        guard geteuid() == 0 else { throw ChargeLightError.notPrivileged("run: sudo chargelight uninstall") }
        // Best effort: hand the LED back to macOS while we still can write it.
        try? makeBackend().write(.system)
        let removed = try Installer().uninstall()
        return CommandOutput(
            fields: ["removed": .array(removed.map { .string($0.path) })],
            text: fancy
                ? fancyChecks(removed.map { "removed \($0.path)" }, footer: removed.isEmpty ? "nothing to remove" : nil)
                : removed.isEmpty ? "nothing to remove" : removed.map { "removed \($0.path)" }.joined(separator: "\n"))
    }

    // MARK: - Watcher

    /// The hidden `_watch` command: the background watcher itself.
    func watcherCommand() throws -> CommandOutput {
        Watcher.run(light: try makeLight())
        return CommandOutput()
    }

    // MARK: - Hook

    /// Handles `chargelight hook`. Never writes to stdout or stderr; failures
    /// are appended to `hook.log` when `CHARGELIGHT_DEBUG=1`.
    func runHook(_ arguments: [String]) {
        var event = "?"
        do {
            let invocation = try Invocation.parse(arguments)
            if let extra = (invocation.options.keys.sorted() + invocation.flags.sorted()).first(where: { $0 != "--as" }) {
                throw ChargeLightError.invalidArgument("hook does not take \(extra)")
            }
            var forced: ClaudeCodeHook.Action?
            if let name = invocation.options["--as"] {
                guard let action = ClaudeCodeHook.Action(argument: name) else {
                    throw ChargeLightError.invalidArgument("hook --as: unknown action \"\(name)\"")
                }
                forced = action
            }
            guard let input = ClaudeCodeHook.Input.decode(readStdin()) else {
                throw ChargeLightError.invalidArgument("hook input is not a JSON object")
            }
            event = input.hookEventName ?? "?"
            guard let action = forced ?? ClaudeCodeHook.action(for: input) else { return }
            guard let session = input.sessionID, !session.isEmpty else {
                throw ChargeLightError.invalidArgument("hook input has no session_id")
            }
            let id = ClaudeCodeHook.claimID(sessionID: session)
            // Not set up yet: this throws, so the hook stays completely out of
            // the way (no state, no sudo attempts).
            let light = try makeWritableLight()
            switch action {
            case .release:
                _ = try light.release(id: id, stamp: stamp, apply: false)
            case .claim(let status):
                _ = try light.claim(
                    id: id, status: status, label: ClaudeCodeHook.label(cwd: input.cwd), stamp: stamp, apply: false)
            }
            try applyChange(light)
        } catch {
            logHookError(event: event, error: ChargeLightError.wrap(error))
        }
    }

    private func logHookError(event: String, error: ChargeLightError) {
        guard environment["CHARGELIGHT_DEBUG"] == "1" else { return }
        let formatter = ISO8601DateFormatter()
        let line = "\(formatter.string(from: Date())) \(event) \(error.code): \(error.message)\n"
        let url = paths.hookLogFile
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withCString { write(fd, $0, strlen($0)) }
    }

    // MARK: - Helpers

    /// Checks that `show` is a state or pattern; a preset gets a hint, since
    /// only claims take presets.
    func validateLED(_ show: String, _ configuration: Configuration) throws {
        do {
            _ = try configuration.resolveLED(show)
        } catch {
            if configuration.preset(show) != nil {
                throw ChargeLightError.invalidArgument(
                    "\(show) is a preset; presets are for claims: chargelight claim <id> \(show)")
            }
            throw error
        }
    }

    /// The claim that decides the LED among `claims` (highest precedence
    /// first): the first whose `show` still resolves.
    func winningClaim(_ claims: [Claim], _ configuration: Configuration) -> Claim? {
        claims.first { (try? configuration.resolve($0.show)) != nil }
    }

    /// Parses a duration option such as `--for 10m`.
    func duration(_ text: String, option: String) throws -> TimeInterval {
        guard let seconds = parseDuration(text) else {
            throw ChargeLightError.invalidArgument("invalid \(option) \"\(text)\" (examples: 90, 90s, 10m, 2h)")
        }
        return seconds
    }

    /// Parses a whole-number option within `range`.
    func integer(_ text: String, option: String, in range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
            throw ChargeLightError.invalidArgument(
                "invalid \(option) \"\(text)\" (expected a whole number from \(range.lowerBound) to \(range.upperBound))")
        }
        return value
    }

    /// Shortens a long pattern for a table: the start, then `...`.
    func abbreviate(_ text: String, _ length: Int = 32) -> String {
        text.count <= length ? text : String(text.prefix(length - 3)) + "..."
    }

    /// `0.9 s`, `12.3 s`.
    func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", seconds)
    }

    /// Left-aligns columns separated by two spaces.
    func table(_ rows: [[String]]) -> [String] {
        guard let columns = rows.map(\.count).max() else { return [] }
        let widths = (0..<columns).map { column in rows.map { column < $0.count ? $0[column].count : 0 }.max() ?? 0 }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
    }
}
