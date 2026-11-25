import ChargeLight
import Foundation

extension CLI {
    // MARK: - LED

    func getCommand() throws -> CommandOutput {
        let reading = try makeBackend().read()
        let name = reading.state?.rawValue
        return CommandOutput(
            fields: ["led": .string(name), "raw": .int(Int64(reading.raw))],
            text: name ?? "unknown (0x\(String(format: "%02x", reading.raw)))")
    }

    func setCommand(_ name: String, options: [String: String]) throws -> CommandOutput {
        let state = try parseLEDState(name)
        var ttl: TimeInterval?
        if let text = options["--for"] {
            guard let seconds = parseDuration(text) else {
                throw ChargeLightError.invalidArgument("invalid --for \"\(text)\" (examples: 90, 90s, 10m, 2h)")
            }
            guard state != .system else {
                throw ChargeLightError.invalidArgument("--for does not apply to system, which ends the override")
            }
            ttl = seconds
        }
        let light = try makeWritableLight()
        let result = try light.setOverride(state, ttl: ttl, apply: false)
        try applyChange(light, force: state == .system)
        if state == .system {
            return CommandOutput(
                fields: ["led": .string(result.led.rawValue), "override": .null],
                text: result.claims.isEmpty
                    ? result.led.rawValue : "\(result.led.rawValue) (\(result.claims.count) agent claim(s) decide the LED again)")
        }
        if !result.claims.isEmpty {
            warn("this overrides \(result.claims.count) agent claim(s) until: chargelight set system")
        }
        return CommandOutput(
            fields: ["led": .string(result.led.rawValue), "override": .override(result.override)],
            text: ttl.map { "\(state.rawValue) for \(formatDuration($0))" } ?? "\(state.rawValue) (until: chargelight set system)")
    }

    func demoCommand() throws -> CommandOutput {
        let light = try makeWritableLight()
        let before = light.snapshot().override
        let sequence: [LEDState] = [.amber, .blinkSlow, .blinkFast, .green, .off]
        for state in sequence {
            _ = try light.setOverride(state, apply: false)
            try applyChange(light)
            if !json && !quiet { writeOut("\(state.rawValue)\n") }
            if demoStep > 0 { Thread.sleep(forTimeInterval: demoStep) }
        }
        // Put back whatever was being shown before the demo.
        let remaining = before?.expiresAt.map { $0.timeIntervalSinceNow }
        let restored: SyncResult
        if let before, remaining.map({ $0 > 0 }) ?? true {
            restored = try light.setOverride(before.led, ttl: remaining, apply: false)
        } else {
            restored = try light.setOverride(nil, apply: false)
        }
        try applyChange(light, force: true)
        return CommandOutput(
            fields: ["shown": .array(sequence.map { .string($0.rawValue) }), "led": .string(restored.led.rawValue)],
            text: "restored: \(restored.led.rawValue)")
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

    func claimCommand(id: String, status: String, options: [String: String]) throws -> CommandOutput {
        guard let agentStatus = AgentStatus(rawValue: status) else {
            throw ChargeLightError.invalidArgument(
                "unknown status \"\(status)\" (expected one of: \(AgentStatus.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        var ttl: TimeInterval?
        if let text = options["--ttl"] {
            guard let seconds = parseDuration(text) else {
                throw ChargeLightError.invalidArgument("invalid --ttl \"\(text)\" (examples: 90, 90s, 10m, 2h)")
            }
            ttl = seconds
        }
        let light = try makeWritableLight()
        let result = try light.claim(
            id: id, status: agentStatus, ttl: ttl, label: options["--label"], stamp: stamp, apply: false)
        try applyChange(light)
        guard let claim = result.claim else {
            // Only when this request is older than a release of the same id.
            return CommandOutput(
                fields: ["claim": .null, "accepted": .bool(false), "led": .string(result.led.rawValue)],
                text: "ignored: \(id) was released after this request started; LED \(result.led.rawValue)")
        }
        let text = result.accepted
            ? "\(result.led.rawValue) (\(claim.id) \(claim.status.rawValue), expires in \(formatDuration(claim.expiresAt.timeIntervalSinceNow)))"
            : "ignored: a newer claim for \(claim.id) exists; LED \(result.led.rawValue)"
        return CommandOutput(
            fields: [
                "claim": .claim(claim, configuration: light.configuration),
                "accepted": .bool(result.accepted),
                "led": .string(result.led.rawValue),
            ],
            text: text)
    }

    func releaseCommand(id: String) throws -> CommandOutput {
        let light = try makeWritableLight()
        let result = try light.release(id: id, stamp: stamp, apply: false)
        try applyChange(light)
        let released = result.released > 0
        return CommandOutput(
            fields: ["released": .bool(released), "led": .string(result.led.rawValue)],
            text: "\(released ? "released" : "no claim") \(id); LED \(result.led.rawValue)")
    }

    func resetCommand() throws -> CommandOutput {
        let light = try makeWritableLight()
        let result = try light.reset(apply: false)
        try applyChange(light, force: true)
        return CommandOutput(
            fields: ["released": .int(Int64(result.released)), "led": .string(result.led.rawValue)],
            text: "released \(result.released) claim(s), cleared any override; LED \(result.led.rawValue)")
    }

    func statusCommand() throws -> CommandOutput {
        let light = try makeLight()
        let snapshot = light.snapshot()
        var reading: LEDReading?
        var readError: ChargeLightError?
        do { reading = try light.backend.read() } catch { readError = ChargeLightError.wrap(error) }
        let watcherRunning = Watcher.isRunning(paths: light.paths)
        let helperPath = ChargeLight.helperPath(environment: environment)
        let helperInstalled = FileManager.default.fileExists(atPath: helperPath)
        let backendName = light.backend is FileBackend ? "file" : "smc"

        var led: [String: JSON] = [
            "desired": .string(snapshot.desired.rawValue),
            "actual": .string(reading?.state?.rawValue),
            "raw": reading.map { .int(Int64($0.raw)) } ?? .null,
        ]
        if let readError {
            led["error"] = .object(["code": .string(readError.code), "message": .string(readError.message)])
        }
        let fields: [String: JSON] = [
            "led": .object(led),
            "claims": .array(snapshot.claims.map { .claim($0, configuration: light.configuration) }),
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
        var lines = [
            "led      \(actual), desired \(snapshot.desired.rawValue)" + (backendName == "file" ? " [file backend]" : ""),
            "watcher  \(watcherRunning ? "running" : "not running")",
            "helper   \(helperInstalled ? "installed" : "not installed (run: sudo chargelight setup)") \(helperPath)",
        ]
        if let override = snapshot.override {
            let until = override.expiresAt.map { "for \(formatDuration($0.timeIntervalSinceNow))" } ?? "until: chargelight set system"
            lines.append("override \(override.led.rawValue) (\(until))")
        }
        if snapshot.claims.isEmpty {
            lines.append("claims   none")
        } else {
            lines.append("claims   \(snapshot.claims.count)")
            let rows = snapshot.claims.map { claim in
                [
                    claim.status.rawValue, light.configuration.led(for: claim.status).rawValue,
                    formatDuration(claim.expiresAt.timeIntervalSinceNow), claim.label ?? "-", claim.id,
                ]
            }
            lines += table([["STATUS", "LED", "EXPIRES", "LABEL", "ID"]] + rows).map { "  " + $0 }
        }
        return CommandOutput(fields: fields, text: lines.joined(separator: "\n"))
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
        if version != ChargeLight.version {
            warn("installed helper reports version \(version), expected \(ChargeLight.version)")
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
            text: """
                installed \(report.helperDestination.path) (version \(version), from \(report.helperSource.path))
                installed \(report.sudoersFile.path) (passwordless: chargelight-helper only)
                try: chargelight set amber
                """)
    }

    func uninstallCommand() throws -> CommandOutput {
        guard geteuid() == 0 else { throw ChargeLightError.notPrivileged("run: sudo chargelight uninstall") }
        // Best effort: hand the LED back to macOS while we still can write it.
        try? makeBackend().write(.system)
        let removed = try Installer().uninstall()
        return CommandOutput(
            fields: ["removed": .array(removed.map { .string($0.path) })],
            text: removed.isEmpty ? "nothing to remove" : removed.map { "removed \($0.path)" }.joined(separator: "\n"))
    }

    // MARK: - Watcher

    func watchCommand() throws -> CommandOutput {
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
            if let extra = invocation.options.keys.first(where: { $0 != "--as" }) {
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

    func parseLEDState(_ name: String) throws -> LEDState {
        guard let state = LEDState(rawValue: name) else {
            throw ChargeLightError.invalidArgument("unknown LED state \"\(name)\" (expected one of: \(LEDState.namesList))")
        }
        return state
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
